// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Vendored via `forge install Uniswap/v3-core` — see remappings.txt.
import {IUniswapV3Pool} from "v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3MintCallback} from "v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import {TickMath} from "./libraries/TickMath.sol";

import {IPairVault} from "./interfaces/IPairVault.sol";
import {IPyth} from "./interfaces/IPyth.sol";
import {IYieldSource} from "./interfaces/IYieldSource.sol";
import {RiskMath} from "./libraries/RiskMath.sol";
import {LiquidityMath} from "./libraries/LiquidityMath.sol";

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @title PairVault
/// @notice Isolated per-pair pool of depositor capital. The vault itself IS the
///         Uniswap v3 liquidity provider for its pair — it opens one
///         concentrated-liquidity band and recenters it (close, then reopen
///         nearer the live price) as `VaultManager` directs.
/// @dev Design note: the vault is its own sole LP, full stop. A Uniswap v3
///      position is identified by (owner, tickLower, tickUpper), and this
///      contract only ever mints under its own address, so there's no way
///      (and no reason) for it to hold liquidity on behalf of any other
///      party's position. Managing exactly one band against one fixed pool
///      keeps every state transition (open, close, NAV) simple and
///      self-contained.
/// @dev Depositor shares are priced against a real dual-asset NAV (Pyth) that
///      includes the currently-open band's live value (LiquidityMath.
///      getAmountsForLiquidity), not just idle token balances — most of a
///      vault's value is expected to sit in its own band by design (the
///      "working pocket"), so NAV has to price that band live rather than
///      only the idle "spare pocket" sitting alongside it.
contract PairVault is IPairVault, IUniswapV3MintCallback {
    uint256 private constant WAD = 1e18;
    uint256 private constant MAX_PRICE_AGE = 60; // seconds — Pyth staleness bound

    // Fee split on every `collectFees()` harvest (source paper §6: "80/20 on
    // harvested fees... a starting point, not scripture"). Applies only to
    // fees pulled via the standalone, permissionless `collectFees()` — NOT to
    // the principal-plus-fees a `closeBand()` (recenter) returns, since that
    // would need per-position fee-growth snapshotting (tracking
    // feeGrowthInside at last touch) to separate principal from fees, which
    // this version doesn't do. Flagged rather than silently approximated.
    uint256 private constant BPS_DENOM = 10_000;
    uint256 public constant PROTOCOL_BPS = 2_000; // 20% of each harvest
    // Carved OUT of PROTOCOL_BPS (not added on top) — "a bit for the keepers
    // who actually send the transactions" (source paper §6). Whatever isn't
    // rebated goes to the protocol treasury as protocol-owned-liquidity seed
    // money; there's no native-token-locker slice yet since the option-token
    // mechanism itself isn't built (source paper §7: ship fees before options).
    uint256 public constant KEEPER_BPS = 500; // 5% of each harvest, to whoever calls collectFees
    uint256 public constant TREASURY_BPS = PROTOCOL_BPS - KEEPER_BPS; // 15%

    address public immutable protocolTreasury;

    // The "spare pocket" (source paper §4.2): whatever's swept out of idle
    // balance earns yield here instead of sitting doing nothing. Unset
    // (address(0)) disables the feature entirely — every sweep function
    // below becomes a no-op — which is deliberately the current state on
    // testnet: no lending market exists there to point this at (checked
    // directly — Aave V3 is Monad-mainnet-only, and the one testnet money
    // market that existed, Kinza Finance, has been retired by its own team
    // in favor of mainnet). Wires in for real the moment a vault deploys
    // somewhere with a real venue to use.
    IYieldSource public immutable yieldSource;
    // Of currently-idle balance, how much a sweep targets moving to the
    // yield source (source paper §4.2's 10-30% spare-pocket range, applied
    // here to the idle bucket itself rather than total NAV since idle is
    // already sized to be roughly the non-working portion). A starting
    // point, not scripture — same framing as PROTOCOL_BPS above.
    uint256 public constant SWEEP_BPS = 8_000; // sweep up to 80% of idle, keep 20% liquid

    address public immutable assetA;
    address public immutable assetB;
    uint8 public immutable decimalsA;
    uint8 public immutable decimalsB;
    bytes32 public immutable priceIdA;
    bytes32 public immutable priceIdB;
    IPyth public immutable pyth;
    /// @notice The vault's own, fixed Uniswap v3 pool for (assetA, assetB) —
    ///         set once at construction and never changed. `assetA`/`assetB`
    ///         must be supplied in this pool's sorted token0/token1 order.
    IUniswapV3Pool public immutable pool;
    uint8 public immutable tier;
    address public vaultManager;

    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    // Idle token balances — the "spare pocket," ledger-tracked regardless of
    // whether the actual tokens sit in this contract or have been swept to
    // `yieldSource`. Available to fund the next recenter or a withdrawal
    // without having to unwind the working position first — though a sweep
    // may need reversing first via sweepYieldToIdle if too much has moved
    // out (see its own comment).
    uint256 public tvlA;
    uint256 public tvlB;

    /// @notice The vault's single, currently-open concentrated-liquidity
    ///         position — the "working pocket." `liquidity == 0` means no band
    ///         is open (fresh vault, or between a close and the next open).
    struct Band {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    Band public band;

    error NotVaultManager();
    error UnsupportedAsset();
    error InvalidPrice();
    error BandAlreadyOpen();
    error NotPool();

    modifier onlyVaultManager() {
        if (msg.sender != vaultManager) revert NotVaultManager();
        _;
    }

    constructor(
        address _assetA,
        address _assetB,
        uint8 _decimalsA,
        uint8 _decimalsB,
        bytes32 _priceIdA,
        bytes32 _priceIdB,
        address _pyth,
        address _pool,
        uint8 _tier,
        address _vaultManager,
        address _protocolTreasury,
        address _yieldSource
    ) {
        assetA = _assetA;
        assetB = _assetB;
        decimalsA = _decimalsA;
        decimalsB = _decimalsB;
        priceIdA = _priceIdA;
        priceIdB = _priceIdB;
        pyth = IPyth(_pyth);
        pool = IUniswapV3Pool(_pool);
        tier = _tier;
        vaultManager = _vaultManager;
        protocolTreasury = _protocolTreasury;
        yieldSource = IYieldSource(_yieldSource);
    }

    function deposit(address asset, uint256 amount) external returns (uint256 shares) {
        return _deposit(asset, amount, msg.sender);
    }

    /// @dev See IPairVault — pushes `priceUpdateData` to Pyth in the same tx as
    ///      the deposit itself, so the price `_priceWad` reads is guaranteed
    ///      fresh regardless of how long it's been since anyone last called
    ///      `updatePriceFeeds` separately. Two independently-broadcast
    ///      transactions (push, then deposit) can't reliably beat a 60-second
    ///      staleness window once real block time and signing latency are
    ///      accounted for. Excess msg.value over the exact update fee is refunded.
    function depositWithPriceUpdate(address asset, uint256 amount, bytes[] calldata priceUpdateData)
        external
        payable
        returns (uint256 shares)
    {
        uint256 fee = pyth.getUpdateFee(priceUpdateData);
        pyth.updatePriceFeeds{value: fee}(priceUpdateData);
        if (msg.value > fee) {
            (bool ok,) = msg.sender.call{value: msg.value - fee}("");
            require(ok, "refund failed");
        }
        return _deposit(asset, amount, msg.sender);
    }

    /// @dev See IPairVault — the cross-chain-deposit-safe variant. `msg.sender`
    ///      still supplies the tokens (transferFrom); only share ownership goes
    ///      to `onBehalfOf`. A caller cannot mint shares to someone else without
    ///      actually paying for them — this is a beneficiary override, not a
    ///      funds-source override.
    function depositFor(address asset, uint256 amount, address onBehalfOf) external returns (uint256 shares) {
        return _deposit(asset, amount, onBehalfOf);
    }

    function _deposit(address asset, uint256 amount, address beneficiary) internal returns (uint256 shares) {
        if (asset != assetA && asset != assetB) revert UnsupportedAsset();
        IERC20Minimal(asset).transferFrom(msg.sender, address(this), amount);

        uint256 depositValueWad = asset == assetA
            ? _valueWad(amount, decimalsA, _priceWad(priceIdA))
            : _valueWad(amount, decimalsB, _priceWad(priceIdB));

        uint256 navBefore = navWad();
        // Bootstrap case (totalShares == 0): 1 share == 1 WAD of deposited value,
        // same convention as every other WAD quantity in this codebase. Otherwise
        // shares are minted proportional to the value added relative to NAV —
        // depositValueWad and navBefore are both "WAD of value", so this is a
        // plain ratio, not a divWad (which is for WAD-scaled fractions specifically).
        shares = totalShares == 0 ? depositValueWad : (depositValueWad * totalShares) / navBefore;

        totalShares += shares;
        sharesOf[beneficiary] += shares;

        if (asset == assetA) tvlA += amount;
        else tvlB += amount;

        emit Deposited(beneficiary, asset, amount, shares);
    }

    /// @dev Withdraws a proportional share of idle value only. If most of NAV
    ///      is deployed in the band (the normal, intended state), idle
    ///      balances may not cover a large withdrawal — `closeBand` (via
    ///      VaultManager) frees more if needed. A pro-rata claim on the band
    ///      itself, without closing it, isn't implemented here (open question,
    ///      matches the source paper's own "withdrawals must work even when
    ///      recentering is paused" requirement, which this satisfies for the
    ///      idle portion but not yet a mid-band partial exit).
    /// @dev "Idle value" here means tvlA/tvlB (this contract's own raw
    ///      balance) PLUS whatever's currently parked at `yieldSource` (its
    ///      `balanceOf`, live — includes accrued interest, not just
    ///      principal) — a withdrawer's pro-rata share has to count both, or
    ///      the swept portion becomes permanently unclaimable the moment
    ///      totalShares ever reaches zero (no one left with a claim on it).
    ///      Pays from local balance first, then tops up the shortfall from
    ///      the yield source — `_payOutIdle` returns what was ACTUALLY paid,
    ///      not the theoretical entitlement, for the one edge case where the
    ///      venue itself is short (same "can't always get 100% out
    ///      instantly" reality any real money market has); this never
    ///      reverts on that, it just pays out less.
    function withdraw(uint256 shares) external returns (uint256 amountA, uint256 amountB) {
        uint256 bal = sharesOf[msg.sender];
        require(shares <= bal, "insufficient shares");

        uint256 entitledA = ((tvlA + _spareBalance(assetA)) * shares) / totalShares;
        uint256 entitledB = ((tvlB + _spareBalance(assetB)) * shares) / totalShares;

        sharesOf[msg.sender] = bal - shares;
        totalShares -= shares;

        amountA = _payOutIdle(assetA, entitledA);
        amountB = _payOutIdle(assetB, entitledB);

        emit Withdrawn(msg.sender, shares, amountA, amountB);
    }

    /// @dev Zero if no yield source is configured — the common testnet case
    ///      right now (see the `yieldSource` field comment) — without an
    ///      extra external call.
    function _spareBalance(address asset) internal view returns (uint256) {
        if (address(yieldSource) == address(0)) return 0;
        return yieldSource.balanceOf(asset, address(this));
    }

    /// @dev Pays `entitled` of `asset` to msg.sender: local tvl first, then
    ///      the yield source for whatever's left. Decrements tvlA/tvlB by
    ///      only the LOCAL portion actually used — the yield-source portion
    ///      was never counted there to begin with (see the `yieldSource`
    ///      field / `tvlA` comments).
    function _payOutIdle(address asset, uint256 entitled) internal returns (uint256 paid) {
        if (entitled == 0) return 0;

        uint256 localTvl = asset == assetA ? tvlA : tvlB;
        uint256 fromLocal = entitled > localTvl ? localTvl : entitled;
        if (asset == assetA) tvlA -= fromLocal; else tvlB -= fromLocal;

        uint256 shortfall = entitled - fromLocal;
        uint256 fromYield = 0;
        if (shortfall > 0 && address(yieldSource) != address(0)) {
            fromYield = yieldSource.withdraw(asset, shortfall);
        }

        paid = fromLocal + fromYield;
        if (paid > 0) IERC20Minimal(asset).transfer(msg.sender, paid);
    }

    /// @notice Permissionless — sweeps up to SWEEP_BPS of current idle balance
    ///         into `yieldSource`. No-op if no yield source is configured or
    ///         there's nothing to sweep. Deliberately doesn't touch deposit,
    ///         withdraw, openBand, or closeBand at all: this is an explicit,
    ///         separate action a keeper calls, not an implicit side effect —
    ///         keeps every already-live code path completely unchanged
    ///         regardless of whether a yield source is ever configured.
    function sweepIdleToYield() external {
        if (address(yieldSource) == address(0)) return;

        uint256 amountA = (tvlA * SWEEP_BPS) / BPS_DENOM;
        uint256 amountB = (tvlB * SWEEP_BPS) / BPS_DENOM;
        if (amountA > 0) {
            tvlA -= amountA;
            IERC20Minimal(assetA).approve(address(yieldSource), amountA);
            yieldSource.deposit(assetA, amountA);
        }
        if (amountB > 0) {
            tvlB -= amountB;
            IERC20Minimal(assetB).approve(address(yieldSource), amountB);
            yieldSource.deposit(assetB, amountB);
        }
        if (amountA > 0 || amountB > 0) emit SweptToYield(amountA, amountB);
    }

    /// @notice Permissionless — pulls up to `amountA`/`amountB` back from
    ///         `yieldSource` into this contract's own idle balance (e.g.
    ///         before a withdrawal or recenter needs more liquid balance than
    ///         is currently idle here). `yieldSource.withdraw` itself caps at
    ///         what's actually available, so an over-large request here just
    ///         returns less rather than reverting.
    function sweepYieldToIdle(uint256 amountA, uint256 amountB) external {
        if (address(yieldSource) == address(0)) return;

        uint256 gotA;
        uint256 gotB;
        if (amountA > 0) {
            gotA = yieldSource.withdraw(assetA, amountA);
            tvlA += gotA;
        }
        if (amountB > 0) {
            gotB = yieldSource.withdraw(assetB, amountB);
            tvlB += gotB;
        }
        if (gotA > 0 || gotB > 0) emit SweptFromYield(gotA, gotB);
    }

    /// @notice Opens the vault's own concentrated-liquidity band against its
    ///         fixed pool, funded from its own idle balances. Called by
    ///         VaultManager as the second half of a recenter (or the very
    ///         first band a fresh vault opens).
    function openBand(int24 tickLower, int24 tickUpper, uint256 amount0Desired, uint256 amount1Desired)
        external
        onlyVaultManager
        returns (uint128 liquidityAdded)
    {
        if (band.liquidity != 0) revert BandAlreadyOpen();

        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint160 sqrtPa = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtPb = TickMath.getSqrtRatioAtTick(tickUpper);
        liquidityAdded = LiquidityMath.getLiquidityForAmounts(sqrtPriceX96, sqrtPa, sqrtPb, amount0Desired, amount1Desired);

        band = Band({tickLower: tickLower, tickUpper: tickUpper, liquidity: liquidityAdded});

        // Triggers uniswapV3MintCallback below, synchronously, which is what
        // actually debits tvlA/tvlB and pays the pool.
        (uint256 amount0, uint256 amount1) = pool.mint(address(this), tickLower, tickUpper, liquidityAdded, "");

        emit BandOpened(tickLower, tickUpper, liquidityAdded, amount0, amount1);
    }

    /// @notice Removes all liquidity from the vault's current band and credits
    ///         the freed tokens (principal plus any fees accrued on it) to
    ///         tvlA/tvlB. No-op if no band is open.
    function closeBand() external onlyVaultManager returns (uint256 amount0, uint256 amount1) {
        Band memory b = band;
        if (b.liquidity == 0) return (0, 0);
        delete band;

        // burn() only moves the position's principal into its owed-tokens
        // balance; collect() is the actual transfer. Requesting the max
        // uint128 drains everything owed — principal plus whatever fees had
        // already accrued on this position before the close.
        pool.burn(b.tickLower, b.tickUpper, b.liquidity);
        (uint128 got0, uint128 got1) =
            pool.collect(address(this), b.tickLower, b.tickUpper, type(uint128).max, type(uint128).max);
        amount0 = got0;
        amount1 = got1;

        if (amount0 > 0) tvlA += amount0;
        if (amount1 > 0) tvlB += amount1;

        emit BandClosed(b.tickLower, b.tickUpper, b.liquidity, amount0, amount1);
    }

    /// @notice Pushes a Pyth price update, refunding any excess fee.
    ///         Permissionless — a real, validly-signed Pyth update can only
    ///         ever make this vault's own prices more accurate, never let
    ///         anyone manipulate them, so there's nothing to gate here.
    /// @dev Standalone rather than folded into `openBand` because
    ///      `VaultManager.recenter`'s flow needs a fresh price across the whole
    ///      close-then-reopen sequence (the sanity check against the OLD band
    ///      also reads this vault's price-adjacent state), not just at the
    ///      final open call.
    function pushPriceUpdate(bytes[] calldata priceUpdateData) external payable {
        uint256 fee = pyth.getUpdateFee(priceUpdateData);
        pyth.updatePriceFeeds{value: fee}(priceUpdateData);
        if (msg.value > fee) {
            (bool ok,) = msg.sender.call{value: msg.value - fee}("");
            require(ok, "refund failed");
        }
    }

    /// @notice Permissionless "harvest" — pulls this vault's own accrued fees on
    ///         its current band (splits them 80% depositors / 15% protocol
    ///         treasury / 5% straight to whoever called this), and returns the
    ///         depositor-side amount actually added to NAV. No-op if no band open.
    /// @dev A zero-amount `burn` is the standard Uniswap v3 idiom for "poke this
    ///      position's fee accounting without touching its principal" — it
    ///      moves currently-accrued fees into the position's owed-tokens
    ///      balance without freeing any liquidity, so the subsequent `collect`
    ///      pulls out pure fee income.
    function collectFees() external returns (uint256 amount0, uint256 amount1) {
        Band memory b = band;
        if (b.liquidity == 0) return (0, 0);

        pool.burn(b.tickLower, b.tickUpper, 0);
        (uint128 got0, uint128 got1) =
            pool.collect(address(this), b.tickLower, b.tickUpper, type(uint128).max, type(uint128).max);
        uint256 raw0 = got0;
        uint256 raw1 = got1;

        // Credit the FULL raw harvest into tvlA/tvlB first (same as this
        // function did pre-split), THEN carve the protocol's and the
        // keeper's slices back out below — so the transfers out are real
        // debits against a balance that's actually there, not skipped
        // against a balance that was never credited in the first place.
        if (raw0 > 0) tvlA += raw0;
        if (raw1 > 0) tvlB += raw1;

        (uint256 treasury0, uint256 keeper0) = _splitFee(raw0);
        (uint256 treasury1, uint256 keeper1) = _splitFee(raw1);

        if (treasury0 + keeper0 > 0) {
            tvlA -= (treasury0 + keeper0);
            if (treasury0 > 0) IERC20Minimal(assetA).transfer(protocolTreasury, treasury0);
            if (keeper0 > 0) IERC20Minimal(assetA).transfer(msg.sender, keeper0);
        }
        if (treasury1 + keeper1 > 0) {
            tvlB -= (treasury1 + keeper1);
            if (treasury1 > 0) IERC20Minimal(assetB).transfer(protocolTreasury, treasury1);
            if (keeper1 > 0) IERC20Minimal(assetB).transfer(msg.sender, keeper1);
        }

        amount0 = raw0 - treasury0 - keeper0;
        amount1 = raw1 - treasury1 - keeper1;

        emit FeesCollected(amount0, amount1);
        if (treasury0 + treasury1 + keeper0 + keeper1 > 0) {
            emit FeesSplit(treasury0, treasury1, keeper0, keeper1, msg.sender);
        }
    }

    /// @dev raw's 80/15/5 split: returns (treasuryAmt, keeperAmt); the implicit
    ///      remainder (raw - both) is what's left for depositors. Kept
    ///      per-asset and in raw token units — no oracle call needed just to
    ///      decide the split, so a stale Pyth feed can never block a harvest.
    function _splitFee(uint256 raw) internal pure returns (uint256 treasuryAmt, uint256 keeperAmt) {
        if (raw == 0) return (0, 0);
        keeperAmt = (raw * KEEPER_BPS) / BPS_DENOM;
        treasuryAmt = (raw * TREASURY_BPS) / BPS_DENOM;
    }

    /// @dev Pool-only. Uniswap v3's mint callback: pays whatever the pool says
    ///      is owed for the liquidity `openBand` just requested, straight out
    ///      of this vault's own idle balance.
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata) external {
        if (msg.sender != address(pool)) revert NotPool();
        if (amount0Owed > 0) {
            tvlA -= amount0Owed;
            IERC20Minimal(assetA).transfer(address(pool), amount0Owed);
        }
        if (amount1Owed > 0) {
            tvlB -= amount1Owed;
            IERC20Minimal(assetB).transfer(address(pool), amount1Owed);
        }
    }

    function utilization() public view returns (uint256 utilizationWad) {
        uint256 nav = navWad();
        if (nav == 0) return 0;
        return RiskMath.divWad(_bandValueWad(), nav);
    }

    /// @notice Total vault value in WAD, priced live via Pyth: idle balances
    ///         (tvlA/tvlB), whatever's parked at `yieldSource` (if any), plus
    ///         the current band's value at the live pool price.
    /// @dev Skips pricing an idle side with zero balance entirely — an earlier
    ///      version called `_priceWad` unconditionally for both assets, which
    ///      meant even a single-sided deposit into an empty vault would revert
    ///      if the *other* asset's feed happened to be stale, despite that side
    ///      holding nothing to price. Zero balance contributes zero value
    ///      either way, so this changes no valid result — only which reverts
    ///      are avoidable.
    /// @dev The yield-source component is read live (yieldSource.balanceOf),
    ///      not from a static ledger like tvlA/tvlB — it needs to reflect
    ///      whatever interest has accrued there since the last sweep, which a
    ///      snapshot taken at sweep time never would.
    function navWad() public view returns (uint256) {
        uint256 valueA = tvlA == 0 ? 0 : _valueWad(tvlA, decimalsA, _priceWad(priceIdA));
        uint256 valueB = tvlB == 0 ? 0 : _valueWad(tvlB, decimalsB, _priceWad(priceIdB));
        if (address(yieldSource) != address(0)) {
            uint256 spareA = yieldSource.balanceOf(assetA, address(this));
            uint256 spareB = yieldSource.balanceOf(assetB, address(this));
            valueA += spareA == 0 ? 0 : _valueWad(spareA, decimalsA, _priceWad(priceIdA));
            valueB += spareB == 0 ? 0 : _valueWad(spareB, decimalsB, _priceWad(priceIdB));
        }
        if (band.liquidity != 0) {
            (uint256 bandA, uint256 bandB) = _bandAmounts();
            valueA += bandA == 0 ? 0 : _valueWad(bandA, decimalsA, _priceWad(priceIdA));
            valueB += bandB == 0 ? 0 : _valueWad(bandB, decimalsB, _priceWad(priceIdB));
        }
        return valueA + valueB;
    }

    function _bandValueWad() internal view returns (uint256) {
        if (band.liquidity == 0) return 0;
        (uint256 bandA, uint256 bandB) = _bandAmounts();
        uint256 valueA = bandA == 0 ? 0 : _valueWad(bandA, decimalsA, _priceWad(priceIdA));
        uint256 valueB = bandB == 0 ? 0 : _valueWad(bandB, decimalsB, _priceWad(priceIdB));
        return valueA + valueB;
    }

    function _bandAmounts() internal view returns (uint256 amount0, uint256 amount1) {
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint160 sqrtPa = TickMath.getSqrtRatioAtTick(band.tickLower);
        uint160 sqrtPb = TickMath.getSqrtRatioAtTick(band.tickUpper);
        return LiquidityMath.getAmountsForLiquidity(sqrtPriceX96, sqrtPa, sqrtPb, band.liquidity);
    }

    /// @dev Kept for interface compatibility — now genuinely priced, not raw token units.
    function tvl() external view returns (uint256) {
        return navWad();
    }

    /// @dev See IPairVault — lets external consumers price a raw fee/token
    ///      amount via this vault's own oracle config. Returns 0 for a zero
    ///      amount without touching the oracle: a stale or unreachable Pyth
    ///      feed shouldn't make a caller revert over an amount that's zero
    ///      either way. Same fix as `navWad`'s zero-balance skip.
    function valueOfAssetA(uint256 amountRaw) external view returns (uint256) {
        if (amountRaw == 0) return 0;
        return _valueWad(amountRaw, decimalsA, _priceWad(priceIdA));
    }

    function valueOfAssetB(uint256 amountRaw) external view returns (uint256) {
        if (amountRaw == 0) return 0;
        return _valueWad(amountRaw, decimalsB, _priceWad(priceIdB));
    }

    function _priceWad(bytes32 feedId) internal view returns (uint256) {
        IPyth.Price memory p = pyth.getPriceNoOlderThan(feedId, MAX_PRICE_AGE);
        if (p.price <= 0) revert InvalidPrice();

        if (p.expo >= 0) {
            return uint256(uint64(p.price)) * WAD * (10 ** uint32(p.expo));
        }
        uint32 negExpo = uint32(-p.expo);
        require(negExpo <= 18, "expo out of range");
        return uint256(uint64(p.price)) * (10 ** (18 - negExpo));
    }

    function _valueWad(uint256 amountRaw, uint8 assetDecimals, uint256 priceWad) internal pure returns (uint256) {
        return (amountRaw * priceWad) / (10 ** assetDecimals);
    }
}
