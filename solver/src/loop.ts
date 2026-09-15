// Per-block monitoring loop.
// Run with: npm run loop (after `npm install` and setting the env vars below).
//
// Each tier has exactly one vault, permanently, discoverable with a single
// `vaultOfTier(tier)` view call — no log scan, no separate indexing module.
// The vault's pool, its two Pyth feed ids, and that pool's tick spacing are
// all public immutables read live from the vault/pool contracts themselves
// (see chain.ts's readPool/readPriceIds/readTickSpacing) — nothing about
// which pool a tier targets needs to live in config.

import { fetchPythPrices, fetchPythUpdateData } from "./pyth.ts";
import { PriceWindow, realizedVolatility } from "./volatility.ts";
import { isTriggered, withinEdgeBand, positionInRange, pickCenteredTicks, tickToSqrtPrice, amountsForLiquidity } from "./math.ts";
import {
  toWad,
  encodeRecenterProof,
  readVaultOfTier,
  readPaused,
  readBand,
  readPool,
  readPriceIds,
  readTickSpacing,
  readIdleBalances,
  readPoolPrice,
  submitRecenterWithPriceUpdateTx,
  submitCollectFeesTx,
} from "./chain.ts";
import type { PoolState, VaultConfig, TierParams } from "./types.ts";
import type { Hex } from "viem";
import { pathToFileURL } from "node:url";

const POLL_INTERVAL_MS = Number(process.env.POLL_INTERVAL_MS ?? 500); // ~1-2 Monad blocks
const VAULT_MANAGER_ADDRESS = process.env.VAULT_MANAGER_ADDRESS as Hex | undefined;
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

// Harvests uncollected fees on an open band into idle balance every so often —
// permissionless, and worth doing periodically so a later recenter's freed-
// amount estimate (see math.ts's amountsForLiquidity) reflects real principal,
// not principal plus a growing pile of uncollected fees that estimate can't see.
const COLLECT_FEES_INTERVAL_MS = Number(process.env.COLLECT_FEES_INTERVAL_MS ?? 60 * 60 * 1000);

// Real per-tier params, matching what's queued on the live ParamsRegistry for
// the fields VaultManager actually reads. monitoringWindowYears/halfWidthTicks
// are solver-side policy, not on-chain parameters — see types.ts.
const TIER_PARAMS: Record<number, TierParams> = {
  1: {
    zStar: 0.67449,
    sigmaMax: 0.08,
    rSanityLow: 0.35,
    rSanityHigh: 0.65,
    monitoringWindowYears: 3 / 365,
    halfWidthTicks: 600,
  },
  // Tier 2: real USDC / DMOA — same policy as tier 1.
  2: {
    zStar: 0.67449,
    sigmaMax: 0.08,
    rSanityLow: 0.35,
    rSanityHigh: 0.65,
    monitoringWindowYears: 3 / 365,
    halfWidthTicks: 600,
  },
};

/** Which tiers to monitor — just a list of numbers. Everything else about a
 *  tier's vault (its pool, feed ids, tick spacing) is resolved live once the
 *  vault is actually registered; see the caches below. */
function loadVaultConfigs(): VaultConfig[] {
  const tiers = (process.env.TIERS ?? "1").split(",").map((s) => Number(s.trim())).filter((n) => !Number.isNaN(n));
  return tiers.map((tier) => ({ tier }));
}

// One rolling price window per tier — this is what realized sigma is computed from.
const priceWindows = new Map<number, PriceWindow>();
// Caches that only need refreshing occasionally, not every tick.
const vaultAddressCache = new Map<number, Hex>();
const poolAddressCache = new Map<number, Hex>();
const feedIdsCache = new Map<number, { feed0: string; feed1: string }>();
const tickSpacingCache = new Map<number, number>();
const lastCollectedAt = new Map<number, number>();

/** Resolves (and caches) everything about a tier's vault that's a fixed,
 *  read-once fact once the vault exists: its pool address, that pool's two
 *  Pyth feed ids, and the pool's own tick spacing. */
async function resolveVaultMeta(
  tier: number,
  vaultAddress: Hex,
): Promise<{ pool: Hex; feed0: string; feed1: string; tickSpacing: number }> {
  let pool = poolAddressCache.get(tier);
  let feeds = feedIdsCache.get(tier);
  let tickSpacing = tickSpacingCache.get(tier);

  if (!pool) {
    pool = await readPool(vaultAddress);
    poolAddressCache.set(tier, pool);
  }
  if (!feeds) {
    feeds = await readPriceIds(vaultAddress);
    feedIdsCache.set(tier, feeds);
  }
  if (tickSpacing === undefined) {
    tickSpacing = await readTickSpacing(pool);
    tickSpacingCache.set(tier, tickSpacing);
  }

  return { pool, ...feeds, tickSpacing };
}

