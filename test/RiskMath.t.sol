// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Requires: forge install foundry-rs/forge-std
import {Test} from "forge-std/Test.sol";
import {RiskMath} from "../src/libraries/RiskMath.sol";

/// @notice Checks RiskMath against the worked example in the math spec §7
///         (ETH/USDC, p0=3000, pa=2700, pb=3300, sigma=65%, T=3 days).
contract RiskMathTest is Test {
    uint256 constant WAD = 1e18;

    function test_positionInRange_centeredAtStart() public pure {
        // sqrt(2700)=51.96, sqrt(3300)=57.45, sqrt(3000)=54.77 -> r ~= 0.512
        uint256 sqrtPa = 51.96e18;
        uint256 sqrtPb = 57.45e18;
        uint256 sqrtP = 54.77e18;

        uint256 r = RiskMath.positionInRange(sqrtP, sqrtPa, sqrtPb);
        assertApproxEqRel(r, 0.512e18, 0.02e18); // within 2%
    }

    function test_isTriggered_matchesWorkedExample() public pure {
        // d_min/(sigma*sqrt(T)) = 0.047/0.059 = 0.79 -> U=2*Phi(-0.79)=0.43
        // theta*=0.30 -> zStar = Phi^-1(1-0.15) = Phi^-1(0.85) ~= 1.036
        uint256 dMinWad = 0.047e18;
        uint256 sigmaSqrtTWad = 0.059e18;
        uint256 zStarWad = 1.036e18;

        // 0.047/0.059 = 0.797, which is < 1.036 -> triggered
        assertTrue(RiskMath.isTriggered(dMinWad, sigmaSqrtTWad, zStarWad));
    }

    function test_cappedInjection_matchesWorkedExample() public pure {
        // 6.5% of a $50,000 position ~= $3,250, well under a $500k vault at 40% util.
        uint256 requested = 3_250e18;
        uint256 kMax = 0.35e18;
        uint256 l0 = 50_000e18;
        uint256 cumulativeK = 0;

        uint256 allowed = RiskMath.cappedInjection(requested, kMax, l0, cumulativeK);
        assertEq(allowed, requested); // under the 0.35*50000 = 17500 cap
    }

    function test_gamma_matchesWorkedExample() public pure {
        // gamma ~= 10.48 for pa=2700, pb=3300
        uint256 sqrtPa = 51.96e18;
        uint256 sqrtPb = 57.45e18;

        uint256 g = RiskMath.gamma(sqrtPa, sqrtPb);
        assertApproxEqRel(g, 10.48e18, 0.02e18);
    }

    function test_liquidationBand_matchesWorkedExample() public pure {
        // gamma~=10.48, f_t=0.03, LCR_min=0.90 -> c=0.13
        // -> rho_up ~= 1.373, rho_down ~= 0.728
        uint256 g = 10.48e18;
        uint256 c = 0.13e18;

        (uint256 rhoUp, uint256 rhoDown) = RiskMath.liquidationRatios(g, c);
        assertApproxEqRel(rhoUp, 1.373e18, 0.02e18);
        assertApproxEqRel(rhoDown, 0.728e18, 0.02e18);
    }

    function test_sqrtPriceX96ToWad_convertsCorrectly() public pure {
        // sqrtPriceX96 for price=1.0 is exactly 2^96 (Q64.96 representation of 1.0)
        uint160 sqrtPriceX96AtOne = uint160(1) << 96;
        uint256 wad = RiskMath.sqrtPriceX96ToWad(sqrtPriceX96AtOne);
        assertEq(wad, WAD);
    }

    function test_withinEdgeBand_flagsOnlyNearEdges() public pure {
        uint256 rLow = 0.15e18;
        uint256 rHigh = 0.85e18;

        assertTrue(RiskMath.withinEdgeBand(0.05e18, rLow, rHigh)); // near lower edge
        assertTrue(RiskMath.withinEdgeBand(0.95e18, rLow, rHigh)); // near upper edge
        assertFalse(RiskMath.withinEdgeBand(0.50e18, rLow, rHigh)); // centered — not a sanity match
    }

    function test_mulShr128_exactAtOneAndOneHalf() public pure {
        uint256 liquidity = 1e18;

        // feeGrowthDelta = 2^128 (exactly 1.0 in Q128) -> result == liquidity
        assertEq(RiskMath.mulShr128(liquidity, uint256(1) << 128), liquidity);

        // feeGrowthDelta = 2^127 (exactly 0.5 in Q128) -> result == liquidity / 2, exact
        assertEq(RiskMath.mulShr128(liquidity, uint256(1) << 127), liquidity / 2);
    }

    function test_mulShr128_doesNotOverflowNearMaxOperands() public pure {
        // The case a naive (liquidity * delta) >> 128 would silently wrap on:
        // liquidity at its real-world uint128 ceiling, delta at uint256 max.
        uint256 liquidity = type(uint128).max; // a = 2^128 - 1
        uint256 delta = type(uint256).max; // b = 2^256 - 1

        // Hand-derived exact expected value (not a fuzzy bound — an earlier
        // version of this test asserted result < liquidity * 2, which was
        // simply wrong: delta near 2^256 represents ~2^128 in Q128 terms, not
        // 2, so that bound failed even though mulShr128 itself was correct):
        //   a*b = (2^128-1)(2^256-1) = 2^384 - 2^256 - 2^128 + 1
        //   floor(a*b / 2^128) = 2^256 - 2^128 - 1
        uint256 expected = type(uint256).max - (uint256(1) << 128);

        assertEq(RiskMath.mulShr128(liquidity, delta), expected);
    }

    function test_feeSplit_matchesFounderExample() public pure {
        // 50:50 composition on $10 fees -> $5/$5
        uint256 s = RiskMath.feeSplit(10e18, 5e18, 5e18);
        assertEq(s, 5e18);

        // 70:30 protocol-weighted composition on $10 fees -> $7 protocol
        uint256 s2 = RiskMath.feeSplit(10e18, 7e18, 3e18);
        assertEq(s2, 7e18);
    }
}
