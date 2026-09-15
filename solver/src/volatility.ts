// Realized volatility estimation from a rolling window of Pyth price samples.
// Feeds the sigma input the math spec's urgency (eq. 2) and stop-condition
// (§3.3a) calculations need — Pyth gives point-in-time prices, not volatility
// directly, so the solver has to derive it from its own sample history.

export interface PriceSample {
  price: number;
  timestamp: number; // unix seconds
}

/**
 * A fixed-capacity rolling window of price samples for one pool, used to
 * compute realized volatility of ln(price) without unbounded memory growth.
 */
export class PriceWindow {
  private samples: PriceSample[] = [];
  private maxSamples: number;

  constructor(maxSamples: number = 200) {
    this.maxSamples = maxSamples;
  }

  push(sample: PriceSample): void {
    this.samples.push(sample);
    if (this.samples.length > this.maxSamples) this.samples.shift();
  }

  get lnPrices(): number[] {
    return this.samples.map((s) => Math.log(s.price));
  }

  get timestamps(): number[] {
    return this.samples.map((s) => s.timestamp);
  }

  get latest(): PriceSample | undefined {
    return this.samples[this.samples.length - 1];
  }

  get size(): number {
    return this.samples.length;
  }
}

/**
 * Annualized realized volatility of ln(price) from a sample window.
 * Standard estimator: stdev of consecutive log returns, scaled by
 * sqrt(samples per year) implied by the average time between samples.
 */
export function realizedVolatility(window: PriceWindow): number {
  const lnPrices = window.lnPrices;
  const timestamps = window.timestamps;
  if (lnPrices.length < 3) return 0; // not enough data to estimate yet

  const returns: number[] = [];
  for (let i = 1; i < lnPrices.length; i++) {
    returns.push(lnPrices[i] - lnPrices[i - 1]);
  }

  const mean = returns.reduce((a, b) => a + b, 0) / returns.length;
  const variance = returns.reduce((a, b) => a + (b - mean) ** 2, 0) / (returns.length - 1);
  const stdevPerSample = Math.sqrt(variance);

  const totalSeconds = timestamps[timestamps.length - 1] - timestamps[0];
  const avgSecondsPerSample = totalSeconds / (timestamps.length - 1);
  if (avgSecondsPerSample <= 0) return 0;

  const secondsPerYear = 365 * 24 * 60 * 60;
  const samplesPerYear = secondsPerYear / avgSecondsPerSample;

  return stdevPerSample * Math.sqrt(samplesPerYear);
}
