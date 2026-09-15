import { test } from "node:test";
import assert from "node:assert/strict";
import { PriceWindow, realizedVolatility } from "./volatility.ts";

test("realizedVolatility returns 0 with fewer than 3 samples", () => {
  const w = new PriceWindow();
  w.push({ price: 100, timestamp: 0 });
  w.push({ price: 101, timestamp: 1 });
  assert.equal(realizedVolatility(w), 0);
});

test("realizedVolatility matches a hand-computed value", () => {
  // ln(100), ln(101.005...), ln(100) -> returns [+0.01, -0.01] approximately.
  // mean=0, variance=((0.01)^2+(-0.01)^2)/(2-1)=0.0002, stdev=sqrt(0.0002)
  const w = new PriceWindow();
  w.push({ price: 100, timestamp: 0 });
  w.push({ price: 100 * Math.exp(0.01), timestamp: 1 });
  w.push({ price: 100, timestamp: 2 });

  const stdevPerSample = Math.sqrt(0.0002);
  const samplesPerYear = (365 * 24 * 60 * 60) / 1; // 1 second between samples
  const expected = stdevPerSample * Math.sqrt(samplesPerYear);

  const actual = realizedVolatility(w);
  const diff = Math.abs(actual - expected);
  assert.ok(diff / expected < 0.01, `expected ~${expected}, got ${actual}`);
});

test("PriceWindow evicts oldest sample past capacity", () => {
  const w = new PriceWindow(2);
  w.push({ price: 100, timestamp: 0 });
  w.push({ price: 101, timestamp: 1 });
  w.push({ price: 102, timestamp: 2 });
  assert.equal(w.size, 2);
  assert.equal(w.latest?.price, 102);
});

test("realizedVolatility is 0 for a perfectly deterministic constant-return trend", () => {
  // Every step has the identical log return -> zero variance -> zero vol.
  const w = new PriceWindow();
  let p = 100;
  for (let t = 0; t < 5; t++) {
    w.push({ price: p, timestamp: t });
    p *= Math.exp(0.005);
  }
  assert.ok(realizedVolatility(w) < 1e-6);
});
