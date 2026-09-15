# Aurora Intents integration

Any-chain vault deposits via Aurora Intents Connect.

## Why this is a real fit, not a bolt-on

Rangekeeper's whole liquidity-sourcing problem — bootstrapping vault TVL (math
spec §5, architecture spec §5) — is exactly what Intents Connect solves. Today
a depositor needs USDC or ETH already sitting on Monad to fund a `PairVault`.
With **Intents Connect's deposit-and-execute flow**, someone holding USDC on
Solana, Arbitrum, Base, or any of Aurora's 31+ supported source chains can fund
a Rangekeeper vault in one signed intent — the deposit itself triggers
`PairVault.depositFor()` the moment funds land on Monad, no manual bridging,
no separate swap step. **Monad is confirmed as a fully supported Intents
Connect destination chain** (checked directly against
`docs.intents.aurora.dev/intents-connect/supported-chains`).

This also opens a second revenue lever beyond the protocol's existing fee
split (math spec eq. 10): Intents Connect lets an integrator set a custom fee
on every cross-chain flow, with a 40–60% revenue share back to the integrator.
Every cross-chain deposit into a Rangekeeper vault could carry its own small
protocol fee, independent of the swap-fee revenue the vault earns afterward.

## The interface gap this surfaced

Aurora's own worked example (depositing into Aave from Solana) calls
`supply(asset, amount, onBehalfOf, referralCode)` — the destination contract
call explicitly names a beneficiary. That's necessary because the account
that actually executes on the destination chain is a **transient MPC-derived
intermediary** tied to the origin wallet via Chain Signatures, not the user's
own address on Monad. `PairVault.deposit()` had no such parameter — it always
credited `msg.sender`, which for a cross-chain deposit would be that
intermediary, not the real depositor. Fixed by adding `depositFor(asset,
amount, onBehalfOf)` (see `src/PairVault.sol`, `test/PairVault.t.sol`
`test_depositFor_creditsBeneficiaryNotCaller`) — the caller still pays
(`transferFrom(msg.sender, ...)`), only share *ownership* goes to the named
beneficiary. This is a real protocol improvement independent of Aurora too:
anyone depositing on someone else's behalf (a custodian, an automation
script) benefits from it.

## The actual API call, pointed at Rangekeeper

Checked against Aurora's real Aave-from-Solana example
(`docs.intents.aurora.dev/intents-connect/examples/deposit-into-aave-from-solana`).
The `steps` entry is the destination-chain contract call — swap Aave's
`supply(...)` for our `depositFor(...)`:

```javascript
// POST https://intents-connect-alpha-api.aurora.dev/api/v1/executions/{originWalletAddress}
{
  "dry": false,
  "metadata": {
    "intent": "rangekeeper_deposit",
    "title": "Deposit into Rangekeeper (ETH/USDC vault)"
  },
  "quote": {
    "amount": "{ORIGIN_AMOUNT}",
    "originAsset": "nep141:sol.omft.near",
    // Real, fetched from GET /api/v1/supported_tokens (no API key needed for
    // this endpoint) — Monad USDC, chain id 143. See the note below: 143 is
    // Monad MAINNET, not testnet (10143), where the actual deployed vault lives.
    "destinationAsset": "nep245:v2_1.omni.hot.tg:143_2dmLwYWkCQKyTjeUPAsGJuiVLbFx",
    "slippageTolerance": 100
  },
  "type": "evm",
  "steps": [
    {
      // Standard ERC20 approve, same as Aurora's own example — PairVault
      // pulls funds via transferFrom, so the intermediary must approve it.
      "functionSignature": "approve(address,uint256)",
      "parameters": ["{PAIR_VAULT_ADDRESS}", "{MIN_AMOUNT_OUT}"],
      "to": "{USDC_ADDRESS}",
      "value": "0"
    },
    {
      "functionSignature": "depositFor(address,uint256,address)",
      "parameters": ["{USDC_ADDRESS}", "{MIN_AMOUNT_OUT}", "{ORIGIN_USER_MONAD_ADDRESS}"],
      "to": "{PAIR_VAULT_ADDRESS}",
      "value": "0"
    }
  ]
}
```

The user then signs once with their origin-chain wallet (e.g. a Solana
wallet); Aurora's MPC-controlled intermediary bridges, approves, and calls
`depositFor` on their behalf, crediting vault shares directly to their own
Monad address (`{ORIGIN_USER_MONAD_ADDRESS}`) — the fix above is what makes
that last step actually work correctly.

## What's needed to actually go live

- ~~A deployed `PairVault` address~~ — done, see the main README's Status
  section.
- ~~The exact NEAR omft asset ids for Monad-side USDC~~ — done, pulled from
  the real `GET https://intents-connect-api.aurora.dev/api/v1/supported_tokens`
  endpoint (no API key needed for this one call) rather than guessed. Real
  value: `nep245:v2_1.omni.hot.tg:143_2dmLwYWkCQKyTjeUPAsGJuiVLbFx` (USDC),
  `nep245:v2_1.omni.hot.tg:143_11111111111111111111` (native MON).
- **A real blocker found doing that lookup**: every one of those asset ids
  encodes chain id `143` — Monad **mainnet**, not testnet (`10143`), and
  `monad` appears exactly once in the full supported-token list (no separate
  testnet entry). Aurora Intents Connect does not currently have a route into
  Monad testnet, which is where the deployed vault above actually lives. The
  worked example in this file is real and correctly shaped, but there is
  nothing on the other end of it to land on right now — this isn't a
  configuration gap, it's Aurora not supporting the network the vault is on.
  Confirm this hasn't changed (re-run the query above) before building
  further on it; it'll start working the moment a vault exists on Monad
  mainnet, with no changes needed to the call shape above.
- A real Aurora Intents Connect API key — self-serve at
  [portal.intents.aurora.dev](https://portal.intents.aurora.dev/) → API keys
  → Create API key. Worth getting regardless, since it's free and doesn't
  expire, but there's nothing to test it against on testnet yet.
- A small frontend flow (a "Deposit from any chain" entry point in
  `frontend/index.html`, wallet-connect for the origin chain, signing the
  intent) — not yet built, and not worth building before the testnet gap
  above is resolved.

This integration is written against Aurora's real, fetched documentation and
example, but untested end-to-end for the reason above. Flagged here rather
than claimed done.
