// Shared types for the solver loop. Each tier has exactly one vault, and
// that vault has at most one open band at a time — the state this file
// describes is just that band, plus the pool it lives in.

export interface TierParams {
  zStar: number; // recenter trigger threshold, z-score form — mirrors IParamsRegistry.TierParams.zStar.
  //                d_min / (sigma * sqrt(T)) <= zStar triggers a recenter attempt (RiskMath.isTriggered).
  sigmaMax: number; // volatility ceiling — mirrors TierParams.sigmaMax. A recenter above this closes the
  //                   band and does NOT reopen (VaultManager's circuit breaker) until a later, calmer call.
  rSanityLow: number; // on-chain edge-band sanity check, low side — mirrors TierParams.rSanityLow.
  rSanityHigh: number; // on-chain edge-band sanity check, high side — mirrors TierParams.rSanityHigh.
  monitoringWindowYears: number; // T, the eq. 2 monitoring window — solver-side only, never stored on-chain.
  halfWidthTicks: number; // how wide (each side, in ticks) a fresh or recentered band should be —
  //                         a solver-side policy choice, not an on-chain parameter.
  // kMax/lcrMin/mStar remain declared on IParamsRegistry.TierParams but are reserved for a possible future
  // cumulative fee/IL circuit breaker — VaultManager v1 never reads them, so there's nothing to mirror here yet.
}

export interface PoolState {
  price: number; // current pool price, quote per base
  sqrtPrice: number; // sqrt(price)
  tick: number; // current pool tick, from the pool's own slot0
  sigma: number; // realized volatility of ln(price), annualized
  price0Usd: number; // token0's own USD price (independent feed, not derived from `price`)
  price1Usd: number; // token1's own USD price — for a stablecoin pair this tracks `price` closely
}

/** Which tier to monitor — everything else (the vault's pool, its two Pyth
 *  feed ids, the pool's tick spacing) is resolved live from the vault and
 *  pool contracts themselves, since `PairVault.pool()`/`priceIdA()`/
 *  `priceIdB()` are all public immutables and a v3 pool's `tickSpacing()` is
 *  a public immutable too — no separate config needed once a tier's vault
 *  and pool actually exist on-chain. */
export interface VaultConfig {
  tier: number;
}

/** Mirrors PairVault.band()'s return shape. `liquidity === 0n` means no band is open. */
export interface BandState {
  tickLower: number;
  tickUpper: number;
  liquidity: bigint;
}
