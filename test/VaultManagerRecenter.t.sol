// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IUniswapV3Factory} from "v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {VaultManager} from "../src/VaultManager.sol";
import {ParamsRegistry} from "../src/ParamsRegistry.sol";
import {PairVault} from "../src/PairVault.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {IParamsRegistry} from "../src/interfaces/IParamsRegistry.sol";
import {MockERC20, MockPyth} from "./PairVault.t.sol";
import {V3TestRouter} from "./utils/V3TestRouter.sol";

/// @notice Full, real end-to-end test of `recenterWithPriceUpdate` — real
///         VaultManager, real PairVault, a real deployed Uniswap v3 factory
///         and pool, real swaps to move price, MockPyth standing in only for
///         the oracle. Exists specifically to prove the excess-value refund
///         chain works all the way through (PairVault -> VaultManager -> the
///         real caller), which test/VaultManager.t.sol's mock-vault suite
///         can't exercise (its mock ignores msg.value entirely).
contract VaultManagerRecenterTest is Test {
    IUniswapV3Factory factory;
    IUniswapV3Pool pool;
    V3TestRouter router;
    MockERC20 token0;
    MockERC20 token1;
    MockPyth pyth;
    ParamsRegistry paramsRegistry;
    VaultManager vaultManager;
    PairVault vault;

    bytes32 constant FEED0 = bytes32(uint256(20));
    bytes32 constant FEED1 = bytes32(uint256(21));
    uint8 constant TIER = 1;
    int24 constant TICK_LO = -600;
    int24 constant TICK_HI = 600;

    address depositor = address(0xD0);
    address trader = address(0x7EADE);
    address keeper = address(0x501589); // the real caller of recenterWithPriceUpdate

    function setUp() public {
        factory = IUniswapV3Factory(vm.deployCode("UniswapV3Factory.sol"));
        router = new V3TestRouter();

        MockERC20 a = new MockERC20("A", 18);
        MockERC20 b = new MockERC20("B", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);

        pyth = new MockPyth();
        pyth.setPrice(FEED0, 1e8, -8);
        pyth.setPrice(FEED1, 1e8, -8);
        pyth.setUpdateFee(3);

        paramsRegistry = new ParamsRegistry();
        vaultManager = new VaultManager(address(paramsRegistry));

        pool = IUniswapV3Pool(factory.createPool(address(token0), address(token1), 3000));
        pool.initialize(uint160(1) << 96); // price = 1.0

        vault = new PairVault(
            address(token0), address(token1), 18, 18, FEED0, FEED1, address(pyth), address(pool), TIER, address(vaultManager), address(0x7EA5), address(0)
        );
        vaultManager.setVaultForTier(TIER, address(vault));

        token0.mint(depositor, 10_000e18);
        token1.mint(depositor, 10_000e18);
        vm.startPrank(depositor);
        vault.deposit(address(token0), 10_000e18);
        vault.deposit(address(token1), 10_000e18);
        vm.stopPrank();

        // MockERC20's transferFrom doesn't enforce allowance (see
        // test/PairVault.t.sol), so no approve() call is needed here.
        token0.mint(trader, 1_000_000e18);
        token1.mint(trader, 1_000_000e18);

        IParamsRegistry.TierParams memory p = IParamsRegistry.TierParams({
            zStar: 0.67449e18,
            kMax: 0,
            sigmaMax: 0.08e18,
            lcrMin: 0,
            mStar: 0,
            rSanityLow: 0.35e18,
            rSanityHigh: 0.65e18,
            version: 1
        });
        paramsRegistry.setTierParams(TIER, p);
        vm.warp(block.timestamp + paramsRegistry.TIMELOCK_DELAY() + 1);
        paramsRegistry.execute(TIER);

        vm.deal(keeper, 1 ether);
    }

    function _swap(bool zeroForOne, int256 amountSpecified) internal {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
        vm.prank(trader);
        router.swap(pool, trader, zeroForOne, amountSpecified, limit);
    }

    function _positionLiquidity(int24 tickLower, int24 tickUpper) internal view returns (uint128 liquidity) {
        bytes32 key = keccak256(abi.encodePacked(address(vault), tickLower, tickUpper));
        (liquidity,,,,) = pool.positions(key);
    }

    function _urgentProof() internal pure returns (bytes memory) {
        // ratio 0.03/0.06 = 0.5 <= zStar 0.67449 -> triggered; sigma 0.06 <= sigmaMax 0.08
        return abi.encode(uint256(0.03e18), uint256(0.06e18), uint256(0.06e18));
    }

    function test_recenterWithPriceUpdate_opensFirstBand_thenMovesItForReal() public {
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = hex"00";

        // 1. First-ever band: opens unconditionally.
        vm.prank(keeper);
        vaultManager.recenterWithPriceUpdate{value: 1000}(
            TIER, TICK_LO, TICK_HI, 1_000e18, 1_000e18, _urgentProof(), updateData
        );

        (,, uint128 liq1) = vault.band();
        assertGt(liq1, 0, "first band must actually hold real liquidity");
        uint128 poolLiq1 = _positionLiquidity(TICK_LO, TICK_HI);
        assertEq(poolLiq1, liq1, "PairVault's own record must match the pool's");

        // 2. Refund chain: only the exact 3-wei fee should be spent.
        uint256 keeperBalanceBefore = keeper.balance;
        vm.warp(block.timestamp + vaultManager.MIN_RECENTER_INTERVAL() + 1);

        // Push price toward the upper edge with a real swap. Concentrated
        // liquidity in a narrow +/-600-tick band is deep relative to a
        // full-range pool of the same token amounts, so this needs to be
        // much larger than a naive "a few percent of TVL" guess to actually
        // cross the sanity band's r >= 0.65 threshold.
        _swap(false, -400e18);
        pyth.setPrice(FEED0, 1e8, -8); // keep both feeds fresh through the warp
        pyth.setPrice(FEED1, 1e8, -8);

        vm.prank(keeper);
        vaultManager.recenterWithPriceUpdate{value: 1000}(
            TIER, TICK_LO + 60, TICK_HI + 60, 500e18, 500e18, _urgentProof(), updateData
        );

        (,, uint128 liq2) = vault.band();
        assertGt(liq2, 0, "recenter must have opened a new band");
        uint128 oldPoolLiq = _positionLiquidity(TICK_LO, TICK_HI);
        assertEq(oldPoolLiq, 0, "the OLD band must actually be closed in the pool, not just replaced in bookkeeping");

        assertEq(
            keeperBalanceBefore - keeper.balance,
            3,
            "only the exact Pyth fee (3) should be spent across both calls, the rest refunded"
        );
        assertEq(address(vaultManager).balance, 0, "VaultManager must not retain any leftover ETH between calls");
    }

    function test_recenter_circuitBreakerPausesForRealThenResumes() public {
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = hex"00";

        vm.prank(keeper);
        vaultManager.recenterWithPriceUpdate{value: 1000}(
            TIER, TICK_LO, TICK_HI, 1_000e18, 1_000e18, _urgentProof(), updateData
        );

        vm.warp(block.timestamp + vaultManager.MIN_RECENTER_INTERVAL() + 1);
        _swap(false, -400e18);
        pyth.setPrice(FEED0, 1e8, -8);
        pyth.setPrice(FEED1, 1e8, -8);

        // sigma above sigmaMax (0.08e18) -> close, don't reopen.
        bytes memory volatile = abi.encode(uint256(0.03e18), uint256(0.06e18), uint256(0.15e18));
        vm.prank(keeper);
        vaultManager.recenterWithPriceUpdate{value: 1000}(TIER, TICK_LO + 60, TICK_HI + 60, 0, 0, volatile, updateData);

        (,, uint128 liqAfterPause) = vault.band();
        assertEq(liqAfterPause, 0, "circuit breaker must close and NOT reopen");
        assertTrue(vaultManager.paused(TIER));
        assertGt(vault.tvlA(), 0, "freed capital must sit as real idle balance, not be lost");

        // Resume once calm.
        vm.warp(block.timestamp + vaultManager.MIN_RECENTER_INTERVAL() + 1);
        pyth.setPrice(FEED0, 1e8, -8);
        pyth.setPrice(FEED1, 1e8, -8);
        bytes memory calm = abi.encode(uint256(0.03e18), uint256(0.06e18), uint256(0.05e18));
        vm.prank(keeper);
        vaultManager.recenterWithPriceUpdate{value: 1000}(TIER, TICK_LO, TICK_HI, 500e18, 500e18, calm, updateData);

        (,, uint128 liqAfterResume) = vault.band();
        assertGt(liqAfterResume, 0, "must have reopened a fresh band");
        assertFalse(vaultManager.paused(TIER));
    }
}
