// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Requires: forge install foundry-rs/forge-std
import {Test} from "forge-std/Test.sol";
import {PairVault} from "../src/PairVault.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";

contract MockERC20 {
    string public name;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, uint8 _decimals) {
        name = _name;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    /// @dev Deliberately does NOT enforce allowance — several existing tests
    ///      rely on being able to pull from a balance with no prior approve()
    ///      call. `approve`/`allowance` exist only so a caller that DOES
    ///      approve (e.g. AaveV3YieldAdapter, which calls approve on whatever
    ///      asset it's given) doesn't revert against a token with no such
    ///      function at all.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract MockPyth is IPyth {
    mapping(bytes32 => Price) private _prices;
    bytes32[] private _feedIds;
    mapping(bytes32 => bool) private _seen;
    uint256 public updateFee;
    uint256 public updateCallCount;

    error MockStalePrice();

    function setPrice(bytes32 id, int64 price, int32 expo) external {
        if (!_seen[id]) {
            _seen[id] = true;
            _feedIds.push(id);
        }
        _prices[id] = Price({price: price, conf: 0, expo: expo, publishTime: block.timestamp});
    }

    function setUpdateFee(uint256 fee) external {
        updateFee = fee;
    }

    /// @dev Actually enforces staleness (unlike a bare mapping read) so tests
    ///      can exercise the real gate `_priceWad` relies on, not just assume it.
    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (Price memory) {
        Price memory p = _prices[id];
        if (block.timestamp - p.publishTime > age) revert MockStalePrice();
        return p;
    }

    /// @dev Ignores `updateData` contents (this is a mock) but performs the one
    ///      effect that matters for the tests that use it: refreshing every
    ///      known feed's publishTime to "now", same as a real Hermes push would.
    function updatePriceFeeds(bytes[] calldata) external payable {
        require(msg.value >= updateFee, "insufficient fee");
        updateCallCount++;
        for (uint256 i = 0; i < _feedIds.length; i++) {
            _prices[_feedIds[i]].publishTime = block.timestamp;
        }
    }

    function getUpdateFee(bytes[] calldata) external view returns (uint256) {
        return updateFee;
    }
}

