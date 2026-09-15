import {
  type CommandIO,
  CommandError,
  InputFieldType,
  type InputSchema,
  PluginCommand,
  schemaToArgs,
  schemaToFlags,
} from "@metamask/agent-wallet/plugin";
import { isAddress, parseAbi, type Address } from "viem";

// The live tier-1 PairVault on Monad testnet. Update as new vaults are
// deployed and wired up.
const DEFAULT_VAULT = "0xD534BdcC0E5a4E703A43Be055c5EFFD938114528" as const;
const MONAD_TESTNET_CHAIN_ID = 10143;

const PAIR_VAULT_ABI = parseAbi([
  "function assetA() view returns (address)",
  "function assetB() view returns (address)",
  "function decimalsA() view returns (uint8)",
  "function decimalsB() view returns (uint8)",
  "function tier() view returns (uint8)",
  "function tvlA() view returns (uint256)",
  "function tvlB() view returns (uint256)",
  "function totalShares() view returns (uint256)",
  "function band() view returns (int24 tickLower, int24 tickUpper, uint128 liquidity)",
]);

const inputs = {
  vault: {
    type: InputFieldType.Text,
    flag: "vault",
    message: `Rangekeeper vault address (default: the live Monad testnet demo vault, ${DEFAULT_VAULT})`,
    required: false,
    index: 0,
  },
} satisfies InputSchema;

interface RangekeeperStatusResult {
  vault: Address;
  assetA: Address;
  assetB: Address;
  tier: number;
  tvlA: string;
  tvlB: string;
  totalShares: string;
  bandOpen: boolean;
  bandTickLower: number;
  bandTickUpper: number;
  bandLiquidity: string;
  navNote: string;
}

/// A real, live-chain read against a deployed Rangekeeper PairVault — see
/// the main repo (github.com/<org>/Rangekeeper) for the contract source.
/// Rangekeeper is an adaptive liquidity protocol: a vault is its own sole
/// Uniswap v3 liquidity provider, and recenters its own concentrated-liquidity
/// band as price moves instead of sitting still until it goes one-sided.
export default class RangekeeperStatus extends PluginCommand<RangekeeperStatusResult> {
  static override description =
    "Show a Rangekeeper vault's real on-chain state on Monad (TVL, shares, open band).";

  static override examples = [
    "<%= config.bin %> rangekeeper status",
    "<%= config.bin %> rangekeeper status --vault 0xD534BdcC0E5a4E703A43Be055c5EFFD938114528 --json",
  ];

  static override requiresAuth = true;
  static override requiresInit = true;
  static override flags = schemaToFlags(inputs);
  static override args = schemaToArgs(inputs);

  protected readonly pluginCommandId = "rangekeeper:status";

  async execute(io: CommandIO): Promise<RangekeeperStatusResult> {
    const { vault: vaultInput } = await io.resolveInputs(inputs);
    const vault = (vaultInput || DEFAULT_VAULT) as Address;

    if (!isAddress(vault)) {
      throw new CommandError("RANGEKEEPER_BAD_ADDRESS", `'${vault}' is not a valid address.`, "Pass a 0x-prefixed vault address.");
    }

    const client = this.ctx.publicClient(MONAD_TESTNET_CHAIN_ID);

    const [assetA, assetB, tier, tvlA, tvlB, totalShares, band] = await Promise.all([
      client.readContract({ address: vault, abi: PAIR_VAULT_ABI, functionName: "assetA" }).catch(rethrow),
      client.readContract({ address: vault, abi: PAIR_VAULT_ABI, functionName: "assetB" }).catch(rethrow),
      client.readContract({ address: vault, abi: PAIR_VAULT_ABI, functionName: "tier" }).catch(rethrow),
      client.readContract({ address: vault, abi: PAIR_VAULT_ABI, functionName: "tvlA" }).catch(rethrow),
      client.readContract({ address: vault, abi: PAIR_VAULT_ABI, functionName: "tvlB" }).catch(rethrow),
      client.readContract({ address: vault, abi: PAIR_VAULT_ABI, functionName: "totalShares" }).catch(rethrow),
      client.readContract({ address: vault, abi: PAIR_VAULT_ABI, functionName: "band" }).catch(rethrow),
    ]);
    const [bandTickLower, bandTickUpper, bandLiquidity] = band;

    return {
      vault,
      assetA,
      assetB,
      tier,
      tvlA: tvlA.toString(),
      tvlB: tvlB.toString(),
      totalShares: totalShares.toString(),
      bandOpen: bandLiquidity > 0n,
      bandTickLower,
      bandTickUpper,
      bandLiquidity: bandLiquidity.toString(),
      navNote: "navWad()/utilization() aren't included here — they revert if the vault's Pyth price is >60s stale; use rangekeeper deposit's built-in fresh-price path instead of a separate stale read.",
    };
  }

  override successHint(data: RangekeeperStatusResult): string {
    const bandNote = data.bandOpen ? `band [${data.bandTickLower},${data.bandTickUpper}]` : "no band open";
    return `${data.vault}: tvlA=${data.tvlA} tvlB=${data.tvlB} shares=${data.totalShares} ${bandNote}`;
  }
}

function rethrow(error: unknown): never {
  throw new CommandError(
    "RANGEKEEPER_RPC_ERROR",
    `Rangekeeper vault read failed: ${error instanceof Error ? error.message : String(error)}`,
    "Check the vault address and that Monad testnet is reachable.",
  );
}
