// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PairVault} from "./PairVault.sol";
import {VaultManager} from "./VaultManager.sol";

/// @title VaultFactory
/// @notice Deploys a new isolated PairVault for a given pair and pool, and
///         assigns it a tier. Registration with VaultManager is a separate,
///         explicit call so tier wiring is always visible on-chain.
contract VaultFactory {
    VaultManager public immutable vaultManager;
    address public immutable pyth;
    // Protocol-wide, not per-pair — every vault this factory creates skims its
    // fee split to the same address. See PairVault's PROTOCOL_BPS/KEEPER_BPS.
    address public immutable protocolTreasury;
    // Also protocol-wide: one adapter (see IYieldSource) serves every vault
    // and every asset this factory creates a vault for — it takes the asset
    // as a call parameter, so there's no reason for a second instance per
    // pair. address(0) disables the spare-pocket feature entirely for every
    // vault this factory creates (see PairVault's yieldSource comment for why
    // that's the real, current, checked state of Monad testnet).
    address public immutable yieldSource;
    address[] public allVaults;

    event VaultCreated(address indexed vault, address assetA, address assetB, uint8 tier);

    /// @dev protocolTreasury deliberately has no constructor parameter: reads
    ///      msg.sender directly instead, same reasoning as ParamsRegistry's
    ///      and VaultManager's own admin fields (see their constructor
    ///      comments) — `new VaultFactory(..., msg.sender)` from inside a
    ///      Foundry script would evaluate that `msg.sender` in the SCRIPT
    ///      CONTRACT's own calling context (Foundry's internal harness
    ///      address), not the real broadcasting key, because argument
    ///      expressions are evaluated by the script's own currently-executing
    ///      frame — unlike a direct `new VaultFactory(...)` call itself, which
    ///      Foundry's broadcaster re-issues as a standalone transaction from
    ///      the real key, so `msg.sender` READ INSIDE this constructor's own
    ///      body correctly reflects the real deployer. This one is real: an
    ///      earlier version of this constructor took `_protocolTreasury` as a
    ///      parameter and would have permanently burned the treasury's 15%
    ///      fee slice to an address nobody controls, caught in dry-run before
    ///      ever being broadcast for real.
    constructor(address _vaultManager, address _pyth, address _yieldSource) {
        vaultManager = VaultManager(payable(_vaultManager));
        pyth = _pyth;
        protocolTreasury = msg.sender;
        yieldSource = _yieldSource;
    }

    /// @param decimalsA/B ERC20 decimals of each asset — passed explicitly rather
    ///        than read via IERC20Metadata so an exotic/non-standard token can't
    ///        make vault creation revert.
    /// @param priceIdA/B Pyth price feed ids (see docs.pyth.network/price-feed-ids)
    /// @param pool This tier's own, already-deployed Uniswap v3 pool for
    ///        (assetA, assetB) — one pool per tier, fixed for the vault's
    ///        lifetime. assetA/assetB must already be in that pool's sorted
    ///        token0/token1 order.
    /// @dev Deliberately does NOT call `vaultManager.setVaultForTier` itself —
    ///      that's admin-only now (VaultManager's own onlyAdmin fix), and this
    ///      factory isn't the admin. Registration is a separate, explicit call
    ///      the deploy script/admin makes right after this one, so tier wiring
    ///      is always a distinct, visible, authenticated on-chain action rather
    ///      than an implicit side effect of creating a vault.
    function createVault(
        address assetA,
        address assetB,
        uint8 decimalsA,
        uint8 decimalsB,
        bytes32 priceIdA,
        bytes32 priceIdB,
        address pool,
        uint8 tier
    ) external returns (address vault) {
        vault = address(
            new PairVault(
                assetA,
                assetB,
                decimalsA,
                decimalsB,
                priceIdA,
                priceIdB,
                pyth,
                pool,
                tier,
                address(vaultManager),
                protocolTreasury,
                yieldSource
            )
        );
        allVaults.push(vault);
        emit VaultCreated(vault, assetA, assetB, tier);
    }

    function vaultCount() external view returns (uint256) {
        return allVaults.length;
    }
}