async function fetchPoolState(feed0: string, feed1: string, poolAddress: Hex, tier: number): Promise<PoolState & { tick: number }> {
  // One Hermes call for both feeds — fetchPythPrices already batches by id.
  const prices = await fetchPythPrices([feed0, feed1]);
  const p0 = prices.get(feed0);
  const p1 = prices.get(feed1);
  if (!p0 || !p1) throw new Error(`Hermes returned no price for one of tier ${tier}'s feeds`);

  // The pool's own real, on-chain price — not the Pyth peg — is what the risk
  // math measures against (see chain.ts's readPoolPrice header for why: a peg
  // can and does diverge from the pool's actual traded price once real swaps
  // move it, and the contract's own sanity gate reads the real price too).
  const real = await readPoolPrice(poolAddress);

  let window = priceWindows.get(tier);
  if (!window) {
    window = new PriceWindow();
    priceWindows.set(tier, window);
  }
  window.push({ price: real.price, timestamp: p1.publishTime });

  return {
    price: real.price,
    sqrtPrice: real.sqrtPrice,
    tick: real.tick,
    sigma: realizedVolatility(window), // 0 until the window has >= 3 samples
    price0Usd: p0.price,
    price1Usd: p1.price,
  };
}

async function vaultAddressFor(tier: number): Promise<Hex | null> {
  const cached = vaultAddressCache.get(tier);
  if (cached) return cached;
  if (!VAULT_MANAGER_ADDRESS) return null;
  const addr = await readVaultOfTier(VAULT_MANAGER_ADDRESS as Hex, tier);
  if (addr.toLowerCase() === ZERO_ADDRESS) return null;
  vaultAddressCache.set(tier, addr);
  return addr;
}

async function maybeCollectFees(tier: number, vaultAddress: Hex): Promise<void> {
  const last = lastCollectedAt.get(tier) ?? 0;
  if (Date.now() - last < COLLECT_FEES_INTERVAL_MS) return;
  lastCollectedAt.set(tier, Date.now());
  try {
    const hash = await submitCollectFeesTx(vaultAddress);
    console.log(`[collectFees] tier=${tier} vault=${vaultAddress} tx=${hash}`);
  } catch (err) {
    console.log(`[collectFees:dry-run] tier=${tier} vault=${vaultAddress} (${(err as Error).message})`);
  }
}

async function submitRecenter(
  tier: number,
  feed0: string,
  feed1: string,
  newTickLower: number,
  newTickUpper: number,
  amount0Desired: bigint,
  amount1Desired: bigint,
  dMinWad: bigint,
  sigmaSqrtTWad: bigint,
  sigmaWad: bigint,
): Promise<void> {
  const proof = encodeRecenterProof(dMinWad, sigmaSqrtTWad, sigmaWad);
  try {
    // Always the staleness-safe path: fetch a fresh Pyth VAA for this pool's
    // feeds and push it in the same tx as the recenter (PairVault's price has
    // a 60s bound, and nothing else guarantees a recent update). The contract
    // refunds the unused update fee to the signer.
    const priceUpdateData = await fetchPythUpdateData([feed0, feed1]);
    const hash = await submitRecenterWithPriceUpdateTx(
      tier,
      newTickLower,
      newTickUpper,
      amount0Desired,
      amount1Desired,
      proof,
      priceUpdateData,
    );
    console.log(`[recenter] tier=${tier} newTicks=[${newTickLower},${newTickUpper}] tx=${hash}`);
  } catch (err) {
    // Missing PRIVATE_KEY/VAULT_MANAGER_ADDRESS is expected until a real
    // deployment exists — log the decision without crashing the loop over it.
    console.log(`[recenter:dry-run] tier=${tier} newTicks=[${newTickLower},${newTickUpper}] (${(err as Error).message})`);
  }
}

