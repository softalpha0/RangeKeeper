// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IUniswapV3Pool} from "v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";

interface IERC20Like {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title V3TestRouter
/// @notice Minimal swap router for tests/scripts: performs a swap against a
///         real Uniswap v3 pool and pays what's owed by pulling from whichever
///         trader address is encoded in the swap's callback data, via a
///         pre-existing approval. Exists because production `PairVault` never
///         needs to swap (it's an LP, not a trader) — real swap volume in
///         tests/demos has to originate somewhere else.
contract V3TestRouter is IUniswapV3SwapCallback {
    function swap(IUniswapV3Pool pool, address trader, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        external
        returns (int256 amount0, int256 amount1)
    {
        return pool.swap(trader, zeroForOne, amountSpecified, sqrtPriceLimitX96, abi.encode(trader, pool));
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        (address trader, IUniswapV3Pool pool) = abi.decode(data, (address, IUniswapV3Pool));
        require(msg.sender == address(pool), "not pool");
        if (amount0Delta > 0) IERC20Like(pool.token0()).transferFrom(trader, msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20Like(pool.token1()).transferFrom(trader, msg.sender, uint256(amount1Delta));
    }
}
