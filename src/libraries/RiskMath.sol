// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title RiskMath
/// @notice On-chain re-validation checks for the Adaptive Liquidity Protocol.
/// @dev Equation numbers in comments refer to this project's internal math
///      spec (not published) — see the README's Specs section.
///
/// Design decision (see README): this library never computes the normal CDF (Φ)
/// on-chain. Urgency (eq. 2) is `U = 2*Phi(-d_min / (sigma*sqrt(T)))`, which is
/// monotonically decreasing in `d_min / (sigma*sqrt(T))`. So instead of storing a
/// probability threshold `theta*` and evaluating Phi on-chain, `ParamsRegistry`
/// stores the equivalent z-score threshold `zStar = Phi^-1(1 - theta*/2)` — computed
/// off-chain, once, per tier. The contract then only compares two pre-scaled
/// ratios. Zero CDF approximation error, zero extra gas.
///
/// All values are WAD fixed-point (1e18 = 1.0) unless noted. Negative quantities
/// (impermanent loss, LCR headroom) use `int256`.
library RiskMath {
    uint256 internal constant WAD = 1e18;

    error DivisionByZero();
    error NegativeSqrtInput();

    // ---------------------------------------------------------------------
    // Fixed-point helpers
    // ---------------------------------------------------------------------

    function mulWad(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b) / WAD;
    }

    function divWad(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) revert DivisionByZero();
        return (a * WAD) / b;
    }

    /// @dev Integer square root (Babylonian method).
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    /// @dev Square root of a WAD number, returned as a WAD number.
    ///      sqrt(x/1e18) * 1e18 == sqrt(x * 1e18), which avoids losing
    ///      precision to integer truncation before scaling.
    function sqrtWad(uint256 xWad) internal pure returns (uint256) {
        return sqrt(xWad * WAD);
    }

    // ---------------------------------------------------------------------
    // eq. 1 — position-in-range
    // ---------------------------------------------------------------------

    /// @param sqrtP  current sqrt-price, WAD
    /// @param sqrtPa lower bound sqrt-price, WAD
    /// @param sqrtPb upper bound sqrt-price, WAD
    /// @return r position-in-range, WAD, 0 at pa / 1 at pb
    function positionInRange(uint256 sqrtP, uint256 sqrtPa, uint256 sqrtPb) internal pure returns (uint256 r) {
        if (sqrtPb <= sqrtPa) revert DivisionByZero();
        if (sqrtP <= sqrtPa) return 0;
        if (sqrtP >= sqrtPb) return WAD;
        return divWad(sqrtP - sqrtPa, sqrtPb - sqrtPa);
    }

    /// @dev Cheap on-chain sanity gate: is `r` genuinely near an edge? Used to
    ///      cross-check a keeper's proof against the hook-cached on-chain price
    ///      (architecture spec's Uniswap v3 integration) without needing a real
    ///      log-distance or CDF computation on-chain — see VaultManager.sol.
    function withinEdgeBand(uint256 rWad, uint256 rLowWad, uint256 rHighWad) internal pure returns (bool) {
        return rWad <= rLowWad || rWad >= rHighWad;
    }

    /// @dev Converts a Uniswap v3 Q64.96 sqrt price into a WAD (1e18) fixed-point
    ///      sqrt price, so it can feed directly into `positionInRange`/`gamma`.
    function sqrtPriceX96ToWad(uint160 sqrtPriceX96) internal pure returns (uint256) {
        return (uint256(sqrtPriceX96) * WAD) / (1 << 96);
    }

    /// @dev Computes floor(liquidity * feeGrowthDeltaX128 / 2^128) without risking
    ///      the silent-overflow that a naive `(liquidity * delta) >> 128` risks —
    ///      `delta` can be a nearly-full uint256 while `liquidity` alone fits in
    ///      128 bits (as v4's own `uint128 liquidity` does), so only `delta` needs
    ///      splitting into halves to keep every intermediate product safely under
    ///      2^256; ordinary checked arithmetic then reverts on the one genuine edge
    ///      case (both operands near their absolute max) instead of wrapping wrong.
    ///      Not currently called by VaultManager v1; kept as a tested utility
    ///      for a possible future per-vault fee accounting need.
    function mulShr128(uint256 liquidity, uint256 feeGrowthDeltaX128) internal pure returns (uint256) {
        uint256 hi = feeGrowthDeltaX128 >> 128;
        uint256 lo = feeGrowthDeltaX128 & type(uint128).max;
        return liquidity * hi + ((liquidity * lo) >> 128);
    }

    // ---------------------------------------------------------------------
    // eq. 2 (trigger only, no CDF — see header)
    // ---------------------------------------------------------------------

    /// @param dMinWad         min(d_lo, d_hi), the log-distance to the nearer edge, WAD
    /// @param sigmaSqrtTWad   sigma * sqrt(T) for the tier's monitoring window, WAD
    /// @param zStarWad        tier's pre-converted trigger threshold, WAD
    /// @return triggered      true if d_min / (sigma*sqrt(T)) <= zStar  (equivalent to U >= theta*)
    function isTriggered(uint256 dMinWad, uint256 sigmaSqrtTWad, uint256 zStarWad) internal pure returns (bool) {
        return divWad(dMinWad, sigmaSqrtTWad) <= zStarWad;
    }

    // ---------------------------------------------------------------------
    // eq. 3 (capped, not the continuous ramp — see header)
    // ---------------------------------------------------------------------

    /// @param requestedWad    the solver's proposed injection amount, WAD (value terms)
    /// @param kMaxWad         tier's injection cap ratio, WAD
    /// @param l0Wad           position's existing liquidity value, WAD
    /// @param cumulativeKWad  sum of k already injected into this position, WAD
    /// @return allowedWad     min(requested, remaining budget under k_max)
    function cappedInjection(uint256 requestedWad, uint256 kMaxWad, uint256 l0Wad, uint256 cumulativeKWad)
        internal
        pure
        returns (uint256 allowedWad)
    {
        if (cumulativeKWad >= kMaxWad) return 0;
        uint256 remainingK = kMaxWad - cumulativeKWad;
        uint256 remainingBudget = mulWad(remainingK, l0Wad);
        return requestedWad < remainingBudget ? requestedWad : remainingBudget;
    }

    // ---------------------------------------------------------------------
    // eq. 5 — concentration amplification factor
    // ---------------------------------------------------------------------

    /// @dev gamma = 1 / (1 - sqrt(pa/pb)). Since sqrt(pa/pb) = sqrtPa/sqrtPb when
    ///      sqrtPa, sqrtPb are themselves sqrt-prices, this reduces to
    ///      sqrtPb / (sqrtPb - sqrtPa) — no extra sqrt needed on-chain.
    function gamma(uint256 sqrtPaWad, uint256 sqrtPbWad) internal pure returns (uint256) {
        if (sqrtPbWad <= sqrtPaWad) revert DivisionByZero();
        return divWad(sqrtPbWad, sqrtPbWad - sqrtPaWad);
    }

    // ---------------------------------------------------------------------
    // eq. 6 — full-range and concentrated impermanent loss
    // ---------------------------------------------------------------------

    /// @param rhoWad current-price / entry-price ratio, WAD
    /// @return ilFullWad IL_full(rho), always <= 0, signed WAD
    function fullRangeIL(uint256 rhoWad) internal pure returns (int256 ilFullWad) {
        uint256 sqrtRho = sqrtWad(rhoWad);
        uint256 term = divWad(2 * sqrtRho, WAD + rhoWad);
        return int256(term) - int256(WAD);
    }

    /// @param gammaWad     from `gamma()`
    /// @param ilFullWad    from `fullRangeIL()`, signed WAD
    /// @return ilConcWad   gamma * IL_full, signed WAD
    function concentratedIL(uint256 gammaWad, int256 ilFullWad) internal pure returns (int256 ilConcWad) {
        bool neg = ilFullWad < 0;
        uint256 mag = uint256(neg ? -ilFullWad : ilFullWad);
        int256 scaled = int256(mulWad(gammaWad, mag));
        return neg ? -scaled : scaled;
    }

    // ---------------------------------------------------------------------
    // eq. 7 — Loss Coverage Ratio
    // ---------------------------------------------------------------------

    /// @param fTWad        cumulative fee yield earned by the injected tranche, WAD
    /// @param ilConcWad    from `concentratedIL()`, signed WAD (negative = loss)
    /// @return lcrWad      1 + f_t - |IL_conc|, signed WAD. Compare against tier's LCR_min.
    function lossCoverageRatio(uint256 fTWad, int256 ilConcWad) internal pure returns (int256 lcrWad) {
        uint256 magnitude = uint256(ilConcWad < 0 ? -ilConcWad : ilConcWad);
        return int256(WAD) + int256(fTWad) - int256(magnitude);
    }

    // ---------------------------------------------------------------------
    // eq. 8 — closed-form liquidation price band
    // ---------------------------------------------------------------------

    /// @param gammaWad from `gamma()`
    /// @param cWad     1 + f_t - LCR_min, WAD (the loss budget remaining before liquidation)
    /// @return rhoUpWad   upper liquidation price ratio, WAD
    /// @return rhoDownWad lower liquidation price ratio, WAD
    function liquidationRatios(uint256 gammaWad, uint256 cWad)
        internal
        pure
        returns (uint256 rhoUpWad, uint256 rhoDownWad)
    {
        // A = 1 - c/gamma
        uint256 cOverGamma = divWad(cWad, gammaWad);
        if (cOverGamma >= WAD) revert NegativeSqrtInput(); // already past liquidation
        uint256 aWad = WAD - cOverGamma;

        // discriminant = 1 - A^2
        uint256 aSquared = mulWad(aWad, aWad);
        if (aSquared >= WAD) revert NegativeSqrtInput();
        uint256 discriminant = WAD - aSquared;
        uint256 sqrtDisc = sqrtWad(discriminant);

        uint256 x1 = divWad(WAD + sqrtDisc, aWad);
        uint256 x2 = sqrtDisc >= WAD ? 0 : divWad(WAD - sqrtDisc, aWad);

        rhoUpWad = mulWad(x1, x1);
        rhoDownWad = mulWad(x2, x2);
    }

    // ---------------------------------------------------------------------
    // eq. 10 — fee split by composition
    // ---------------------------------------------------------------------

    /// @param totalFeesWad protocol-denominated fees earned by the position, WAD
    /// @param lProtocolWad protocol-owned liquidity in the position, WAD
    /// @param lUserWad     user-owned liquidity in the position, WAD
    /// @return protocolShareWad
    function feeSplit(uint256 totalFeesWad, uint256 lProtocolWad, uint256 lUserWad)
        internal
        pure
        returns (uint256 protocolShareWad)
    {
        uint256 total = lProtocolWad + lUserWad;
        if (total == 0) return 0;
        return (totalFeesWad * lProtocolWad) / total;
    }
}