async function tickForVault(cfg: VaultConfig): Promise<void> {
  const params = TIER_PARAMS[cfg.tier];
  if (!params) {
    console.log(`[config:dry-run] tier ${cfg.tier} has no TIER_PARAMS entry — skipping`);
    return;
  }

  const vaultAddress = await vaultAddressFor(cfg.tier);
  if (!vaultAddress) {
    console.log(`[vault:dry-run] tier ${cfg.tier} has no vault registered yet (vaultOfTier is zero) — skipping`);
    return;
  }

  const meta = await resolveVaultMeta(cfg.tier, vaultAddress);
  const band = await readBand(vaultAddress);

  let pool: PoolState & { tick: number };
  try {
    pool = await fetchPoolState(meta.feed0, meta.feed1, meta.pool, cfg.tier);
  } catch (err) {
    console.log(`[pool:dry-run] tier=${cfg.tier} could not read pool state (${(err as Error).message})`);
    return;
  }

  if (band.liquidity === 0n) {
    const paused = await readPaused(VAULT_MANAGER_ADDRESS as Hex, cfg.tier);
    if (paused && pool.sigma > params.sigmaMax) {
      console.log(`[recenter:skip] tier=${cfg.tier} still paused — sigma=${pool.sigma.toFixed(4)} > sigmaMax=${params.sigmaMax}`);
      return;
    }

    // No band open (fresh vault, or resuming from a circuit-breaker pause with
    // calm conditions now confirmed) — open one, unconditionally, centered on
    // the pool's real current tick.
    const [newTickLower, newTickUpper] = pickCenteredTicks(pool.tick, params.halfWidthTicks, meta.tickSpacing);
    const idle = await readIdleBalances(vaultAddress);
    await submitRecenter(cfg.tier, meta.feed0, meta.feed1, newTickLower, newTickUpper, idle.tvlA, idle.tvlB, toWad(0), toWad(1), toWad(pool.sigma));
    return;
  }

  // A band is open — decide whether it's genuinely time to move it. Both
  // checks below mirror VaultManager._recenter's own on-chain gates exactly
  // (RiskMath.isTriggered / RiskMath.withinEdgeBand); running them here first
  // just avoids paying gas for a call the chain would reject anyway — the
  // chain's own re-validation (against the pool's own live price, not this
  // read) remains the actual authority.
  const sqrtPa = tickToSqrtPrice(band.tickLower);
  const sqrtPb = tickToSqrtPrice(band.tickUpper);
  const dLo = Math.log(pool.price / (sqrtPa * sqrtPa));
  const dHi = Math.log((sqrtPb * sqrtPb) / pool.price);
  const dMin = Math.min(dLo, dHi);
  const sigmaSqrtT = pool.sigma * Math.sqrt(params.monitoringWindowYears);
  const r = positionInRange(pool.sqrtPrice, sqrtPa, sqrtPb);

  const triggered = pool.sigma > 0 && isTriggered(dMin, sigmaSqrtT, params.zStar) && withinEdgeBand(r, params.rSanityLow, params.rSanityHigh);
  if (!triggered) {
    await maybeCollectFees(cfg.tier, vaultAddress);
    return;
  }

  const [newTickLower, newTickUpper] = pickCenteredTicks(pool.tick, params.halfWidthTicks, meta.tickSpacing);

  // Size the new band from currently-idle balances PLUS an estimate of what
  // closing the OLD band will free — both happen inside the very same
  // recenter transaction, so idle balances alone would understate what's
  // actually available by the time openBand runs.
  const freed = amountsForLiquidity(pool.sqrtPrice, sqrtPa, sqrtPb, Number(band.liquidity));
  const SAFETY = 0.999; // margin against rounding/float-precision drift between this estimate and the chain's own integer math
  const idle = await readIdleBalances(vaultAddress);
  const amount0Desired = idle.tvlA + BigInt(Math.floor(freed.amount0 * SAFETY));
  const amount1Desired = idle.tvlB + BigInt(Math.floor(freed.amount1 * SAFETY));

  await submitRecenter(cfg.tier, meta.feed0, meta.feed1, newTickLower, newTickUpper, amount0Desired, amount1Desired, toWad(dMin), toWad(sigmaSqrtT), toWad(pool.sigma));
}

async function tick(): Promise<void> {
  if (!VAULT_MANAGER_ADDRESS) {
    console.log("[config:dry-run] VAULT_MANAGER_ADDRESS not set — see solver/.env.example");
    return;
  }

  const configs = loadVaultConfigs();
  for (const cfg of configs) {
    // One tier's failure (a pool not yet initialized, a stale feed, ...) must
    // not stop the rest of the loop from doing its job.
    try {
      await tickForVault(cfg);
    } catch (err) {
      console.error(`[tier ${cfg.tier} error]`, err);
    }
  }
}

async function main() {
  console.log(`Rangekeeper solver loop starting — polling every ${POLL_INTERVAL_MS}ms`);
  // Recursive setTimeout, not setInterval: setInterval fires on a fixed clock
  // regardless of whether the previous tick finished, and a slow RPC round
  // trip can take longer than POLL_INTERVAL_MS. Overlapping ticks would each
  // fire their own concurrent set of reads, multiplying RPC load for no
  // reason. Only schedule the next tick once this one is fully done, and back
  // off on failure rather than hammering an already-struggling RPC again
  // half a second later.
  let consecutiveFailures = 0;
  for (;;) {
    try {
      await tick();
      consecutiveFailures = 0;
      await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS));
    } catch (err) {
      consecutiveFailures++;
      const backoffMs = Math.min(5_000 * 2 ** (consecutiveFailures - 1), 60_000);
      console.error(`[loop error] (failure ${consecutiveFailures}, retrying in ${backoffMs}ms)`, err);
      await new Promise((resolve) => setTimeout(resolve, backoffMs));
    }
  }
}

// Runs main() only for `node loop.ts` (or `npm run loop`), not when another
// module imports this file. `file://${process.argv[1]}` looks equivalent to
// import.meta.url but never actually matches on Windows — process.argv[1] is
// a backslash path (C:\...\loop.ts), while import.meta.url is a proper
// file:// URL (file:///C:/.../loop.ts, forward slashes, three slashes).
// pathToFileURL normalizes both sides the same way regardless of OS.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main();
}
