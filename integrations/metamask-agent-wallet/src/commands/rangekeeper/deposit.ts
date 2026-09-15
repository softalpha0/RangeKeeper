import {
  type CommandIO,
  CommandError,
  InputFieldType,
  type InputSchema,
  PluginCommand,
  schemaToArgs,
  schemaToFlags,
} from "@metamask/agent-wallet/plugin";
import { encodeFunctionData, isAddress, parseAbi, parseUnits, type Address, type Hex } from "viem";

const DEFAULT_VAULT = "0xD534BdcC0E5a4E703A43Be055c5EFFD938114528" as const;
const MONAD_TESTNET_CHAIN_ID = 10143;
const HERMES_ENDPOINT = "https://hermes.pyth.network";

const PAIR_VAULT_ABI = parseAbi([
  "function assetA() view returns (address)",
  "function assetB() view returns (address)",
  "function decimalsA() view returns (uint8)",
  "function decimalsB() view returns (uint8)",
  "function priceIdA() view returns (bytes32)",
  "function priceIdB() view returns (bytes32)",
  "function pyth() view returns (address)",
  "function depositWithPriceUpdate(address asset, uint256 amount, bytes[] priceUpdateData) payable returns (uint256 shares)",
]);

const ERC20_ABI = parseAbi(["function approve(address spender, uint256 amount) returns (bool)"]);
const PYTH_ABI = parseAbi(["function getUpdateFee(bytes[] updateData) view returns (uint256)"]);

const inputs = {
  vault: {
    type: InputFieldType.Text,
    flag: "vault",
    message: `Rangekeeper vault address (default: ${DEFAULT_VAULT})`,
    required: false,
    index: 0,
  },
  asset: {
    type: InputFieldType.Text,
    flag: "asset",
    message: "Which side to deposit — the vault's assetA or assetB address",
    required: true,
    index: 1,
  },
  amount: {
    type: InputFieldType.Text,
    flag: "amount",
    message: "Human-readable amount to deposit, e.g. 20 (not raw units)",
    required: true,
    index: 2,
  },
  confirm: {
    type: InputFieldType.Boolean,
    flag: "confirm",
    message: "Actually submit — omit this to just see the plan",
    default: false,
    prompt: false,
  },
} satisfies InputSchema;

interface DepositPlan {
  vault: Address;
  asset: Address;
  amountHuman: string;
  amountRaw: string;
  pythUpdateFeeWei: string;
  submitted: boolean;
  steps: Array<{ description: string; to: Address; hash?: Hex; status?: string }>;
}

/// Deposits into a live Rangekeeper vault on Monad — an adaptive liquidity
/// protocol where a vault is its own sole Uniswap v3 liquidity provider and
/// recenters its own concentrated-liquidity band as price moves. Every
/// transaction routes through Agent Wallet's own signing and policy; this
/// command only ever computes calldata and a Hermes price update, it never
/// touches keys. See the main Rangekeeper repo for the contract source
/// (src/PairVault.sol) and why the deposit needs a fresh Pyth price pushed
/// atomically (PairVault's MAX_PRICE_AGE is 60s, so a separately-pushed
/// price reliably goes stale before a second transaction lands —
/// depositWithPriceUpdate exists specifically to fix that).
export default class RangekeeperDeposit extends PluginCommand<DepositPlan> {
  static override description =
    "Deposit into a Rangekeeper vault on Monad, pricing it with a fresh Pyth update in the same transaction. Prints a plan by default — pass --confirm to actually submit.";

  static override examples = [
    "<%= config.bin %> rangekeeper deposit --asset 0x1053f9E8bB4e0eCFB8891B8ac174C78B302601e8 --amount 20",
    "<%= config.bin %> rangekeeper deposit --asset 0x1053f9E8bB4e0eCFB8891B8ac174C78B302601e8 --amount 20 --confirm",
  ];

  static override requiresAuth = true;
  static override requiresInit = true;
  static override flags = schemaToFlags(inputs);
  static override args = schemaToArgs(inputs);

  protected readonly pluginCommandId = "rangekeeper:deposit";

