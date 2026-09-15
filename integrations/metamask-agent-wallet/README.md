# mm-plugin-rangekeeper

MetaMask Agent Wallet CLI (`mm`) plugin for [Rangekeeper](../../README.md) —
an adaptive liquidity protocol on Monad where a vault is its own Uniswap v3
liquidity provider and recenters its own concentrated-liquidity band as price
moves, instead of sitting still until it goes one-sided and stops earning.

Adds Rangekeeper as a protocol plugin for MetaMask's Agent Wallet CLI, so a
deposit or a status check can be driven the same way any other Agent Wallet
command is.

## What it does

Two commands, both routed entirely through Agent Wallet's own signing —
this plugin never handles a key:

- **`mm rangekeeper status`** — real-time read of a live `PairVault`'s
  on-chain state (`wallet-read`).
- **`mm rangekeeper deposit`** — deposits into a vault, pushing a fresh Pyth
  price atomically in the same transaction (`wallet-read` + `wallet-submit`).
  Prints a plan by default; only submits with `--confirm`.

See [`skills/rangekeeper/SKILL.md`](skills/rangekeeper/SKILL.md) for the
full command reference an agent needs.

## Real Monad testnet support

Confirmed directly against Agent Wallet's own supported-chains list: **Monad
Testnet (chainId 10143)** is a preconfigured network, and **Monad mainnet
(143)** is Transaction-Shield-covered — this isn't a "bring your own RPC"
workaround, Monad is a first-class chain here.

## Install (local development)

Requires Node.js 22+ and `@metamask/agent-wallet` ^6.2.0.

```bash
npm install
npm run build

mm config set experimentalPlugins true
mm config set experimentalAllowUnverifiedInstalls true

mm plugins install "file:///absolute/path/to/integrations/metamask-agent-wallet" --accept-permissions
mm rangekeeper status --json
```

(On Windows, a `file:` URI needs forward slashes — `file:///C:/Users/you/...`
— a plain `$PWD`-style path fails with a confusing npm ENOENT, found live
while building this.)

`mm rangekeeper status`/`deposit` both require `mm login` (Agent Wallet
authentication) and `mm init` (wallet setup) first — this plugin never
performs those steps itself.

`deposit` additionally needs `HERMES_API_KEY` set (Hermes has required a key
since 2026-08-26 — free at pyth.network).

## Verified, not assumed

- Both commands build and register correctly (`oclif manifest` lists exactly
  `rangekeeper:status` and `rangekeeper:deposit`).
- Installed for real via `mm plugins install`, confirmed discoverable via
  `mm plugins` and `mm rangekeeper --help`.
- The auth gate was confirmed live: running a command pre-login returns a
  clean `AUTH_FAILED` from the host, not a plugin crash.
- Every API surface used here (`PluginCommand`, the manifest schema,
  `ctx.publicClient`, `ctx.walletExecutor`, the quote-then-submit pattern)
  was checked against MetaMask's own docs and the real `ens` example plugin
  before writing any code.

## What's not done

- Not published to npm — installed locally via `file:` so far.
- Not run against a real logged-in wallet end-to-end (that step needs the
  developer's own `mm login`/`mm init`, which this plugin doesn't and
  shouldn't perform itself).
- `--vault` defaults to the tier-0 USDC/AUSD vault; there's no command yet to
  discover *all* live Rangekeeper vaults (would need `VaultFactory.allVaults`
  enumeration).
