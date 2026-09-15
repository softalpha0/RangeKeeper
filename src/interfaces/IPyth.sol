// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IPyth (minimal)
/// @notice Just the read path Rangekeeper needs. Field layout mirrors the real
///         `PythStructs.Price` / `IPyth.getPriceNoOlderThan` from the maintained
///         `pythnetwork/pyth-sdk-solidity` package exactly, so this ABI-matches
///         the real deployed contract without vendoring the whole SDK.
///         Source checked against: pyth-crosschain/target_chains/ethereum/sdk/solidity
interface IPyth {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    /// @notice Reverts if the price is older than `age` seconds.
    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (Price memory price);

    /// @notice Pushes Hermes-signed price update(s) on-chain. Caller must send
    ///         at least `getUpdateFee(updateData)` wei alongside the call.
    function updatePriceFeeds(bytes[] calldata updateData) external payable;

    /// @notice Fee (in wei) required to submit `updateData` to `updatePriceFeeds`.
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256 feeAmount);
}