  async execute(io: CommandIO): Promise<DepositPlan> {
    const { vault: vaultInput, asset: assetInput, amount, confirm } = await io.resolveInputs(inputs);
    const vault = (vaultInput || DEFAULT_VAULT) as Address;
    const asset = assetInput as Address;

    if (!isAddress(vault)) throw new CommandError("RANGEKEEPER_BAD_VAULT", `'${vault}' is not a valid address.`, "Pass a 0x-prefixed vault address, or omit --vault to use the default.");
    if (!isAddress(asset)) throw new CommandError("RANGEKEEPER_BAD_ASSET", `'${asset}' is not a valid address.`, "Pass the vault's assetA or assetB address — see rangekeeper status.");

    const client = this.ctx.publicClient(MONAD_TESTNET_CHAIN_ID);

    const [assetA, assetB, decimalsA, decimalsB, priceIdA, priceIdB, pythAddress] = await Promise.all([
      client.readContract({ address: vault, abi: PAIR_VAULT_ABI, functionName: "assetA" }),
      client.readContract({ address: vault, abi: PAIR_VAULT_ABI, functionName: "assetB" }),
      client.readContract({ address: vault, abi: PAIR_VAULT_ABI, functionName: "decimalsA" }),
      client.readContract({ address: vault, abi: PAIR_VAULT_ABI, functionName: "decimalsB" }),
      client.readContract({ address: vault, abi: PAIR_VAULT_ABI, functionName: "priceIdA" }),
      client.readContract({ address: vault, abi: PAIR_VAULT_ABI, functionName: "priceIdB" }),
      client.readContract({ address: vault, abi: PAIR_VAULT_ABI, functionName: "pyth" }),
    ]);

    let decimals: number;
    let priceId: Hex;
    if (asset.toLowerCase() === assetA.toLowerCase()) {
      decimals = decimalsA;
      priceId = priceIdA;
    } else if (asset.toLowerCase() === assetB.toLowerCase()) {
      decimals = decimalsB;
      priceId = priceIdB;
    } else {
      throw new CommandError(
        "RANGEKEEPER_UNKNOWN_ASSET",
        `'${asset}' is neither this vault's assetA (${assetA}) nor assetB (${assetB}).`,
        "Pass one of those two addresses.",
      );
    }

    const amountRaw = parseUnits(amount, decimals);

    const apiKey = process.env.HERMES_API_KEY;
    if (!apiKey) {
      throw new CommandError(
        "RANGEKEEPER_NO_HERMES_KEY",
        "HERMES_API_KEY is not set.",
        "Hermes (Pyth's price service) has required an API key since 2026-08-26 — get a free one at pyth.network and export HERMES_API_KEY.",
      );
    }

    const priceRes = await fetch(`${HERMES_ENDPOINT}/v2/updates/price/latest?ids[]=${priceId}`, {
      headers: { Authorization: `Bearer ${apiKey}` },
    });
    if (!priceRes.ok) {
      throw new CommandError("RANGEKEEPER_HERMES_ERROR", `Hermes request failed: ${priceRes.status}`, "Check HERMES_API_KEY and network access.");
    }
    const priceJson = (await priceRes.json()) as { binary: { data: string[] } };
    const updateData = `0x${priceJson.binary.data[0]}` as Hex;

    const updateFee = await client.readContract({
      address: pythAddress,
      abi: PYTH_ABI,
      functionName: "getUpdateFee",
      args: [[updateData]],
    });

    const approveData = encodeFunctionData({ abi: ERC20_ABI, functionName: "approve", args: [vault, amountRaw] });
    const depositData = encodeFunctionData({
      abi: PAIR_VAULT_ABI,
      functionName: "depositWithPriceUpdate",
      args: [asset, amountRaw, [updateData]],
    });

    const plan: DepositPlan = {
      vault,
      asset,
      amountHuman: amount,
      amountRaw: amountRaw.toString(),
      pythUpdateFeeWei: updateFee.toString(),
      submitted: false,
      steps: [
        { description: `approve(vault, ${amountRaw}) on ${asset}`, to: asset },
        { description: `depositWithPriceUpdate(${asset}, ${amountRaw}, [freshPythUpdate])`, to: vault },
      ],
    };

    if (!confirm) {
      return plan; // quote-only — this is the default
    }

    // Only from here on does anything actually get signed. Every request
    // goes through Agent Wallet's own executor — this command never handles
    // a key or bypasses policy/MFA.
    const executor = await this.ctx.walletExecutor(io, this.pluginCommandId, { emitStepNotices: true });
    type WalletRequest = Parameters<typeof executor>[0];

    const approveResult = await executor({
      kind: "transaction",
      chainId: MONAD_TESTNET_CHAIN_ID,
      transaction: { to: asset, data: approveData, value: 0n },
      intent: { summary: `Approve Rangekeeper vault to pull ${amount} tokens`, action: "call", details: { vault, asset, amountRaw: amountRaw.toString() } },
    } as unknown as WalletRequest);
    plan.steps[0].hash = (approveResult as { hash?: Hex }).hash;
    plan.steps[0].status = (approveResult as { kind?: string }).kind;

    if (!plan.steps[0].hash) {
      throw new CommandError("RANGEKEEPER_APPROVE_FAILED", "The approve step did not return a transaction hash.", "Check the executor result and try again.");
    }
    await client.waitForTransactionReceipt({ hash: plan.steps[0].hash });

    const depositResult = await executor({
      kind: "transaction",
      chainId: MONAD_TESTNET_CHAIN_ID,
      transaction: { to: vault, data: depositData, value: updateFee },
      intent: {
        summary: `Deposit ${amount} into Rangekeeper vault ${vault}, pricing it with a fresh Pyth update in the same tx`,
        action: "call",
        details: { vault, asset, amountRaw: amountRaw.toString(), pythUpdateFeeWei: updateFee.toString() },
      },
    } as unknown as WalletRequest);
    plan.steps[1].hash = (depositResult as { hash?: Hex }).hash;
    plan.steps[1].status = (depositResult as { kind?: string }).kind;
    plan.submitted = true;

    return plan;
  }

  override successHint(data: DepositPlan): string {
    return data.submitted
      ? `Deposited ${data.amountHuman} into ${data.vault} — tx ${data.steps[1]?.hash ?? "(pending)"}`
      : `Plan ready: ${data.amountHuman} of ${data.asset} into ${data.vault} (fee ${data.pythUpdateFeeWei} wei). Re-run with --confirm to submit.`;
  }
}
