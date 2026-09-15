// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "./FullMath.sol";

/// @title SqrtPriceMath
/// @notice The two `getAmount{0,1}Delta` functions from Uniswap v3's own
///         SqrtPriceMath library — how much of each token a given amount of
///         liquidity represents between two sqrt prices.
/// @dev Ported to Solidity ^0.8.26, and pared down to only the two pure
///      conversion functions this project actually calls (LiquidityMath.sol);
///      the original library's swap-step functions aren't needed here. The
///      one dependency the original had beyond `FullMath` (`UnsafeMath.
///      divRoundingUp`, for the `roundUp` branch) is inlined directly below
///      rather than pulled in as a separate file for one three-line function.
library SqrtPriceMath {
    uint8 internal constant RESOLUTION = 96;
    uint256 internal constant Q96 = 0x1000000000000000000000000;

    /// @dev Equivalent to `UnsafeMath.divRoundingUp` — assumes `b != 0`,
    ///      matching the original's own "unsafe" contract (its only caller
    ///      below already guarantees a non-zero divisor).
    function _divRoundingUp(uint256 a, uint256 b) private pure returns (uint256 result) {
        unchecked {
            result = a / b;
            if (a % b > 0) result += 1;
        }
    }

    /// @notice Gets the amount0 delta between two prices
    /// @dev Calculates liquidity / sqrt(lower) - liquidity / sqrt(upper),
    /// i.e. liquidity * (sqrt(upper) - sqrt(lower)) / (sqrt(upper) * sqrt(lower))
    function getAmount0Delta(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity, bool roundUp)
        internal
        pure
        returns (uint256 amount0)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        uint256 numerator1 = uint256(liquidity) << RESOLUTION;
        uint256 numerator2 = sqrtRatioBX96 - sqrtRatioAX96;

        require(sqrtRatioAX96 > 0);

        return roundUp
            ? _divRoundingUp(FullMath.mulDivRoundingUp(numerator1, numerator2, sqrtRatioBX96), sqrtRatioAX96)
            : FullMath.mulDiv(numerator1, numerator2, sqrtRatioBX96) / sqrtRatioAX96;
    }

    /// @notice Gets the amount1 delta between two prices
    /// @dev Calculates liquidity * (sqrt(upper) - sqrt(lower))
    function getAmount1Delta(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity, bool roundUp)
        internal
        pure
        returns (uint256 amount1)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        return roundUp
            ? FullMath.mulDivRoundingUp(liquidity, sqrtRatioBX96 - sqrtRatioAX96, Q96)
            : FullMath.mulDiv(liquidity, sqrtRatioBX96 - sqrtRatioAX96, Q96);
    }
}