/// @notice Verifies PairVault's NAV-based share pricing — the fix for the
///         scaffold's original 1:1-nominal-shares bug (README history). Two
///         assets with wildly different prices and decimals must mint shares
///         proportional to real value, not raw token count.
contract PairVaultTest is Test {
    MockERC20 usdc; // 6 decimals, $1.00
    MockERC20 weth; // 18 decimals, $3,000.00
    MockPyth pyth;
    PairVault vault;

    bytes32 constant USDC_FEED = bytes32(uint256(1));
    bytes32 constant WETH_FEED = bytes32(uint256(2));

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address constant TREASURY = address(0x7EA5); // protocol treasury — not exercised by these tests' assertions

    function setUp() public {
        usdc = new MockERC20("USDC", 6);
        weth = new MockERC20("WETH", 18);
        pyth = new MockPyth();

        pyth.setPrice(USDC_FEED, 1e8, -8); // $1.00
        pyth.setPrice(WETH_FEED, 3000e8, -8); // $3,000.00

        // address(0) for pool: these tests exercise deposit/withdraw/NAV
        // accounting only, never openBand/closeBand — those get their own real
        // end-to-end suite (test/PairVaultBand.t.sol) against a real pool.
        vault = new PairVault(
            address(usdc), address(weth), 6, 18, USDC_FEED, WETH_FEED, address(pyth), address(0), 1, address(this), TREASURY, address(0)
        );

        usdc.mint(alice, 1_000_000e6);
        weth.mint(bob, 1_000e18);
    }

    function test_navWad_pricesBothAssetsCorrectly() public {
        vm.prank(alice);
        vault.deposit(address(usdc), 100e6); // $100

        vm.prank(bob);
        vault.deposit(address(weth), 1e18); // 1 WETH = $3,000

        assertEq(vault.navWad(), 3_100e18, "NAV should be $100 + $3,000");
    }

    function test_deposit_sharesProportionalToValue_notRawTokenCount() public {
        vm.prank(alice);
        vault.deposit(address(usdc), 100e6); // $100 -> bootstrap: 100e18 shares

        vm.prank(bob);
        vault.deposit(address(weth), 1e18); // $3,000 -> 30x alice's value

        assertEq(vault.sharesOf(alice), 100e18);
        assertEq(vault.sharesOf(bob), 3_000e18);
        assertEq(vault.totalShares(), 3_100e18);

        // The bug this replaces would have given bob 1e18 raw-WETH-wei worth of
        // shares (≈ alice's 100e6 raw-USDC-wei) despite depositing 30x the value.
        assertEq(vault.sharesOf(bob) / vault.sharesOf(alice), 30, "shares must track value, not raw token units");
    }

    /// @notice With no band open, utilization is zero and NAV is exactly the
    ///         idle balances — the real open-band-affects-NAV path (and
    ///         utilization becoming nonzero) needs a deployed pool, so
    ///         it lives in test/PairVaultBand.t.sol instead of this
    ///         accounting-only suite (pool is address(0) here).
    function test_utilization_isZeroWithNoBandOpen() public {
        vm.prank(alice);
        vault.deposit(address(usdc), 100e6);
        vm.prank(bob);
        vault.deposit(address(weth), 1e18);

        assertEq(vault.utilization(), 0);
        assertEq(vault.navWad(), 3_100e18);
    }

    function test_depositFor_creditsBeneficiaryNotCaller() public {
        // Simulates an Aurora Intents Connect flow: an intermediary account
        // (`intermediary`) actually holds the bridged tokens and calls the
        // vault, but the real end user (`alice`) should own the shares.
        address intermediary = address(0xEE);
        usdc.mint(intermediary, 500e6);

        vm.prank(intermediary);
        vault.depositFor(address(usdc), 500e6, alice);

        assertEq(vault.sharesOf(alice), 500e18, "shares must go to the named beneficiary");
        assertEq(vault.sharesOf(intermediary), 0, "the paying intermediary must not receive shares");
    }

    function test_withdraw_returnsProportionalShareOfBothAssets() public {
        vm.prank(alice);
        vault.deposit(address(usdc), 100e6);
        vm.prank(bob);
        vault.deposit(address(weth), 1e18);

        uint256 aliceShares = vault.sharesOf(alice);
        vm.prank(alice);
        (uint256 amountA, uint256 amountB) = vault.withdraw(aliceShares);

        // Alice's 100e18 shares are 100/3100 of the pool — she gets that slice
        // of *both* tvlA and tvlB, not necessarily her original 100 USDC back.
        assertApproxEqRel(amountA, uint256(100e6 * 100) / 3100, 0.01e18);
        assertApproxEqRel(amountB, uint256(1e18 * 100) / 3100, 0.01e18);
        assertEq(vault.sharesOf(alice), 0);
    }

    /// @notice navWad() must skip pricing a zero-balance side entirely, so a
    ///         single-sided deposit into an empty vault never depends on the
    ///         *other* asset's price feed being fresh or reachable — that
    ///         side holds zero balance and contributes zero value either way.
    function test_deposit_singleSided_succeedsEvenIfOtherFeedIsUnset() public {
        MockERC20 freshUsdc = new MockERC20("USDC", 6);
        MockERC20 freshWeth = new MockERC20("WETH", 18);
        MockPyth freshPyth = new MockPyth();

        // Deliberately never call freshPyth.setPrice(freshWethFeed, ...) —
        // simulates a feed the deposit shouldn't need to touch yet.
        bytes32 freshUsdcFeed = bytes32(uint256(10));
        bytes32 freshWethFeed = bytes32(uint256(11));
        freshPyth.setPrice(freshUsdcFeed, 1e8, -8);

        PairVault freshVault = new PairVault(
            address(freshUsdc), address(freshWeth), 6, 18, freshUsdcFeed, freshWethFeed, address(freshPyth), address(0), 1, address(this), TREASURY, address(0)
        );

        freshUsdc.mint(alice, 100e6);
        vm.prank(alice);
        uint256 shares = freshVault.deposit(address(freshUsdc), 100e6);

        assertEq(shares, 100e18, "bootstrap deposit: 1 share per WAD of value");
        assertEq(freshVault.navWad(), 100e18);
    }

    /// @notice Pushing a Pyth price update and then calling deposit() as two
    ///         separate transactions can never reliably beat a 60-second
    ///         staleness window once real block time plus signing latency are
    ///         accounted for — the price goes stale again before the second
    ///         tx lands. depositWithPriceUpdate() avoids that by pushing the
    ///         update and pricing the deposit atomically in one call.
    function test_depositWithPriceUpdate_refreshesStalePriceAtomically() public {
        // Advance past PairVault's MAX_PRICE_AGE (60s) so both feeds are stale.
        vm.warp(block.timestamp + 61);

        usdc.mint(alice, 100e6);

        // Prove the staleness gate is real: plain deposit() must revert now.
        vm.prank(alice);
        vm.expectRevert(MockPyth.MockStalePrice.selector);
        vault.deposit(address(usdc), 100e6);

        // depositWithPriceUpdate() pushes a refresh (mock simulates Hermes'
        // effect: publishTime -> now) and then must succeed, in one call.
        pyth.setUpdateFee(3);
        vm.deal(alice, 1 ether);
        uint256 aliceEthBefore = alice.balance;

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = hex"00"; // mock ignores contents, only cares that it was called

        vm.prank(alice);
        uint256 shares = vault.depositWithPriceUpdate{value: 10}(address(usdc), 100e6, updateData);

        assertEq(shares, 100e18, "deposit must actually succeed once the price is fresh");
        assertEq(pyth.updateCallCount(), 1, "must have actually pushed the update, not skipped it");
        assertEq(aliceEthBefore - alice.balance, 3, "only the exact fee (3) should be spent, the rest (10-3) refunded");
    }

    /// @notice `valueOfAsset{A,B}(0)` must not touch Pyth — external callers may
    ///         price a raw amount that happens to be zero, and that shouldn't
    ///         make the whole read revert just because the feed is stale.
    ///         Caught by a live solver dry-run against a deployment whose demo
    ///         feed hadn't been refreshed in >60s.
    function test_valueOfAsset_zeroAmountSkipsTheOracle() public {
        vm.warp(block.timestamp + 61); // both feeds now stale

        // A non-zero amount still prices (and reverts on the stale feed).
        vm.expectRevert(MockPyth.MockStalePrice.selector);
        vault.valueOfAssetA(1);

        // Zero short-circuits before the oracle is ever consulted.
        assertEq(vault.valueOfAssetA(0), 0);
        assertEq(vault.valueOfAssetB(0), 0);
    }
}
