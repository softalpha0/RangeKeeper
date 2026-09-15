// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IParamsRegistry
/// @notice Timelocked, versioned per-tier risk parameters. See architecture spec §4, §7.
///         `zStar` is the z-score equivalent of the math spec's `theta*` — see RiskMath.sol
///         header for why the contract never evaluates a CDF on-chain.
interface IParamsRegistry {
    struct TierParams {
        uint256 zStar; // WAD — recenter trigger threshold, z-score form (math spec eq. 2). Used by VaultManager.
        uint256 kMax; // WAD — reserved; no capped-injection concept in the recenter design (was eq. 3). Not read by VaultManager v1.
        uint256 sigmaMax; // WAD — volatility ceiling; above this, a recenter closes the band but doesn't reopen (circuit breaker). Used by VaultManager.
        uint256 lcrMin; // WAD — reserved for a future cumulative fee/IL circuit breaker. Not read by VaultManager v1.
        uint256 mStar; // WAD — reserved for a future trend-based stop (was eq. 4). Not read by VaultManager v1.
        uint256 rSanityLow; // WAD — on-chain edge-band sanity check, low side (eq. 1). Used by VaultManager.
        uint256 rSanityHigh; // WAD — on-chain edge-band sanity check, high side (eq. 1). Used by VaultManager.
        uint32 version; // increments on every governance update
    }

    event TierParamsUpdated(uint8 indexed tier, TierParams params);

    function paramsOf(uint8 tier) external view returns (TierParams memory);

    /// @dev Timelocked; only the ParamsRegistry's own governance flow may call this.
    function setTierParams(uint8 tier, TierParams calldata params) external;
}
