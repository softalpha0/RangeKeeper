// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice The real slice of Aave V3's IPool this project needs — a plain
///         supply/withdraw money market, nothing else. Matches Aave's own
///         published interface exactly (see aave-v3-core's IPool.sol /
///         docs.aave.com/developers), not vendored in full since a handful of
///         functions is all AaveV3YieldAdapter calls.
interface IAaveV3Pool {
    /// @param referralCode Aave's referral program id — 0 is "none", the only
    ///        value this project has any reason to use.
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    /// @param to Where the withdrawn underlying is sent.
    /// @return withdrawn The actual amount withdrawn (Aave itself may cap this
    ///         below `amount` if the caller passes more than they're owed).
    function withdraw(address asset, uint256 amount, address to) external returns (uint256 withdrawn);
}

/// @notice Aave V3's PoolDataProvider — used only to resolve an asset's aToken
///         address, so this project never has to hardcode one per reserve.
interface IAaveV3PoolDataProvider {
    function getReserveTokensAddresses(address asset)
        external
        view
        returns (address aTokenAddress, address stableDebtTokenAddress, address variableDebtTokenAddress);
}
