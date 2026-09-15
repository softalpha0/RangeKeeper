// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "./FullMath.sol";
import {SqrtPriceMath} from "./SqrtPriceMath.sol";

/// @title LiquidityMath
/// @notice Converts token amounts into a Uniswap v3 position's `liquidity`, for
///         actually opening a vault's band (PairVault.openBand) — and back
///         again, for pricing an already-open one (PairVault.navWad).
/// @dev The Uniswap v3 whitepaper (§6.29-6.30) defines both directions of this
///      conversion; v3-periphery ships them as `LiquidityAmounts.sol`, but that
///      package's own dependency chain isn't something a vault contract should
///      pull in wholesale just for two pure functions. This ports the same
///      formulas directly against v3-core's own production `FullMath.mulDiv`
///      and `SqrtPriceMath.getAmount{0,1}Delta` — verified by round-tripping
///      through those same real functions in `test/LiquidityMath.t.sol`, not
///      just written by inspection.
library LiquidityMath {
    uint256 internal constant Q96 = 1 << 96;

    /// @notice Liquidity that consumes exactly `amount0` between two sqrt prices.
    function getLiquidityForAmount0(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount0)
        internal
        pure
        returns (uint128 liquidity)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        uint256 intermediate = FullMath.mulDiv(sqrtRatioAX96, sqrtRatioBX96, Q96);
        liquidity = toUint128(FullMath.mulDiv(amount0, intermediate, sqrtRatioBX96 - sqrtRatioAX96));
    }

    /// @notice Liquidity that consumes exactly `amount1` between two sqrt prices.
    function getLiquidityForAmount1(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount1)
        internal
        pure
        returns (uint128 liquidity)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        liquidity = toUint128(FullMath.mulDiv(amount1, Q96, sqrtRatioBX96 - sqrtRatioAX96));
    }

    /// @notice The largest liquidity deliverable from at most `amount0` of
    ///         token0 and `amount1` of token1 at the current price, without
    ///         exceeding either — the standard "how much can I actually
    ///         provide" calculation for a range that may not yet be centered
    ///         on the current price.
    function getLiquidityForAmounts(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        if (sqrtRatioX96 <= sqrtRatioAX96) {
            liquidity = getLiquidityForAmount0(sqrtRatioAX96, sqrtRatioBX96, amount0);
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            uint128 liquidity0 = getLiquidityForAmount0(sqrtRatioX96, sqrtRatioBX96, amount0);
            uint128 liquidity1 = getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioX96, amount1);
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else {
            liquidity = getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioBX96, amount1);
        }
    }

    /// @notice The token0/token1 amounts `liquidity` currently represents between
    ///          two sqrt prices, at the live price — the inverse of
    ///          `getLiquidityForAmounts`.
    /// @dev Needed so a vault holding an open band can price its own NAV without
    ///      closing the position first — see PairVault.navWad(). Before this
    ///      existed, NAV only ever summed idle token balances, silently
    ///      understating vault value by the entire deployed band the moment any
    ///      capital left for the pool (harmless while injections were a small,
    ///      capped slice of NAV; a real mispricing once most of the vault's
    ///      value lives in its own band by design).
    function getAmountsForLiquidity(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        if (sqrtRatioX96 <= sqrtRatioAX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtRatioAX96, sqrtRatioBX96, liquidity, false);
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtRatioX96, sqrtRatioBX96, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtRatioAX96, sqrtRatioX96, liquidity, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtRatioAX96, sqrtRatioBX96, liquidity, false);
        }
    }

    function toUint128(uint256 x) internal pure returns (uint128 y) {
        require(x <= type(uint128).max, "LiquidityMath: overflow");
        y = uint128(x);
    }
}
