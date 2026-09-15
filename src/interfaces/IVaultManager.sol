// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IVaultManager
/// @notice Registry of tier -> vault and the sole entry point for keepers to
///         recenter a vault's own band. Each vault manages exactly one band,
///         itself, against its own fixed Uniswap v3 pool.
interface IVaultManager {
    event VaultRegistered(uint8 indexed tier, address vault);
    event Recentered(
        uint8 indexed tier, int24 oldTickLower, int24 oldTickUpper, int24 newTickLower, int24 newTickUpper, uint128 liquidityAdded
    );
    event RecenterPaused(uint8 indexed tier, int24 oldTickLower, int24 oldTickUpper);

    /// @dev Wired once per tier by governance/deployment — out of scope for this
    ///      interface but needed before recenter works.
    function setVaultForTier(uint8 tier, address vault) external;

    /// @param proof abi.encode(uint256 dMinWad, uint256 sigmaSqrtTWad, uint256 sigmaWad)
    ///        dMin/sigmaSqrtT are only checked (and the on-chain sanity band
    ///        re-verified against the pool's own live `slot0()` price) when the
    ///        vault already has a band open — a vault with no band yet always
    ///        opens one unconditionally, there being nothing to be "near the
    ///        edge" of. sigmaWad, if above the tier's sigmaMax, closes the old
    ///        band but does NOT reopen a new one (circuit breaker: don't chase
    ///        a crash; the vault sits in cash until a later recenter call finds
    ///        calmer conditions).
    function recenter(
        uint8 tier,
        int24 newTickLower,
        int24 newTickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired,
        bytes calldata proof
    ) external;

    /// @dev Same as `recenter`, but pushes `priceUpdateData` to the vault's Pyth
    ///      feed first, atomically, for the identical staleness reason
    ///      `depositWithPriceUpdate` exists. Any `msg.value` this contract
    ///      doesn't need is forwarded back to the caller.
    function recenterWithPriceUpdate(
        uint8 tier,
        int24 newTickLower,
        int24 newTickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired,
        bytes calldata proof,
        bytes[] calldata priceUpdateData
    ) external payable;

    function vaultOfTier(uint8 tier) external view returns (address);
}
