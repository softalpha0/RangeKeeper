// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IUniswapV3Pool} from "v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "./libraries/TickMath.sol";

import {IVaultManager} from "./interfaces/IVaultManager.sol";
import {IPairVault} from "./interfaces/IPairVault.sol";
import {IParamsRegistry} from "./interfaces/IParamsRegistry.sol";
import {RiskMath} from "./libraries/RiskMath.sol";

/// @title VaultManager
/// @notice Registry of tier -> vault, and the sole keeper entry point for
///         recentering a vault's own band. Every state-changing call
///         re-derives its justification from RiskMath rather than trusting a
///         keeper's proof at face value — see RiskMath.sol header for the
///         CDF-avoidance design.
/// @dev Manages each vault's OWN band directly — recentering it as price
///      moves. A Uniswap v3 position is identified by (owner, tickLower,
///      tickUpper), so a vault only ever needs to manage the one band it
///      fully owns against its own fixed pool. The sanity check below reads
///      that pool's `slot0()` directly at recenter time — a plain public view
///      call, not a cached value — so there's no separate price-reporting
///      contract to trust or keep wired correctly.
contract VaultManager is IVaultManager {
    IParamsRegistry public immutable paramsRegistry;
    address public admin;

    // Anti-thrashing: a keeper can grief by recentering constantly, paying real
    // slippage each time out of depositors' pockets for no benefit. A flat
    // per-tier cooldown is the source paper's "keeper griefing" containment,
    // kept simple for v1 rather than a full daily-recenter-count cap.
    uint256 public constant MIN_RECENTER_INTERVAL = 5 minutes;

    mapping(uint8 => address) public vaultOfTier;
    mapping(uint8 => uint256) public lastRecenterAt;
    // True after a circuit-breaker pause (band closed, not reopened) until a
    // later recenter finds volatility back under the tier's ceiling. A vault
    // that has simply never opened a band yet is NOT paused — it opens
    // unconditionally the first time, there being no edge to be "near" yet.
    mapping(uint8 => bool) public paused;

    error UnknownTier();
    error NotTriggered();
    error OutOfSanityBand();
    error TooSoon();
    error StillPaused();
    error NotAdmin();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    /// @dev Deliberately takes no `_admin` parameter — see ParamsRegistry's own
    ///      constructor comment: `new VaultManager(msg.sender)` from inside a
    ///      Foundry script would capture the script's own execution-frame
    ///      msg.sender (Foundry's DEFAULT_SENDER), not the address actually
    ///      broadcasting the deployment. Reading msg.sender directly here
    ///      avoids that trap.
    constructor(address _paramsRegistry) {
        paramsRegistry = IParamsRegistry(_paramsRegistry);
        admin = msg.sender;
    }

    /// @dev Needed so `PairVault.pushPriceUpdate`'s excess-value refund can land
    ///      here before `recenterWithPriceUpdate` forwards it to the real
    ///      caller — otherwise any caller sending more than the exact Pyth fee
    ///      (the normal case) would revert the whole recenter.
    receive() external payable {}

    /// @dev Wired once per tier by governance/deployment. admin-only: this is
    ///      the mapping every recenter and every solver read trusts blindly —
    ///      previously callable by anyone, which meant any address could
    ///      silently redirect a tier at a contract of its own choosing.
    function setVaultForTier(uint8 tier, address vault) external onlyAdmin {
        vaultOfTier[tier] = vault;
        emit VaultRegistered(tier, vault);
    }

    function recenter(
        uint8 tier,
        int24 newTickLower,
        int24 newTickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired,
        bytes calldata proof
    ) external {
        _recenter(tier, newTickLower, newTickUpper, amount0Desired, amount1Desired, proof);
    }

    /// @dev Same as `recenter`, but pushes `priceUpdateData` to the vault's
    ///      Pyth feed *first* — the same fix `depositWithPriceUpdate` applies,
    ///      for the identical staleness reason, but ordered so the fresh price
    ///      is in place before the sanity check reads it, not just before the
    ///      final `openBand` call.
    function recenterWithPriceUpdate(
        uint8 tier,
        int24 newTickLower,
        int24 newTickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired,
        bytes calldata proof,
        bytes[] calldata priceUpdateData
    ) external payable {
        address vault = _vaultFor(tier);
        IPairVault(vault).pushPriceUpdate{value: msg.value}(priceUpdateData);

        _recenter(tier, newTickLower, newTickUpper, amount0Desired, amount1Desired, proof);

        uint256 leftover = address(this).balance;
        if (leftover > 0) {
            (bool ok,) = msg.sender.call{value: leftover}("");
            require(ok, "refund failed");
        }
    }

    /// @param proof abi.encode(uint256 dMinWad, uint256 sigmaSqrtTWad, uint256 sigmaWad)
    function _recenter(
        uint8 tier,
        int24 newTickLower,
        int24 newTickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired,
        bytes calldata proof
    ) internal {
        address vaultAddr = _vaultFor(tier);
        IPairVault vault = IPairVault(vaultAddr);
        IParamsRegistry.TierParams memory p = paramsRegistry.paramsOf(tier);

        (int24 oldTickLower, int24 oldTickUpper, uint128 oldLiquidity) = vault.band();
        (uint256 dMinWad, uint256 sigmaSqrtTWad, uint256 sigmaWad) = abi.decode(proof, (uint256, uint256, uint256));

        if (oldLiquidity > 0) {
            // A band is open — only move it if it's genuinely time to.
            if (!RiskMath.isTriggered(dMinWad, sigmaSqrtTWad, p.zStar)) revert NotTriggered();

            (uint160 sqrtPriceX96,,,,,,) = vault.pool().slot0();
            uint256 currentSqrtPWad = RiskMath.sqrtPriceX96ToWad(sqrtPriceX96);
            uint256 sqrtPa = RiskMath.sqrtPriceX96ToWad(TickMath.getSqrtRatioAtTick(oldTickLower));
            uint256 sqrtPb = RiskMath.sqrtPriceX96ToWad(TickMath.getSqrtRatioAtTick(oldTickUpper));
            uint256 r = RiskMath.positionInRange(currentSqrtPWad, sqrtPa, sqrtPb);
            if (!RiskMath.withinEdgeBand(r, p.rSanityLow, p.rSanityHigh)) revert OutOfSanityBand();

            if (block.timestamp < lastRecenterAt[tier] + MIN_RECENTER_INTERVAL) revert TooSoon();

            vault.closeBand();
            lastRecenterAt[tier] = block.timestamp;

            // Circuit breaker: too volatile to chase right now. Close and sit
            // out — do not reopen — until a later call finds calmer conditions.
            if (sigmaWad > p.sigmaMax) {
                paused[tier] = true;
                emit RecenterPaused(tier, oldTickLower, oldTickUpper);
                return;
            }
        } else if (paused[tier]) {
            // Was sitting out after a circuit-breaker close. Only resume once
            // volatility is genuinely back under the ceiling — otherwise this
            // would just reopen unconditionally on the very next call, which
            // defeats the whole point of pausing.
            if (sigmaWad > p.sigmaMax) revert StillPaused();
            paused[tier] = false;
        } // else: no band yet and never paused — a brand-new vault opens
        //   unconditionally, there being no edge to be "near" yet.

        uint128 liquidityAdded = vault.openBand(newTickLower, newTickUpper, amount0Desired, amount1Desired);
        lastRecenterAt[tier] = block.timestamp;
        emit Recentered(tier, oldTickLower, oldTickUpper, newTickLower, newTickUpper, liquidityAdded);
    }

    function _vaultFor(uint8 tier) internal view returns (address vault) {
        vault = vaultOfTier[tier];
        if (vault == address(0)) revert UnknownTier();
    }
}
