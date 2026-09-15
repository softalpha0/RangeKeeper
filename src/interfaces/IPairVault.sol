// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IUniswapV3Pool} from "v3-core/contracts/interfaces/IUniswapV3Pool.sol";

/// @title IPairVault
/// @notice Isolated per-pair vault of depositor capital. The vault IS the Uniswap
///         v3 liquidity provider for its own pair — it opens and manages exactly
///         one concentrated-liquidity band at a time, recentering it as price
///         moves.
interface IPairVault {
    event Deposited(address indexed depositor, address asset, uint256 amount, uint256 shares);
    event Withdrawn(address indexed depositor, uint256 shares, uint256 amountA, uint256 amountB);
    event BandOpened(int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 amount0, uint256 amount1);
    event BandClosed(int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 amount0, uint256 amount1);
    event FeesCollected(uint256 amount0, uint256 amount1);
    /// @dev Emitted alongside FeesCollected only when a harvest was actually
    ///      split (i.e. raw fees > 0). `keeper` is whoever called
    ///      `collectFees()` and received keeper0/keeper1.
    event FeesSplit(uint256 treasury0, uint256 treasury1, uint256 keeper0, uint256 keeper1, address indexed keeper);
    /// @dev Emitted by sweepIdleToYield/sweepYieldToIdle only when something
    ///      actually moved (both are no-ops, silent, if yieldSource is unset).
    event SweptToYield(uint256 amountA, uint256 amountB);
    event SweptFromYield(uint256 amountA, uint256 amountB);

    function deposit(address asset, uint256 amount) external returns (uint256 shares);

    /// @dev Same as `deposit`, but credits shares to `onBehalfOf` instead of
    ///      `msg.sender` — needed for cross-chain deposit flows (e.g. Aurora
    ///      Intents Connect) where the caller is a transient intermediary
    ///      account, not the real depositor. Mirrors Aave's own
    ///      `supply(asset, amount, onBehalfOf, referralCode)` pattern.
    function depositFor(address asset, uint256 amount, address onBehalfOf) external returns (uint256 shares);

    /// @dev Same as `deposit`, but pushes `priceUpdateData` to Pyth first, in the
    ///      same transaction, before pricing the deposit. Fixes a real race: two
    ///      separate transactions (push price, then deposit) can never reliably
    ///      land inside Pyth's staleness window (`MAX_PRICE_AGE`) once you
    ///      account for block time plus manual signing latency — the two must
    ///      be atomic. Caller must send `msg.value >= pyth.getUpdateFee(priceUpdateData)`;
    ///      any excess is refunded.
    function depositWithPriceUpdate(address asset, uint256 amount, bytes[] calldata priceUpdateData)
        external
        payable
        returns (uint256 shares);

    function withdraw(uint256 shares) external returns (uint256 amountA, uint256 amountB);

    /// @notice The vault's own, fixed Uniswap v3 pool — set once at
    ///         construction and never changed. Publicly readable so
    ///         VaultManager can read its live price directly (`slot0()`)
    ///         without depending on a separate cache.
    function pool() external view returns (IUniswapV3Pool);

    /// @notice The vault's single, currently-open band. `liquidity == 0` means
    ///         none is open. VaultManager reads this to know what to close and
    ///         to re-derive the on-chain sanity check before recentering.
    function band() external view returns (int24 tickLower, int24 tickUpper, uint128 liquidity);

    /// @dev VaultManager-only. Opens the vault's own concentrated-liquidity band,
    ///      funded from its own token balances. Reverts if a band is already
    ///      open — `closeBand` first. `amount0Desired`/`amount1Desired` are
    ///      keeper/solver-computed off-chain from live pool composition; a real
    ///      ERC20 transfer failing if the vault doesn't hold enough is the
    ///      natural guard, with no separate cap needed on top of it.
    function openBand(int24 tickLower, int24 tickUpper, uint256 amount0Desired, uint256 amount1Desired)
        external
        returns (uint128 liquidityAdded);

    /// @dev VaultManager-only. Removes all liquidity from the vault's current
    ///      band (principal plus any fees accrued on it) and credits the freed
    ///      tokens to tvlA/tvlB. No-op, returns (0, 0), if no band is currently open.
    function closeBand() external returns (uint256 amount0, uint256 amount1);

    /// @notice Pushes a Pyth price update, refunding any excess fee.
    ///         Permissionless — a real, validly-signed Pyth update can only
    ///         ever make this vault's own prices more accurate, never let
    ///         anyone manipulate them, so there's nothing to gate here.
    function pushPriceUpdate(bytes[] calldata priceUpdateData) external payable;

    /// @notice Permissionless "harvest" — pulls this vault's own accrued fees on
    ///         its current band into its NAV. Anyone may call it; the vault only
    ///         ever receives its own money.
    /// @dev Possible because PairVault itself is the sole liquidity provider for
    ///      this band — a Uniswap v3 position is identified by (owner,
    ///      tickLower, tickUpper), and this vault only ever mints under its own
    ///      address, so this could never be done on a third party's behalf even
    ///      if one existed here.
    function collectFees() external returns (uint256 amount0, uint256 amount1);

    /// @return utilizationWad fraction of vault NAV currently deployed in the band, WAD
    function utilization() external view returns (uint256 utilizationWad);

    /// @notice Total vault value in WAD: idle token balances plus the current
    ///         band's value at the live pool price (if one is open).
    function navWad() external view returns (uint256);

    function tvl() external view returns (uint256);

    /// @dev Lets external consumers price a raw token amount via this vault's
    ///      own oracle config, without duplicating Pyth wiring. Assumes
    ///      assetA/assetB were supplied in Uniswap's sorted token0/token1
    ///      order at vault creation — see VaultFactory.createVault.
    function valueOfAssetA(uint256 amountRaw) external view returns (uint256 valueWad);
    function valueOfAssetB(uint256 amountRaw) external view returns (uint256 valueWad);
}
