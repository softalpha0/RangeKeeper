// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IParamsRegistry} from "./interfaces/IParamsRegistry.sol";

/// @title ParamsRegistry
/// @notice Governance's only lever on the system (architecture spec §7: "scoped to
///         parameters, not funds"). Changes are timelocked; nothing here can move
///         deposits, positions, or accrued fees.
contract ParamsRegistry is IParamsRegistry {
    uint256 public constant TIMELOCK_DELAY = 2 days;

    address public admin;
    mapping(uint8 => TierParams) private _params;

    struct PendingUpdate {
        TierParams params;
        uint256 executableAt;
        bool exists;
    }

    mapping(uint8 => PendingUpdate) public pending;

    event UpdateProposed(uint8 indexed tier, TierParams params, uint256 executableAt);
    event UpdateCancelled(uint8 indexed tier);

    error NotAdmin();
    error NoPendingUpdate();
    error TimelockNotElapsed();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    /// @dev Deliberately takes no `_admin` parameter: `new ParamsRegistry(msg.sender)`
    ///      inside a Foundry deploy script would evaluate `msg.sender` in the
    ///      script's own execution frame (Foundry's internal DEFAULT_SENDER),
    ///      not the address actually broadcasting the deployment transaction —
    ///      even though that broadcast transaction's `msg.sender` *as observed
    ///      by this constructor itself* correctly reflects the real deployer,
    ///      per ordinary EVM semantics. Reading `msg.sender` directly here
    ///      avoids that trap entirely.
    constructor() {
        admin = msg.sender;
    }

    function paramsOf(uint8 tier) external view returns (TierParams memory) {
        return _params[tier];
    }

    /// @dev Queues a parameter change; must wait TIMELOCK_DELAY before `execute`.
    ///      Named `setTierParams` per IParamsRegistry, but it only queues — see `execute`.
    function setTierParams(uint8 tier, TierParams calldata params) external onlyAdmin {
        uint256 executableAt = block.timestamp + TIMELOCK_DELAY;
        pending[tier] = PendingUpdate({params: params, executableAt: executableAt, exists: true});
        emit UpdateProposed(tier, params, executableAt);
    }

    function execute(uint8 tier) external {
        PendingUpdate memory p = pending[tier];
        if (!p.exists) revert NoPendingUpdate();
        if (block.timestamp < p.executableAt) revert TimelockNotElapsed();

        TierParams storage stored = _params[tier];
        stored.zStar = p.params.zStar;
        stored.kMax = p.params.kMax;
        stored.sigmaMax = p.params.sigmaMax;
        stored.lcrMin = p.params.lcrMin;
        stored.mStar = p.params.mStar;
        stored.rSanityLow = p.params.rSanityLow;
        stored.rSanityHigh = p.params.rSanityHigh;
        stored.version = p.params.version;

        delete pending[tier];
        emit TierParamsUpdated(tier, stored);
    }

    function cancel(uint8 tier) external onlyAdmin {
        delete pending[tier];
        emit UpdateCancelled(tier);
    }
}
