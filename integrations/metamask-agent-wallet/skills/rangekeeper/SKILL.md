---
name: rangekeeper
description: Deposit into and inspect Rangekeeper adaptive-liquidity vaults on Monad via the MetaMask Agent Wallet CLI (mm). Covers `mm rangekeeper status` (real vault TVL/shares/band, read-only) and `mm rangekeeper deposit` (quote-then-submit deposit, priced by a fresh Pyth update in the same transaction). Use when the user asks to check a Rangekeeper vault, deposit into an adaptive-liquidity vault on Monad, or mentions Rangekeeper, PairVault, or a vault that "recenters its own Uniswap v3 liquidity band."
license: MIT
metadata:
  author: rangekeeper
  version: "0.1.0"
  cliVersion: "6.2.0"
  network: "Monad testnet (chainId 10143)"
---

# Rangekeeper Agent Wallet plugin

Rangekeeper is an adaptive liquidity protocol on Monad: each vault is its own
sole Uniswap v3 liquidity provider, and recenters its own concentrated-liquidity
band as price moves instead of sitting still until it goes one-sided. This
plugin lets an agent check a vault's real on-chain state and deposit into
one, entirely through Agent Wallet's own signing and policy.

## Commands

### `mm rangekeeper status [--vault <address>]`

Read-only (`wallet-read`). Reads a live Rangekeeper `PairVault` on Monad
testnet directly via an authenticated RPC client — `assetA`/`assetB`,
`tvlA`/`tvlB`, `totalShares`, and the vault's open band (ticks + liquidity,
if any). Defaults to the live tier-1 vault
(`0xD534BdcC0E5a4E703A43Be055c5EFFD938114528`) if `--vault` is omitted.

Use this first, always, before a deposit — to confirm the vault address is
real and to read `assetA`/`assetB` so you know which address to pass as
`--asset` to `deposit`.

### `mm rangekeeper deposit --asset <address> --amount <human-amount> [--vault <address>] [--confirm]`

Two-step: `approve` then `depositWithPriceUpdate`. Fetches a fresh Pyth price
from Hermes and pushes it in the *same* transaction as the deposit — the
vault's `MAX_PRICE_AGE` is 60 seconds, so a separately-pushed price reliably
goes stale before a second transaction lands; this is why `deposit` doesn't
take a plain "amount + wait" shape.

**Without `--confirm`** (the default): returns a plan only — the resolved
amount in raw units, the exact Pyth update fee in wei, and the two steps that
would run. Nothing is signed. Always show this plan to the user and get
their explicit go-ahead before adding `--confirm`.

**With `--confirm`**: submits both transactions through
`ctx.walletExecutor` — Agent Wallet's own signing, still policy-gated (guard
mode, Transaction Shield, MFA). This plugin never handles a private key or a
seed phrase and cannot bypass that policy.

Requires `HERMES_API_KEY` in the environment (Hermes has required an API key
since 2026-08-26 — a free key is available at pyth.network). If it's
missing, the command fails with a clear `RANGEKEEPER_NO_HERMES_KEY` error
rather than a confusing downstream failure.

## Safety notes for the agent

- Never run `deposit --confirm` without the user explicitly agreeing to the
  plan `deposit` (without `--confirm`) just printed — amount, asset, vault,
  and fee.
- `--asset` must be exactly the vault's `assetA` or `assetB` (check via
  `status` first) — anything else fails fast with `RANGEKEEPER_UNKNOWN_ASSET`
  rather than silently doing the wrong thing.
- `--amount` is human-readable (e.g. `20`, not `20000000`) — the plugin
  converts to the asset's own on-chain decimals internally.
- This plugin targets Monad testnet (chainId 10143) specifically; Monad
  mainnet (143) is also a Transaction-Shield-covered chain on Agent Wallet,
  but no Rangekeeper vault is deployed there.

## Local install (development)

```bash
mm config set experimentalPlugins true
mm config set experimentalAllowUnverifiedInstalls true
mm plugins install "file:///absolute/path/to/integrations/metamask-agent-wallet" --accept-permissions
mm rangekeeper status --json
```
