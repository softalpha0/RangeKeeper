// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IUniswapV3Factory} from "v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {PairVault} from "../src/PairVault.sol";
import {MockERC20, MockPyth} from "./PairVault.t.sol";

/// @notice End-to-end test of `openBand`/`closeBand` against a REAL deployed
///         Uniswap v3 pool — the vault acting as its own sole liquidity provider.
contract PairVaultBandTest is Test {
    IUniswapV3Factory factory;
    IUniswapV3Pool pool;
    MockERC20 token0;
    MockERC20 token1;
    MockPyth pyth;
    PairVault vault;

    bytes32 constant FEED0 = bytes32(uint256(10));
    bytes32 constant FEED1 = bytes32(uint256(11));
    address depositor = address(0xD0);

    function setUp() public {
        factory = IUniswapV3Factory(vm.deployCode("UniswapV3Factory.sol"));

        // Sort so token0 < token1 by address — Uniswap requires token0 < token1,
        // and PairVault assumes assetA == token0 / assetB == token1.
        MockERC20 a = new MockERC20("A", 18);
        MockERC20 b = new MockERC20("B", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);

        pyth = new MockPyth();
        pyth.setPrice(FEED0, 1e8, -8); // $1.00
        pyth.setPrice(FEED1, 1e8, -8);

        pool = IUniswapV3Pool(factory.createPool(address(token0), address(token1), 3000));
        pool.initialize(uint160(1) << 96); // price = 1.0

        // vaultManager = address(this) so this test can call the
        // onlyVaultManager-gated openBand/closeBand directly.
        vault = new PairVault(
            address(token0), address(token1), 18, 18, FEED0, FEED1, address(pyth), address(pool), 1, address(this), address(0x7EA5), address(0)
        );

        token0.mint(depositor, 10_000e18);
        token1.mint(depositor, 10_000e18);
        vm.startPrank(depositor);
        vault.deposit(address(token0), 10_000e18);
        vault.deposit(address(token1), 10_000e18);
        vm.stopPrank();
    }

    function _positionLiquidity(int24 tickLower, int24 tickUpper) internal view returns (uint128 liquidity) {
        bytes32 key = keccak256(abi.encodePacked(address(vault), tickLower, tickUpper));
        (liquidity,,,,) = pool.positions(key);
    }

    function test_openBand_actuallyAddsRealLiquidityToThePool() public {
        uint256 vaultToken0Before = token0.balanceOf(address(vault));
        uint256 vaultToken1Before = token1.balanceOf(address(vault));
        uint256 tvlABefore = vault.tvlA();
        uint256 tvlBBefore = vault.tvlB();

        uint128 liquidityAdded = vault.openBand(-600, 600, 1_000e18, 1_000e18);

        assertGt(liquidityAdded, 0, "should have added nonzero liquidity");

        uint128 storedLiquidity = _positionLiquidity(-600, 600);
        assertEq(storedLiquidity, liquidityAdded, "the pool's own position record must match what we computed");

        // The vault actually paid for it — real tokens left its balance.
        assertLt(token0.balanceOf(address(vault)), vaultToken0Before);
        assertLt(token1.balanceOf(address(vault)), vaultToken1Before);
        assertGt(token0.balanceOf(address(pool)), 0);
        assertGt(token1.balanceOf(address(pool)), 0);

        // tvlA/tvlB must fall by exactly the real outflow — navWad() is built
        // from idle balances plus the band's own live value, not a
        // pre-open snapshot, so double-booking either would misprice shares.
        assertEq(
            tvlABefore - vault.tvlA(),
            vaultToken0Before - token0.balanceOf(address(vault)),
            "tvlA must fall by exactly the real token0 outflow"
        );
        assertEq(
            tvlBBefore - vault.tvlB(),
            vaultToken1Before - token1.balanceOf(address(vault)),
            "tvlB must fall by exactly the real token1 outflow"
        );
    }

    /// @notice Opening a band must not change NAV (modulo rounding) — the
    ///         value simply moves from idle balances into the band, it isn't
    ///         lost from the vault's books. Without LiquidityMath.
    ///         getAmountsForLiquidity, navWad() would only sum idle balances
    ///         and would show NAV dropping by the entire deployed amount here.
    function test_openBand_doesNotChangeNav() public {
        uint256 navBefore = vault.navWad();
        vault.openBand(-600, 600, 1_000e18, 1_000e18);
        assertApproxEqAbs(vault.navWad(), navBefore, 1e12, "opening a band must be NAV-neutral, not NAV-destroying");
    }

    function test_openBand_revertsIfABandIsAlreadyOpen() public {
        vault.openBand(-600, 600, 1_000e18, 1_000e18);
        vm.expectRevert(PairVault.BandAlreadyOpen.selector);
        vault.openBand(-600, 600, 500e18, 500e18);
    }

    function test_closeBand_returnsRealLiquidityAndNavStaysWhole() public {
        vault.openBand(-600, 600, 1_000e18, 1_000e18);
        uint256 navAfterOpen = vault.navWad();

        (uint256 amount0, uint256 amount1) = vault.closeBand();
        assertGt(amount0, 0);
        assertGt(amount1, 0);

        uint128 remaining = _positionLiquidity(-600, 600);
        assertEq(remaining, 0, "the pool must show the vault's position fully removed");

        (,, uint128 bandLiquidity) = vault.band();
        assertEq(bandLiquidity, 0, "vault's own band record must clear");

        assertApproxEqAbs(vault.navWad(), navAfterOpen, 1e12, "closing a band must be NAV-neutral too");
    }

    function test_closeBand_isNoOpWithNoBandOpen() public {
        (uint256 amount0, uint256 amount1) = vault.closeBand();
        assertEq(amount0, 0);
        assertEq(amount1, 0);
    }

    /// @notice A full open -> close -> reopen cycle (what VaultManager.recenter
    ///         actually drives) must round-trip tvlA/tvlB correctly with no
    ///         real trade in between.
    function test_openThenCloseThenReopen_roundTripsTvl() public {
        uint256 tvlABefore = vault.tvlA();
        uint256 tvlBBefore = vault.tvlB();

        vault.openBand(-600, 600, 1_000e18, 1_000e18);
        vault.closeBand();
        vault.openBand(-600, 600, 1_000e18, 1_000e18);
        vault.closeBand();

        assertApproxEqAbs(vault.tvlA(), tvlABefore, 1e12, "tvlA must round-trip after a full open/close cycle");
        assertApproxEqAbs(vault.tvlB(), tvlBBefore, 1e12, "tvlB must round-trip after a full open/close cycle");
    }
}
