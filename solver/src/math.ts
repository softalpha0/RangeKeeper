// Off-chain twin of src/libraries/RiskMath.sol.
//
// Unlike the Solidity library, this file DOES compute the normal CDF and its
// inverse — `zStarFromTheta` is how a tier's on-chain `zStar` threshold gets
// derived in the first place (see RiskMath.sol's header for why the contract
// itself never touches a CDF). `isTriggered`/`withinEdgeBand` mirror
// RiskMath's own trigger and sanity checks in plain floats, so the solver can
// self-check a decision before spending gas on a call the chain will reject.
//
// gamma/fullRangeIL/concentratedIL/lossCoverageRatio/liquidationRatios are
// not used by the current recenter decision loop. Kept here, unused, for the
// same reason IParamsRegistry.TierParams still declares kMax/lcrMin/mStar as
// reserved fields: a possible future cumulative fee/IL circuit breaker on
// the vault's own band, should one be built later.

/** Abramowitz & Stegun 7.1.26 approximation, max error ~1.5e-7. */
export function erf(x: number): number {
  const sign = x < 0 ? -1 : 1;
  const ax = Math.abs(x);

  const a1 = 0.254829592;
  const a2 = -0.284496736;
  const a3 = 1.421413741;
  const a4 = -1.453152027;
  const a5 = 1.061405429;
  const p = 0.3275911;

  const t = 1 / (1 + p * ax);
  const y = 1 - ((((a5 * t + a4) * t + a3) * t + a2) * t + a1) * t * Math.exp(-ax * ax);
  return sign * y;
}

export function normalCDF(x: number): number {
  return 0.5 * (1 + erf(x / Math.SQRT2));
}

/** Peter Acklam's rational approximation of the inverse normal CDF. */
export function normalInvCDF(p: number): number {
  if (p <= 0 || p >= 1) throw new RangeError("normalInvCDF: p must be in (0, 1)");

  const a = [-3.969683028665376e1, 2.209460984245205e2, -2.759285104469687e2, 1.383577518672690e2, -3.066479806614716e1, 2.506628277459239];
  const b = [-5.447609879822406e1, 1.615858368580409e2, -1.556989798598866e2, 6.680131188771972e1, -1.328068155288572e1];
  const c = [-7.784894002430293e-3, -3.223964580411365e-1, -2.400758277161838, -2.549732539343734, 4.374664141464968, 2.938163982698783];
  const d = [7.784695709041462e-3, 3.224671290700398e-1, 2.445134137142996, 3.754408661907416];

  const pLow = 0.02425;
  let q: number, r: number;

  if (p < pLow) {
    q = Math.sqrt(-2 * Math.log(p));
    return (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
      ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1);
  } else if (p <= 1 - pLow) {
    q = p - 0.5;
    r = q * q;
    return (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q /
      (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1);
  } else {
    q = Math.sqrt(-2 * Math.log(1 - p));
    return -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
      ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1);
  }
}

/** eq. 1 — position-in-range, r in [0, 1]. Mirrors RiskMath.positionInRange. */
export function positionInRange(sqrtP: number, sqrtPa: number, sqrtPb: number): number {
  if (sqrtP <= sqrtPa) return 0;
  if (sqrtP >= sqrtPb) return 1;
  return (sqrtP - sqrtPa) / (sqrtPb - sqrtPa);
}

/** Mirrors RiskMath.withinEdgeBand — the same cheap on-chain sanity gate,
 *  computed here so the solver can self-check its own proof against the
 *  pool's real current price before submitting a recenter that the chain's
 *  own sanity check (against the hook-cached price) would reject. */
export function withinEdgeBand(r: number, rLow: number, rHigh: number): boolean {
  return r <= rLow || r >= rHigh;
}

/**
 * Mirrors RiskMath.isTriggered exactly: true when d_min / (sigma*sqrt(T)) <=
 * zStar (equivalent to the eq. 2 probability U >= theta*, without ever
 * computing a CDF on-chain — see RiskMath.sol's header). This is the sole
 * trigger VaultManager checks before moving an already-open band; a fresh
 * vault's first-ever band opens unconditionally and never calls this.
 */
export function isTriggered(dMin: number, sigmaSqrtT: number, zStar: number): boolean {
  return dMin / sigmaSqrtT <= zStar;
}

/**
 * Converts a tier's probability threshold theta* into the equivalent z-score
 * threshold `zStar` that RiskMath.sol stores and compares against directly.
 * zStar = Phi^-1(1 - theta* / 2)
 */
