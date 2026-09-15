// On-chain read/write client for the solver — the other half of loop.ts's
// submitRecenter. Talks to VaultManager and PairVault directly; everything it
// sends gets independently re-validated on-chain (RiskMath.sol), so this
// client's only job is encoding the proof correctly, reading current state,
// and signing the tx.

import {
  createPublicClient,
  createWalletClient,
  http,
  defineChain,
  parseAbi,
  encodeAbiParameters,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import type { Hex } from "viem";
import type { BandState } from "./types.ts";

export const monadTestnet = defineChain({
  id: 10143,
  name: "Monad Testnet",
  nativeCurrency: { name: "Monad", symbol: "MON", decimals: 18 },
  rpcUrls: { default: { http: [process.env.RPC_URL ?? "https://testnet-rpc.monad.xyz"] } },
});

const VAULT_MANAGER_ABI = parseAbi([
  "function recenter(uint8 tier, int24 newTickLower, int24 newTickUpper, uint256 amount0Desired, uint256 amount1Desired, bytes proof) external",
  "function recenterWithPriceUpdate(uint8 tier, int24 newTickLower, int24 newTickUpper, uint256 amount0Desired, uint256 amount1Desired, bytes proof, bytes[] priceUpdateData) external payable",
  "function vaultOfTier(uint8 tier) external view returns (address)",
  "function paused(uint8 tier) external view returns (bool)",
  "function lastRecenterAt(uint8 tier) external view returns (uint256)",
  "function MIN_RECENTER_INTERVAL() external view returns (uint256)",
]);

const PAIR_VAULT_ABI = parseAbi([
  "function pool() external view returns (address)",
  "function priceIdA() external view returns (bytes32)",
  "function priceIdB() external view returns (bytes32)",
  "function band() external view returns (int24 tickLower, int24 tickUpper, uint128 liquidity)",
  "function decimalsA() external view returns (uint8)",
  "function decimalsB() external view returns (uint8)",
  "function navWad() external view returns (uint256)",
  "function tvlA() external view returns (uint256)",
  "function tvlB() external view returns (uint256)",
  "function collectFees() external returns (uint256 amount0, uint256 amount1)",
]);

// A Uniswap v3 pool's own public state/immutables — plain view calls, no
// storage-slot math needed to read the live price.
const POOL_ABI = parseAbi([
  "function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality, uint16 observationCardinalityNext, uint8 feeProtocol, bool unlocked)",
  "function tickSpacing() external view returns (int24)",
]);

const PYTH_ABI = parseAbi(["function getUpdateFee(bytes[] updateData) external view returns (uint256)"]);

// Pyth's price-feeds contract on Monad testnet — architecture spec §8 / pyth.ts.
// Only used to size the `value` for recenterWithPriceUpdate; any excess
// is refunded by the contract, so a stale default here is harmless.
const PYTH_ADDRESS = (process.env.PYTH_ADDRESS ?? "0x2880aB155794e7179c9eE2e38200202908C17B43") as Hex;

const WAD = 1_000_000_000_000_000_000n;

/** Converts a JS float to a WAD (1e18) fixed-point bigint, matching RiskMath.sol. */
export function toWad(x: number): bigint {
  return BigInt(Math.round(x * 1e18));
}

/**
 * Converts a human-unit token amount to raw on-chain units at that specific
 * token's own decimals — NOT always 18. `openBand`'s amount0Desired/
 * amount1Desired are raw units at decimalsA/decimalsB (PairVault.sol's
 * `_valueWad` divides by `10**assetDecimals`), so blindly calling `toWad` for
 * these is only correct by accident for an 18-decimal token — for a real
 * 6-decimal token like USDC/AUSD it's off by 1e12x.
 */
export function toRawUnits(x: number, decimals: number): bigint {
  return BigInt(Math.round(x * 10 ** decimals));
}

/** Inverse of `toWad` — converts an on-chain WAD (1e18) bigint back to a plain JS float. */
export function fromWad(x: bigint): number {
  return Number(x) / 1e18;
}

/** @param proof VaultManager._recenter decodes this as abi.encode(uint256 dMinWad, uint256 sigmaSqrtTWad, uint256 sigmaWad). */
export function encodeRecenterProof(dMinWad: bigint, sigmaSqrtTWad: bigint, sigmaWad: bigint): Hex {
  return encodeAbiParameters(
    [{ type: "uint256" }, { type: "uint256" }, { type: "uint256" }],
    [dMinWad, sigmaSqrtTWad, sigmaWad],
  );
}

let _clients: ReturnType<typeof buildClients> | null = null;

function buildClients() {
  const privateKey = process.env.PRIVATE_KEY;
  if (!privateKey) {
    throw new Error("PRIVATE_KEY not set — see solver/.env.example. Refusing to sign without one.");
  }
  const vaultManagerAddress = process.env.VAULT_MANAGER_ADDRESS as Hex | undefined;
  if (!vaultManagerAddress) {
    throw new Error("VAULT_MANAGER_ADDRESS not set — see solver/.env.example.");
  }

  const account = privateKeyToAccount(privateKey as Hex);
  const publicClient = createPublicClient({ chain: monadTestnet, transport: http() });
  const walletClient = createWalletClient({ account, chain: monadTestnet, transport: http() });

  return { account, publicClient, walletClient, vaultManagerAddress };
}

/** Lazily builds clients on first real use, so importing this module (or running
 *  tests against pure functions like `toWad`) never requires a private key. */
function clients() {
  if (!_clients) _clients = buildClients();
  return _clients;
}

export async function submitRecenterTx(
  tier: number,
  newTickLower: number,
  newTickUpper: number,
  amount0Desired: bigint,
  amount1Desired: bigint,
  proof: Hex,
): Promise<Hex> {
  const { walletClient, vaultManagerAddress, account } = clients();
  return walletClient.writeContract({
    address: vaultManagerAddress,
    abi: VAULT_MANAGER_ABI,
    functionName: "recenter",
    args: [tier, newTickLower, newTickUpper, amount0Desired, amount1Desired, proof],
    account,
  });
}

/**
 * The staleness-safe recenter path: pushes a fresh Pyth update to the vault's
 * feed in the same transaction, before the sanity check and `openBand` read
 * price via the vault's oracle. `priceUpdateData` comes from
 * `fetchPythUpdateData` (pyth.ts). The `value` covers `pyth.getUpdateFee` plus
 * a 1-wei margin; VaultManager refunds whatever it doesn't spend back to this
 * signer.
 *
 * This is what `loop.ts` uses in practice — plain `submitRecenterTx` only
 * works when someone else pushed a Pyth update in the last 60s, which a
 * keeper can't rely on.
 */
export async function submitRecenterWithPriceUpdateTx(
  tier: number,
  newTickLower: number,
  newTickUpper: number,
  amount0Desired: bigint,
  amount1Desired: bigint,
  proof: Hex,
  priceUpdateData: Hex[],
): Promise<Hex> {
  const { walletClient, publicClient, vaultManagerAddress, account } = clients();

  const fee = (await publicClient.readContract({
    address: PYTH_ADDRESS,
    abi: PYTH_ABI,
    functionName: "getUpdateFee",
    args: [priceUpdateData],
  })) as bigint;

  return walletClient.writeContract({
    address: vaultManagerAddress,
    abi: VAULT_MANAGER_ABI,
    functionName: "recenterWithPriceUpdate",
    args: [tier, newTickLower, newTickUpper, amount0Desired, amount1Desired, proof, priceUpdateData],
    value: fee + 1n,
    account,
  });
}

/** Permissionless fee harvest on a vault's current band — see PairVault.collectFees. */
export async function submitCollectFeesTx(vaultAddress: Hex): Promise<Hex> {
  const { walletClient, account } = clients();
  return walletClient.writeContract({
    address: vaultAddress,
    abi: PAIR_VAULT_ABI,
    functionName: "collectFees",
    account,
  });
}

// Read-only client that never needs a private key — every read below works in
// pure monitoring/dry-run mode with no secrets, unlike the submit* functions above.
const readOnlyClient = createPublicClient({ chain: monadTestnet, transport: http() });

export async function readVaultOfTier(vaultManagerAddress: Hex, tier: number): Promise<Hex> {
  return readOnlyClient.readContract({
    address: vaultManagerAddress,
    abi: VAULT_MANAGER_ABI,
    functionName: "vaultOfTier",
    args: [tier],
  }) as Promise<Hex>;
}

export async function readPaused(vaultManagerAddress: Hex, tier: number): Promise<boolean> {
  return readOnlyClient.readContract({
    address: vaultManagerAddress,
    abi: VAULT_MANAGER_ABI,
    functionName: "paused",
    args: [tier],
  }) as Promise<boolean>;
}

export async function readMinRecenterInterval(vaultManagerAddress: Hex): Promise<bigint> {
  return readOnlyClient.readContract({
    address: vaultManagerAddress,
    abi: VAULT_MANAGER_ABI,
    functionName: "MIN_RECENTER_INTERVAL",
  }) as Promise<bigint>;
}

export async function readLastRecenterAt(vaultManagerAddress: Hex, tier: number): Promise<bigint> {
  return readOnlyClient.readContract({
    address: vaultManagerAddress,
    abi: VAULT_MANAGER_ABI,
    functionName: "lastRecenterAt",
    args: [tier],
  }) as Promise<bigint>;
}

export async function readBand(vaultAddress: Hex): Promise<BandState> {
  const [tickLower, tickUpper, liquidity] = (await readOnlyClient.readContract({
    address: vaultAddress,
    abi: PAIR_VAULT_ABI,
    functionName: "band",
  })) as [number, number, bigint];
  return { tickLower, tickUpper, liquidity };
}

/** The vault's own fixed Uniswap v3 pool — a public immutable, so this never
 *  needs config: it's the same answer before or after the vault has ever
 *  opened a band, unlike reading it off `band()` itself. */
export async function readPool(vaultAddress: Hex): Promise<Hex> {
  return readOnlyClient.readContract({ address: vaultAddress, abi: PAIR_VAULT_ABI, functionName: "pool" }) as Promise<Hex>;
}

export async function readPriceIds(vaultAddress: Hex): Promise<{ feed0: string; feed1: string }> {
  const [feed0, feed1] = await Promise.all([
    readOnlyClient.readContract({ address: vaultAddress, abi: PAIR_VAULT_ABI, functionName: "priceIdA" }),
    readOnlyClient.readContract({ address: vaultAddress, abi: PAIR_VAULT_ABI, functionName: "priceIdB" }),
  ]);
  // Hermes expects raw hex ids with no 0x prefix.
  return { feed0: (feed0 as string).slice(2), feed1: (feed1 as string).slice(2) };
}

export async function readTickSpacing(poolAddress: Hex): Promise<number> {
  return readOnlyClient.readContract({ address: poolAddress, abi: POOL_ABI, functionName: "tickSpacing" }) as unknown as Promise<number>;
}

export async function readDecimals(vaultAddress: Hex): Promise<{ decimals0: number; decimals1: number }> {
  const [decimals0, decimals1] = await Promise.all([
    readOnlyClient.readContract({ address: vaultAddress, abi: PAIR_VAULT_ABI, functionName: "decimalsA" }),
    readOnlyClient.readContract({ address: vaultAddress, abi: PAIR_VAULT_ABI, functionName: "decimalsB" }),
  ]);
  return { decimals0: decimals0 as number, decimals1: decimals1 as number };
}

export async function readNavWad(vaultAddress: Hex): Promise<bigint> {
  return readOnlyClient.readContract({ address: vaultAddress, abi: PAIR_VAULT_ABI, functionName: "navWad" }) as Promise<bigint>;
}

export async function readIdleBalances(vaultAddress: Hex): Promise<{ tvlA: bigint; tvlB: bigint }> {
  const [tvlA, tvlB] = await Promise.all([
    readOnlyClient.readContract({ address: vaultAddress, abi: PAIR_VAULT_ABI, functionName: "tvlA" }),
    readOnlyClient.readContract({ address: vaultAddress, abi: PAIR_VAULT_ABI, functionName: "tvlB" }),
  ]);
  return { tvlA: tvlA as bigint, tvlB: tvlB as bigint };
}

/**
 * The pool's real, current price — read straight from the pool's own
 * `slot0()`, not inferred from an oracle. This is what the risk math should
 * measure against: a Pyth USD peg can (and, on a freely-mintable demo pool,
 * does) diverge from the pool's actual traded price once real swaps move it
 * — the contract's own sanity gate already uses this same source of truth,
 * so the solver's own decision should too, rather than risk disagreeing with
 * the chain about whether a band is actually near its edge.
 */
export async function readPoolPrice(poolAddress: Hex): Promise<{ price: number; sqrtPrice: number; tick: number }> {
  const [sqrtPriceX96, tick] = (await readOnlyClient.readContract({
    address: poolAddress,
    abi: POOL_ABI,
    functionName: "slot0",
  })) as [bigint, number, number, number, number, number, boolean];
  const sqrtPrice = Number(sqrtPriceX96) / 2 ** 96;
  return { price: sqrtPrice * sqrtPrice, sqrtPrice, tick };
}
