import { test } from "node:test";
import assert from "node:assert/strict";
import {
  positionInRange,
  withinEdgeBand,
  isTriggered,
  zStarFromTheta,
  gamma,
  fullRangeIL,
  concentratedIL,
  lossCoverageRatio,
  liquidationRatios,
  tickToSqrtPrice,
  pickCenteredTicks,
  amountsForLiquidity,
} from "./math.ts";

// Expected values for the reserved eq. 5-8 functions come from the math spec's
// worked example (ETH/USDC): p0=3000, pa=2700, pb=3300, sigma=0.65, T=3/365.

function approx(actual: number, expected: number, tolPct = 0.02) {
  const diff = Math.abs(actual - expected);
  assert.ok(diff <= Math.abs(expected) * tolPct, `expected ~${expected}, got ${actual}`);
}

test("positionInRange centers near 0.51 at entry", () => {
  const r = positionInRange(Math.sqrt(3000), Math.sqrt(2700), Math.sqrt(3300));
  approx(r, 0.512);
});

test("positionInRange clamps to 0/1 outside the range", () => {
  assert.equal(positionInRange(Math.sqrt(2000), Math.sqrt(2700), Math.sqrt(3300)), 0);
  assert.equal(positionInRange(Math.sqrt(4000), Math.sqrt(2700), Math.sqrt(3300)), 1);
});

test("withinEdgeBand matches RiskMath.withinEdgeBand's <=/>= gate", () => {
  assert.equal(withinEdgeBand(0.1, 0.35, 0.65), true); // below rLow
  assert.equal(withinEdgeBand(0.9, 0.35, 0.65), true); // above rHigh
  assert.equal(withinEdgeBand(0.5, 0.35, 0.65), false); // centered
  assert.equal(withinEdgeBand(0.35, 0.35, 0.65), true); // exactly at the boundary — inclusive
});

test("isTriggered matches RiskMath.isTriggered's ratio-vs-zStar check", () => {
  // From the worked example: d_min/(sigma*sqrt(T)) ~= 0.79, which triggers at zStar=1.036 (theta*=0.30)
  const dMin = Math.log(3300 / 3150);
  const sigmaSqrtT = 0.65 * Math.sqrt(3 / 365);
  const zStar = zStarFromTheta(0.3);
  assert.equal(isTriggered(dMin, sigmaSqrtT, zStar), true);
  // A much larger zStar (tighter/more sensitive trigger) should also fire.
  assert.equal(isTriggered(dMin, sigmaSqrtT, 5), true);
  // A near-zero zStar (only trigger when already essentially at the edge) should not.
  assert.equal(isTriggered(dMin, sigmaSqrtT, 0.01), false);
});

test("zStarFromTheta round-trips with the trigger boolean used on-chain", () => {
  const thetaStar = 0.3;
  const zStar = zStarFromTheta(thetaStar);
  const ratio = Math.log(3300 / 3150) / (0.65 * Math.sqrt(3 / 365));
  assert.ok(ratio <= zStar, "worked example should cross the tier B trigger");
});

test("gamma matches worked example (~10.48)", () => {
  approx(gamma(Math.sqrt(2700), Math.sqrt(3300)), 10.48);
});

test("liquidation band matches worked example (~0.728, ~1.373)", () => {
  const g = gamma(Math.sqrt(2700), Math.sqrt(3300));
  const c = 1 + 0.03 - 0.9; // f_t=0.03, LCR_min=0.90
  const [rhoDown, rhoUp] = liquidationRatios(g, c);
  approx(rhoDown, 0.728);
  approx(rhoUp, 1.373);
});

test("LCR at rho=1.30 stays healthy (~0.94)", () => {
  const g = gamma(Math.sqrt(2700), Math.sqrt(3300));
  const ilFull = fullRangeIL(1.3);
  const ilConc = concentratedIL(g, ilFull);
  const lcr = lossCoverageRatio(0.03, ilConc);
  approx(lcr, 0.94, 0.03);
});

test("tickToSqrtPrice matches price = 1.0001^tick at tick 0", () => {
  assert.equal(tickToSqrtPrice(0), 1);
});

test("tickToSqrtPrice squares back to the tick's price", () => {
  const sqrtP = tickToSqrtPrice(6000);
  approx(sqrtP * sqrtP, Math.pow(1.0001, 6000), 0.0001);
});

test("pickCenteredTicks rounds outward to tickSpacing multiples, centered on tick", () => {
  const [lower, upper] = pickCenteredTicks(100, 600, 60);
  assert.equal(lower, Math.floor(-500 / 60) * 60);
  assert.equal(upper, Math.ceil(700 / 60) * 60);
  assert.ok(lower <= 100 - 600 && upper >= 100 + 600, "must never be narrower than the requested half-width");
});

test("pickCenteredTicks handles a tick that already sits on a tickSpacing multiple", () => {
  const [lower, upper] = pickCenteredTicks(0, 600, 60);
  assert.equal(lower, -600);
  assert.equal(upper, 600);
});

test("pickCenteredTicks handles a negative center tick", () => {
  const [lower, upper] = pickCenteredTicks(-2400, 600, 60);
  assert.equal(lower, -3000);
  assert.equal(upper, -1800);
});

// amountsForLiquidity — same worked-example range as LiquidityMath.t.sol,
// checked by round-tripping back through positionInRange-style boundary logic
// rather than a hand-derived magic number.
const SQRT_PA = Math.sqrt(2700);
const SQRT_PB = Math.sqrt(3300);

test("amountsForLiquidity is all token0 at/below the range", () => {
  const { amount0, amount1 } = amountsForLiquidity(SQRT_PA, SQRT_PA, SQRT_PB, 1000);
  assert.ok(amount0 > 0);
  assert.equal(amount1, 0);
});

test("amountsForLiquidity is all token1 at/above the range", () => {
  const { amount0, amount1 } = amountsForLiquidity(SQRT_PB, SQRT_PA, SQRT_PB, 1000);
  assert.equal(amount0, 0);
  assert.ok(amount1 > 0);
});

test("amountsForLiquidity needs both sides when centered", () => {
  const sqrtCentered = Math.sqrt(3000);
  const { amount0, amount1 } = amountsForLiquidity(sqrtCentered, SQRT_PA, SQRT_PB, 1000);
  assert.ok(amount0 > 0 && amount1 > 0);
});

test("amountsForLiquidity is zero for zero liquidity", () => {
  const { amount0, amount1 } = amountsForLiquidity(Math.sqrt(3000), SQRT_PA, SQRT_PB, 0);
  assert.equal(amount0, 0);
  assert.equal(amount1, 0);
});