export function zStarFromTheta(thetaStar: number): number {
  return normalInvCDF(1 - thetaStar / 2);
}

/** eq. 5 — concentration amplification factor. Reserved — see file header. */
export function gamma(sqrtPa: number, sqrtPb: number): number {
  return sqrtPb / (sqrtPb - sqrtPa);
}

/** eq. 6a — full-range impermanent loss as a function of price ratio rho. Reserved — see file header. */
export function fullRangeIL(rho: number): number {
  return (2 * Math.sqrt(rho)) / (1 + rho) - 1;
}

/** eq. 6b — concentrated-range IL, amplified by gamma. Reserved — see file header. */
export function concentratedIL(gammaVal: number, ilFull: number): number {
  return gammaVal * ilFull;
}

/** eq. 7 — Loss Coverage Ratio. Reserved — see file header. */
export function lossCoverageRatio(fT: number, ilConc: number): number {
  return 1 + fT - Math.abs(ilConc);
}

/** eq. 8 — closed-form liquidation price ratio band. Returns [rhoDown, rhoUp]. Reserved — see file header. */
export function liquidationRatios(gammaVal: number, c: number): [number, number] {
  const A = 1 - c / gammaVal;
  const discriminant = 1 - A * A;
  if (discriminant < 0) throw new RangeError("liquidationRatios: already past liquidation (c/gamma >= 1 in magnitude)");
  const sqrtDisc = Math.sqrt(discriminant);

  const x1 = (1 + sqrtDisc) / A;
  const x2 = (1 - sqrtDisc) / A;
  const rhoUp = x1 * x1;
  const rhoDown = x2 * x2;
  return [rhoDown, rhoUp];
}

/** price = 1.0001^tick, so sqrt(price) = 1.0001^(tick/2) — the same relationship
 *  TickMath.getSqrtPriceAtTick encodes on-chain (in Q64.96 integers; this is the
 *  plain-float equivalent for the solver's own decision-making, not for encoding
 *  a transaction — the contract always re-derives its own bounds from the tick). */
export function tickToSqrtPrice(tick: number): number {
  return Math.pow(1.0001, tick / 2);
}

/**
 * Picks a new band's [tickLower, tickUpper], centered on `tick` and
 * `halfWidthTicks` wide on each side, rounded outward to `tickSpacing`
 * multiples (Uniswap v3 requires both bounds to be exact multiples of the
 * pool's tickSpacing). Rounds the lower bound down and the upper bound up so
 * the requested width is a floor, never silently narrowed by rounding.
 */
export function pickCenteredTicks(tick: number, halfWidthTicks: number, tickSpacing: number): [number, number] {
  const rawLower = tick - halfWidthTicks;
  const rawUpper = tick + halfWidthTicks;
  const tickLower = Math.floor(rawLower / tickSpacing) * tickSpacing;
  const tickUpper = Math.ceil(rawUpper / tickSpacing) * tickSpacing;
  return [tickLower, tickUpper];
}

/**
 * Mirrors LiquidityMath.getAmountsForLiquidity's closed-form amount0/amount1
 * (the standard Uniswap v3 formulas) in plain floats. Used to estimate how
 * much of each token closing the OLD band will free, so a recenter's
 * amount0Desired/amount1Desired can safely offer that freed principal
 * alongside currently-idle balances — not just what's idle right now, which
 * during a recenter is about to grow the moment closeBand executes, in the
 * very same transaction closeBand and openBand both run in.
 *
 * An off-chain estimate only, not a source of truth: the contract always
 * computes its own actual liquidity/amounts from real integer math. This
 * only sizes the *Desired inputs the solver proposes, so the loop applies a
 * small safety margin on top rather than trusting it to the last wei.
 */
export function amountsForLiquidity(
  sqrtP: number,
  sqrtPa: number,
  sqrtPb: number,
  liquidity: number,
): { amount0: number; amount1: number } {
  if (sqrtPa > sqrtPb) [sqrtPa, sqrtPb] = [sqrtPb, sqrtPa];
  if (sqrtP <= sqrtPa) return { amount0: liquidity * (1 / sqrtPa - 1 / sqrtPb), amount1: 0 };
  if (sqrtP >= sqrtPb) return { amount0: 0, amount1: liquidity * (sqrtPb - sqrtPa) };
  return { amount0: liquidity * (1 / sqrtP - 1 / sqrtPb), amount1: liquidity * (sqrtP - sqrtPa) };
}
