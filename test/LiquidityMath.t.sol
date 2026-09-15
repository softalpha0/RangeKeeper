// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SqrtPriceMath} from "../src/libraries/SqrtPriceMath.sol";
import {LiquidityMath} from "../src/libraries/LiquidityMath.sol";

/// @notice Verifies LiquidityMath by round-tripping through the real
///         SqrtPriceMath it's built on — deriving liquidity from an amount,
///         then checking that liquidity reconstructs (approximately, to
///         rounding) the same amount, rather than trusting the port by
///         inspection.
contract LiquidityMathTest is Test {
    // Same range as the math spec's worked example: sqrt(2700)..sqrt(3300)
    // in Q96, scaled arbitrarily (Q96 fixed point) for a realistic magnitude.
    uint160 constant SQRT_PA = 3_998_000_000_000_000_000_000_000; // ~ sqrt(2700) * 2^96 scaled
    uint160 constant SQRT_PB = 4_422_000_000_000_000_000_000_000; // ~ sqrt(3300) * 2^96 scaled
    uint160 constant SQRT_P_CENTERED = 4_211_000_000_000_000_000_000_000; // between the two

    function test_getLiquidityForAmount0_roundTrips() public pure {
        uint256 amount0 = 1_000e18;
        uint128 liquidity = LiquidityMath.getLiquidityForAmount0(SQRT_PA, SQRT_PB, amount0);
        uint256 reconstructed = SqrtPriceMath.getAmount0Delta(SQRT_PA, SQRT_PB, liquidity, false);

        // getLiquidityForAmount0 rounds liquidity down (mulDiv floors), so the
        // reconstructed amount is always <= the original — never more than
        // originally specified, and never off by more than a rounding unit.
        assertLe(reconstructed, amount0);
        assertApproxEqRel(reconstructed, amount0, 0.0001e18); // within 0.01%
    }

    function test_getLiquidityForAmount1_roundTrips() public pure {
        uint256 amount1 = 1_000e18;
        uint128 liquidity = LiquidityMath.getLiquidityForAmount1(SQRT_PA, SQRT_PB, amount1);
        uint256 reconstructed = SqrtPriceMath.getAmount1Delta(SQRT_PA, SQRT_PB, liquidity, false);

        assertLe(reconstructed, amount1);
        assertApproxEqRel(reconstructed, amount1, 0.0001e18);
    }

    function test_getLiquidityForAmounts_pricedAtEdge_usesOnlyThatSideAmount0() public pure {
        // Current price at or below the range -> position is 100% token0, so
        // liquidity should be driven entirely by amount0 (eq. 1, r=0 case).
        uint128 liquidity = LiquidityMath.getLiquidityForAmounts(SQRT_PA, SQRT_PA, SQRT_PB, 500e18, 999_999e18);
        uint128 expected = LiquidityMath.getLiquidityForAmount0(SQRT_PA, SQRT_PB, 500e18);
        assertEq(liquidity, expected);
    }

    function test_getLiquidityForAmounts_pricedAtEdge_usesOnlyThatSideAmount1() public pure {
        // Current price at or above the range -> position is 100% token1.
        uint128 liquidity = LiquidityMath.getLiquidityForAmounts(SQRT_PB, SQRT_PA, SQRT_PB, 999_999e18, 500e18);
        uint128 expected = LiquidityMath.getLiquidityForAmount1(SQRT_PA, SQRT_PB, 500e18);
        assertEq(liquidity, expected);
    }

    function test_getLiquidityForAmounts_centered_takesTheBindingConstraint() public pure {
        // Plenty of token1, scarce token0 -> amount0 should bind.
        uint128 liquidity =
            LiquidityMath.getLiquidityForAmounts(SQRT_P_CENTERED, SQRT_PA, SQRT_PB, 10e18, 1_000_000e18);
        uint128 fromAmount0 = LiquidityMath.getLiquidityForAmount0(SQRT_P_CENTERED, SQRT_PB, 10e18);
        uint128 fromAmount1 = LiquidityMath.getLiquidityForAmount1(SQRT_PA, SQRT_P_CENTERED, 1_000_000e18);

        assertEq(liquidity, fromAmount0);
        assertLt(fromAmount0, fromAmount1); // confirms amount0 really was the binding side
    }

    // -----------------------------------------------------------------
    // getAmountsForLiquidity — the inverse direction, added for PairVault's
    // navWad() to price an open band without closing it first.
    // -----------------------------------------------------------------

    function test_getAmountsForLiquidity_roundTripsThroughGetLiquidityForAmounts_whenCentered() public pure {
        (uint256 amount0, uint256 amount1) =
            LiquidityMath.getAmountsForLiquidity(SQRT_P_CENTERED, SQRT_PA, SQRT_PB, 1_000_000e18);
        assertGt(amount0, 0, "centered price should need both sides");
        assertGt(amount1, 0);

        // Reconstructing liquidity from those very amounts must recover the
        // same figure we started from (to rounding) — the round trip that
        // matters for navWad(), which never sees liquidity as an input, only
        // as PairVault's own stored state.
        uint128 reconstructed = LiquidityMath.getLiquidityForAmounts(SQRT_P_CENTERED, SQRT_PA, SQRT_PB, amount0, amount1);
        assertApproxEqRel(reconstructed, 1_000_000e18, 0.0001e18);
    }

    function test_getAmountsForLiquidity_belowRange_isAllToken0() public pure {
        (uint256 amount0, uint256 amount1) = LiquidityMath.getAmountsForLiquidity(SQRT_PA, SQRT_PA, SQRT_PB, 1_000e18);
        assertGt(amount0, 0);
        assertEq(amount1, 0, "price at/below the range should hold zero token1");
    }

    function test_getAmountsForLiquidity_aboveRange_isAllToken1() public pure {
        (uint256 amount0, uint256 amount1) = LiquidityMath.getAmountsForLiquidity(SQRT_PB, SQRT_PA, SQRT_PB, 1_000e18);
        assertEq(amount0, 0, "price at/above the range should hold zero token0");
        assertGt(amount1, 0);
    }

    function test_getAmountsForLiquidity_zeroLiquidityIsZeroValue() public pure {
        (uint256 amount0, uint256 amount1) = LiquidityMath.getAmountsForLiquidity(SQRT_P_CENTERED, SQRT_PA, SQRT_PB, 0);
        assertEq(amount0, 0);
        assertEq(amount1, 0);
    }
}
