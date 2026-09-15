// Pyth Hermes client — fetches live prices for the solver's trigger calculation.
// Hermes is Pyth's public REST price service.
// Docs: https://hermes.pyth.network/docs
//
// Testnet contract addresses (for the on-chain consumer side, not this client):
// price feeds 0x2880aB155794e7179c9eE2e38200202908C17B43 (architecture spec §8)
//
// Hermes requires an API key (Authorization: Bearer <key>) — unauthenticated
// requests 401. Get a free key at https://www.pyth.network/ and set
// HERMES_API_KEY. Free-tier keys don't cover every feed either (an
// unentitled feed 403s "Not entitled"), so fetchPythPrices should be called
// per-feed-group matching your plan's coverage, not assumed universal.

const HERMES_ENDPOINT = process.env.HERMES_ENDPOINT ?? "https://hermes.pyth.network";
const HERMES_API_KEY = process.env.HERMES_API_KEY;

export interface PythPrice {
  price: number; // human-readable price (already scaled by `expo`)
  confidence: number; // human-readable confidence interval, same scale as price
  publishTime: number; // unix seconds
}

interface HermesParsedFeed {
  id: string;
  price: { price: string; conf: string; expo: number; publish_time: number };
}

interface HermesResponse {
  parsed: HermesParsedFeed[];
}

/**
 * Fetches the latest price for one or more Pyth price feed ids.
 * Feed ids are 32-byte hex identifiers (no 0x prefix) from
 * https://www.pyth.network/developers/price-feed-ids
 */
export async function fetchPythPrices(feedIds: string[]): Promise<Map<string, PythPrice>> {
  const params = feedIds.map((id) => `ids[]=${id}`).join("&");
  const url = `${HERMES_ENDPOINT}/v2/updates/price/latest?${params}`;

  const res = await fetch(url, {
    headers: HERMES_API_KEY ? { Authorization: `Bearer ${HERMES_API_KEY}` } : {},
  });
  if (!res.ok) {
    const hint = res.status === 401 && !HERMES_API_KEY ? " (set HERMES_API_KEY — Hermes requires auth now)" : "";
    throw new Error(`Hermes request failed: ${res.status} ${res.statusText}${hint}`);
  }

  const body = (await res.json()) as HermesResponse;
  const out = new Map<string, PythPrice>();

  for (const feed of body.parsed) {
    const rawPrice = Number(feed.price.price);
    const rawConf = Number(feed.price.conf);
    const scale = 10 ** feed.price.expo; // expo is typically negative, e.g. -8

    out.set(feed.id, {
      price: rawPrice * scale,
      confidence: rawConf * scale,
      publishTime: feed.price.publish_time,
    });
  }

  return out;
}

export async function fetchPythPrice(feedId: string): Promise<PythPrice> {
  const prices = await fetchPythPrices([feedId]);
  const price = prices.get(feedId);
  if (!price) throw new Error(`No price returned for feed ${feedId}`);
  return price;
}

/**
 * Fetches the signed VAA update blobs for one or more feeds — the `bytes[]` a
 * consumer passes to `pyth.updatePriceFeeds` (and that PairVault's
 * `depositWithPriceUpdate` / `pushPriceUpdate` forward on). Returned as
 * 0x-prefixed hex, ready for viem's `writeContract` args. Same auth rules as
 * `fetchPythPrices` — set HERMES_API_KEY.
 *
 * Duplicate feed ids are de-duplicated: the demo tier-1 vault prices both sides
 * off the same USDC feed, and Hermes returns one blob per distinct id anyway.
 */
export async function fetchPythUpdateData(feedIds: string[]): Promise<`0x${string}`[]> {
  const uniqueIds = [...new Set(feedIds)];
  const params = uniqueIds.map((id) => `ids[]=${id}`).join("&");
  const url = `${HERMES_ENDPOINT}/v2/updates/price/latest?${params}&encoding=hex`;

  const res = await fetch(url, {
    headers: HERMES_API_KEY ? { Authorization: `Bearer ${HERMES_API_KEY}` } : {},
  });
  if (!res.ok) {
    const hint = res.status === 401 && !HERMES_API_KEY ? " (set HERMES_API_KEY — Hermes requires auth now)" : "";
    throw new Error(`Hermes update-data request failed: ${res.status} ${res.statusText}${hint}`);
  }

  const body = (await res.json()) as { binary: { data: string[] } };
  return body.binary.data.map((d) => (d.startsWith("0x") ? d : `0x${d}`) as `0x${string}`);
}
