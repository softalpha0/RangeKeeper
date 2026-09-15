// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AaveV3YieldAdapter} from "../src/adapters/AaveV3YieldAdapter.sol";
import {IAaveV3Pool, IAaveV3PoolDataProvider} from "../src/interfaces/IAaveV3Pool.sol";
import {MockERC20} from "./PairVault.t.sol";

/// @dev A single mock aToken per underlying asset — mintable/burnable only by
///      the pool that created it, mirroring Aave's real access control (only
///      the Pool contract can mint/burn a real aToken).
contract MockAToken {
    string public name = "Mock aToken";
    mapping(address => uint256) public balanceOf;
    address public immutable pool;

    error NotPool();

    modifier onlyPool() {
        if (msg.sender != pool) revert NotPool();
        _;
    }

    constructor(address _pool) {
        pool = _pool;
    }

    function mint(address to, uint256 amount) external onlyPool {
        balanceOf[to] += amount;
    }

    function burn(address from, uint256 amount) external onlyPool {
        balanceOf[from] -= amount;
    }
}

/// @notice A minimal but REAL two-party money market: supply mints an aToken
///         1:1, withdraw burns it and pays back the underlying. `simulateYield`
///         mints extra aTokens to mimic real interest accrual — the test
///         funds the pool with matching underlying separately (a real pool's
///         extra underlying comes from borrower interest; this one needs it
///         seeded explicitly).
contract MockAavePool is IAaveV3Pool, IAaveV3PoolDataProvider {
    mapping(address => address) public aTokenOf;
    mapping(address => uint256) public heldOf;

    function registerAsset(address asset) external returns (address aToken) {
        aToken = address(new MockAToken(address(this)));
        aTokenOf[asset] = aToken;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        MockERC20(asset).transferFrom(msg.sender, address(this), amount);
        heldOf[asset] += amount;
        MockAToken(aTokenOf[asset]).mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        MockAToken(aTokenOf[asset]).burn(msg.sender, amount);
        heldOf[asset] -= amount;
        MockERC20(asset).transfer(to, amount);
        return amount;
    }

    function getReserveTokensAddresses(address asset) external view returns (address, address, address) {
        return (aTokenOf[asset], address(0), address(0));
    }

    function simulateYield(address asset, address account, uint256 amount) external {
        MockAToken(aTokenOf[asset]).mint(account, amount);
        heldOf[asset] += amount;
    }
}

contract AaveV3YieldAdapterTest is Test {
    MockAavePool pool;
    AaveV3YieldAdapter adapter;
    MockERC20 token;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        pool = new MockAavePool();
        adapter = new AaveV3YieldAdapter(address(pool), address(pool));
        token = new MockERC20("USDC", 18);
        pool.registerAsset(address(token));

        // MockERC20's transferFrom doesn't enforce allowance (see
        // test/PairVault.t.sol), so no approve() call is needed here — the
        // adapter's deposit() can pull directly from alice/bob's balance.
        token.mint(alice, 1_000e18);
        token.mint(bob, 1_000e18);
    }

    function test_deposit_creditsCallerNotTheAdapter() public {
        vm.prank(alice);
        adapter.deposit(address(token), 100e18);

        assertEq(adapter.balanceOf(address(token), alice), 100e18);
        assertEq(adapter.balanceOf(address(token), address(adapter)), 0, "the adapter itself owns no shares");
    }

    function test_deposit_pullsRealTokensIntoThePool() public {
        uint256 poolBalBefore = token.balanceOf(address(pool));
        vm.prank(alice);
        adapter.deposit(address(token), 100e18);
        assertEq(token.balanceOf(address(pool)), poolBalBefore + 100e18);
        assertEq(token.balanceOf(alice), 900e18);
    }

    function test_withdraw_returnsRealTokensAndBurnsShares() public {
        vm.prank(alice);
        adapter.deposit(address(token), 100e18);

        vm.prank(alice);
        uint256 got = adapter.withdraw(address(token), 40e18);

        assertEq(got, 40e18);
        assertEq(token.balanceOf(alice), 940e18);
        assertEq(adapter.balanceOf(address(token), alice), 60e18);
    }

    function test_withdraw_capsAtCallersOwnBalance_doesNotRevert() public {
        vm.prank(alice);
        adapter.deposit(address(token), 100e18);

        vm.prank(alice);
        uint256 got = adapter.withdraw(address(token), 500e18); // way more than alice has

        assertEq(got, 100e18, "capped to what alice actually owned, not reverted");
        assertEq(adapter.balanceOf(address(token), alice), 0);
    }

    function test_withdraw_forAccountWithNothingReturnsZero() public {
        vm.prank(bob);
        uint256 got = adapter.withdraw(address(token), 1e18);
        assertEq(got, 0);
    }

    /// @notice The core value proposition: two depositors, real accrued yield
    ///         distributed proportionally to shares — not evenly, not to
    ///         whoever happened to deposit first.
    function test_yieldAccrual_splitsProportionallyBetweenDepositors() public {
        vm.prank(alice);
        adapter.deposit(address(token), 300e18); // alice: 75% of the pool
        vm.prank(bob);
        adapter.deposit(address(token), 100e18); // bob: 25%

        // Simulate 40 tokens of real accrued interest. The adapter — not
        // alice or bob individually — is the sole aToken holder (deposit()
        // supplies onBehalfOf=address(this)), so real Aave rebasing would
        // grow THE ADAPTER's balance; the adapter's own share math is what
        // then divides that pro-rata (300:100) between alice and bob.
        token.mint(address(pool), 40e18); // matching underlying, as a real pool would have from borrowers
        pool.simulateYield(address(token), address(adapter), 40e18);

        assertEq(adapter.balanceOf(address(token), alice), 330e18);
        assertEq(adapter.balanceOf(address(token), bob), 110e18);

        vm.prank(alice);
        uint256 aliceGot = adapter.withdraw(address(token), 330e18);
        assertEq(aliceGot, 330e18, "alice redeems her full balance, principal plus yield");

        vm.prank(bob);
        uint256 bobGot = adapter.withdraw(address(token), 110e18);
        assertEq(bobGot, 110e18, "bob redeems his full balance, principal plus yield");
    }

    function test_deposit_ofZeroIsANoOp() public {
        vm.prank(alice);
        adapter.deposit(address(token), 0);
        assertEq(adapter.balanceOf(address(token), alice), 0);
    }
}
