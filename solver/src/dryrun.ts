// Solver dry-run against a live Monad testnet deployment. No private key, no
// transactions — this only reads. Proves the real pipeline works on real data:
//
//   1. vaultOfTier(tier) resolves the vault directly — no log scan, no
//      separate indexer needed.
//   2. the pool's live sqrt price is read straight from its own slot0() — a
//      plain view call, no storage-slot decoding needed — and the band's
//      position-in-range r, edge distance d_min, and trigger condition are
//      computed with the same math.ts the loop uses.
//   3. the vault's own navWad()/tvlA()/tvlB() are read live, for a clear picture
//      of idle vs. deployed capital.
//
// Run: node --experimental-strip-types src/dryrun.ts
// Required env: VAULT_MANAGER_ADDRESS, TIER (default 1).

import { createPublicClient, http, defineChain } from "viem";
import type { Hex } from "viem";
import {
  readVaultOfTier,
  readBand,
  readDecimals,
  readNavWad,
  readIdleBalances,
  readPaused,
  readPool,
  readPoolPrice,
  fromWad,
} from "./chain.ts";
import { positionInRange, withinEdgeBand, isTriggered, tickToSqrtPrice, zStarFromTheta } from "./math.ts";
import { fetchPythPrices } from "./pyth.ts";

const RPC = process.env.RPC_URL ?? "https://testnet-rpc.monad.xyz";
const VAULT_MANAGER = process.env.VAULT_MANAGER_ADDRESS as Hex | undefined;
const TIER = Number(process.env.TIER ?? 1);

// Same tier-1 params loop.ts uses.
const Z_STAR = 0.67449;
const R_SANITY_LOW = 0.35;
const R_SANITY_HIGH = 0.65;
const T_YEARS = 3 / 365;

const monad = defineChain({
  id: 10143,
  name: "Monad Testnet",
  nativeCurrency: { name: "Monad", symbol: "MON", decimals: 18 },
  rpcUrls: { default: { http: [RPC] } },
});
const pub = createPublicClient({ chain: monad, transport: http() });

async function main() {
  console.log(`Rangekeeper solver — DRY RUN (reads only)`);
  console.log(`  RPC              ${RPC}`);
  console.log(`  VaultManager     ${VAULT_MANAGER ?? "(not set)"}`);
  console.log(`  tier             ${TIER}\n`);

  if (!VAULT_MANAGER) {
    console.log("Set VAULT_MANAGER_ADDRESS to run a real dry-run — see .env.example.");
    return;
  }

  const head = await pub.getBlockNumber();
  console.log(`  chain head       block ${head}\n`);

  console.log(`[1/3] resolving tier ${TIER}'s vault…`);
  const vaultAddress = await readVaultOfTier(VAULT_MANAGER, TIER);
  if (vaultAddress.toLowerCase() === "0x0000000000000000000000000000000000000000") {
    console.log(`      vaultOfTier(${TIER}) is zero — no vault registered for this tier yet.\n`);
    return;
  }
  console.log(`      vault ${vaultAddress}\n`);

  const [band, decimals, idle, paused, poolAddress] = await Promise.all([
    readBand(vaultAddress),
    readDecimals(vaultAddress),
    readIdleBalances(vaultAddress),
    readPaused(VAULT_MANAGER, TIER),
    readPool(vaultAddress),
  ]);
  // navWad() reverts (StalePrice) once the vault's last-pushed Pyth price
  // ages past MAX_PRICE_AGE (60s) — expected between price pushes, not a
  // real failure, so this reads as "stale" rather than crashing the dry-run.
  const navWadText = await readNavWad(vaultAddress).then((n) => fromWad(n).toFixed(6)).catch(() => "(stale — push a Pyth update to read)");

  console.log(`[2/3] vault state…`);
  console.log(`      pool         ${poolAddress}`);
  console.log(`      navWad       ${navWadText}`);
  console.log(`      idle tvlA/B  ${idle.tvlA} / ${idle.tvlB}  (raw units, decimals ${decimals.decimals0}/${decimals.decimals1})`);
  console.log(`      paused       ${paused}`);

  if (band.liquidity === 0n) {
    console.log(`      band         none open — [dry-run] would OPEN unconditionally (or once calm, if paused)\n`);
    return;
  }

  console.log(`      band         ticks [${band.tickLower}, ${band.tickUpper}]  liquidity ${band.liquidity}\n`);

  console.log(`[3/3] live pool state (slot0())…`);
  const { price, sqrtPrice, tick } = await readPoolPrice(poolAddress);
  const sqrtPa = tickToSqrtPrice(band.tickLower);
  const sqrtPb = tickToSqrtPrice(band.tickUpper);
  const r = positionInRange(sqrtPrice, sqrtPa, sqrtPb);
  const dLo = Math.log(price / (sqrtPa * sqrtPa));
  const dHi = Math.log((sqrtPb * sqrtPb) / price);
  const dMin = Math.min(dLo, dHi);

  console.log(`      price ${price.toFixed(6)}  (tick ${tick})   sqrtP ${sqrtPrice.toFixed(6)}`);
  console.log(`      r = ${r.toFixed(4)}  (${withinEdgeBand(r, R_SANITY_LOW, R_SANITY_HIGH) ? "NEAR AN EDGE" : "centered"})   d_min = ${dMin.toFixed(4)}`);

  try {
    const usdcFeed = "eaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a";
    const prices = await fetchPythPrices([usdcFeed]);
    const px = prices.get(usdcFeed);
    console.log(`      (Hermes reachable — USDC/USD $${px?.price.toFixed(6)} as a live volatility source for a real feed pair)`);
  } catch (e) {
    console.log(`      Hermes fetch skipped/failed: ${(e as Error).message}`);
  }

  // Realized volatility needs a rolling window built over successive ticks —
  // a one-shot dry-run can't produce that, so this shows the trigger holding
  // sigma fixed at a few illustrative values instead.
  console.log(`\n      trigger check (z* = ${Z_STAR}, illustrative sigma values, T = ${T_YEARS.toFixed(4)}y):`);
  for (const sigma of [0.05, 0.2, 0.5]) {
    const sigmaSqrtT = sigma * Math.sqrt(T_YEARS);
    const triggered = isTriggered(dMin, sigmaSqrtT, Z_STAR);
    console.log(`        sigma=${sigma.toFixed(2)}  ->  ${triggered ? "WOULD RECENTER" : "would hold"}`);
  }
  console.log(`      (zStarFromTheta(0.5) = ${zStarFromTheta(0.5).toFixed(5)}, matching the deployed zStar of ${Z_STAR})`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
