# Rangekeeper

Adaptive liquidity protocol for Monad — a vault that is its own Uniswap v3 liquidity
provider, and recenters its own concentrated-liquidity band as price moves instead of
sitting still until it goes one-sided and stops earning.

Each vault is the sole liquidity provider for its pair, against one fixed pool set at
deployment: it opens one concentrated-liquidity band and recenters it — closes it,
reopens it nearer the live price — as conditions change, gated by on-chain
re-validation (trigger, sanity check, cooldown) plus a real circuit breaker that sits
out a crash instead of chasing it. `VaultManager` is the keeper entry point and never
trusts a keeper's numbers at face value; `PairVault` holds depositor capital and
manages its own band. See [`src/PairVault.sol`](src/PairVault.sol) and
[`src/VaultManager.sol`](src/VaultManager.sol)'s doc comments for the full technical
writeup.

**73/73 Foundry tests pass**, including a full recenter cycle and a real
circuit-breaker pause + resume against a real deployed Uniswap v3 factory and pool, an
80/15/5 fee split paid to a real third-party keeper, a real Aave-V3-shaped yield
adapter, and a public faucet that's what actually lets a new wallet try any
of this, plus **24/24 off-chain solver tests**. Live on Monad testnet
(chain `10143`) — see "Status" below for addresses.

## Specs

This repo implements two internal design documents (a math spec and an architecture
spec, not published) — code comments reference their equation/section numbers instead
of re-deriving the math.

## Layout

```
src/                  Solidity contracts (Foundry)
  interfaces/         IPairVault, IVaultManager, IParamsRegistry, IYieldSource, IAaveV3Pool
  libraries/          RiskMath — the on-chain re-validation checks (trigger, sanity band)
                      LiquidityMath — token amounts <-> Uniswap v3 liquidity, both directions
                      FullMath / TickMath / SqrtPriceMath — the underlying fixed-point primitives
  adapters/
    AaveV3YieldAdapter.sol Real Aave-V3-shaped spare-pocket yield source (see "Spare-pocket yield" below)
  PairVault.sol        Isolated per-pair vault, and the sole Uniswap v3 LP for its pair (see below)
  VaultManager.sol      Registry of tier -> vault; the sole keeper entry point for recentering
  ParamsRegistry.sol   Timelocked per-tier risk parameters
  VaultFactory.sol      Deploys a PairVault per tier
  demo/
    DemoToken.sol       Freely-mintable ERC20 — testing only, not a protocol contract
    DemoTokenFaucet.sol Public, rate-limited faucet for the demo tokens above (see "Status" below)
script/
  DeployRangekeeper.s.sol  Deploys own Uniswap v3 factory (testnet has no canonical one) + core stack
  SetupVault.s.sol      Second-stage setup: demo tokens, pool, tier-1 vault
  SetupTier2.s.sol      Sets up the real USDC/DMOA pair as tier 2
  DemoLoop.s.sol        One-command local demo of the entire recenter loop (see below)
vendor/
  CompileUniswapV3Factory.sol  Forces the real UniswapV3Factory to compile into a deployable
                               artifact — see its own header comment and the `vendor` Foundry
                               profile in foundry.toml (needed once, before the first `forge build`)
test/                Foundry tests (needs forge-std, see Setup)
  utils/V3TestRouter.sol  Minimal swap router for tests — real trades against a real pool
solver/               Off-chain monitoring loop (Node/TypeScript)
  src/math.ts          Off-chain twin of RiskMath.sol's trigger/sanity checks, plus band sizing
  src/pyth.ts          Hermes REST client — live prices (needs HERMES_API_KEY, see .env.example)
  src/volatility.ts    Realized sigma from a rolling Pyth price window
  src/chain.ts         viem client — encodes proofs, signs and sends the actual recenter txs
  src/loop.ts          Per-block monitoring loop — reads each tier's vault directly, no indexer
frontend/              Static site — `npx serve frontend -l 5173`
  index.html           Landing page — what Rangekeeper is, how the mechanism works
  app.html             Live dapp — reads real vault/band state off Monad via viem; wallet connect; deposit helper
  status.html          Build log / worked-example dashboard
  whitepaper.html       The full mechanism, with equations, matched to the deployed contracts
integrations/
  aurora-intents/      Any-chain vault deposits via Aurora Intents Connect (see below)
  metamask-agent-wallet/  `mm rangekeeper status`/`deposit` — Agent Wallet CLI plugin (see below)
```

## Uniswap v3 integration

`PairVault` is the sole liquidity provider for its pair, against one fixed pool set
immutably at construction — there's no shared pool-manager singleton to key into, and
no separate hook needed just to know the current price: a v3 pool's `slot0()` is a
plain public view call, readable by anyone at any time. `VaultManager.recenter` reads
it directly at the moment a recenter is proposed and checks a keeper's proof against
**two** independent things — the proof's own dMin/sigma crossing the tier's z-score
trigger, *and* the pool's real live price actually being near the band's edge (no
logarithm needed on-chain — see `RiskMath.withinEdgeBand`). A keeper can no longer
fabricate an urgent-looking proof for a band the chain can see is sitting comfortably
centered. `test/VaultManager.t.sol` exercises exactly this.

### Recenter execution

`VaultManager.recenter` re-derives its justification from `RiskMath` before touching
anything, then calls `PairVault.closeBand()` followed by `PairVault.openBand()` — both
of which actually move real liquidity via the pool's own `mint`/`burn`/`collect`,
funded from (and returned to) the vault's own balances. `openBand` triggers
`uniswapV3MintCallback` synchronously, which is what actually pays the pool out of the
vault's idle balance. Converting a token amount into a `liquidity` value needs the
inverse of what a v3 pool computes internally (`SqrtPriceMath.getAmount0Delta`/
`getAmount1Delta` go liquidity→amounts, not amounts→liquidity); the standard formulas
for that direction are the same ones v3-periphery's `LiquidityAmounts.sol` ships, ported
directly here (`LiquidityMath.sol`) against this repo's own `FullMath.mulDiv` rather
than pulling in periphery's whole dependency chain for two pure functions — verified
by round-tripping through the real `SqrtPriceMath` in `test/LiquidityMath.t.sol` rather
than trusted by inspection. `LiquidityMath` also ships the inverse of *that*
(`getAmountsForLiquidity`, liquidity → amounts) so `PairVault.navWad()` can price an
open band without closing it first — see "Vault share pricing" below.

`test/PairVaultBand.t.sol` runs the whole open/close path against an actually-deployed
Uniswap v3 pool: it asserts real liquidity lands at the vault's own address for that
tick range, real tokens leave and return to the vault's balance, and that opening or
closing a band is **NAV-neutral**, not NAV-destroying
(`test_openBand_doesNotChangeNav`).

The new band's token split (`amount0Desired`/`amount1Desired`) is keeper-computed
off-chain from whatever's idle in the vault plus an estimate of what closing the old
band will free (`solver/src/math.ts`'s `amountsForLiquidity`) — the contract only
enforces that the resulting liquidity is real and paid for, not that the split is
"optimal"; see `solver/src/math.test.ts` for the boundary cases.

## Vault share pricing

`PairVault` prices deposits against a real dual-asset NAV via Pyth
(`getPriceNoOlderThan`, 60s staleness bound). Deposits mint shares proportional to
`amountRaw * priceWad / 10^decimals`; withdrawals stay a proportional claim on idle
token balances (see `test/PairVault.t.sol`, which specifically asserts a 30x-value
deposit gets exactly 30x the shares).

`navWad()` sums idle balances (`tvlA`/`tvlB`, the "spare pocket") **plus the live
value of any currently-open band** (the "working pocket"), via
`LiquidityMath.getAmountsForLiquidity` against the pool's real current price — most of
a vault's value is expected to sit in its own band by design, so NAV has to price that
band live rather than only the idle balances sitting alongside it.
`test/PairVaultBand.t.sol`'s `test_openBand_doesNotChangeNav` is the regression guard.

`depositFor(asset, amount, onBehalfOf)` credits shares to a named beneficiary instead
of `msg.sender` — needed for cross-chain deposit flows where the caller is a
transient intermediary account, not the real depositor. See `integrations/aurora-intents/`.

Two design details worth flagging:

- `navWad()` skips pricing a zero-balance side entirely, so a single-sided deposit
  into an empty vault never depends on the *other* asset's Pyth feed being fresh or
  reachable — that side holds zero balance and contributes zero value either way.
- `depositWithPriceUpdate(asset, amount, priceUpdateData)` pushes a Pyth update and
  prices the deposit atomically in one transaction, rather than depending on some
  other party having recently refreshed the price — the correct general pattern for a
  pull-oracle integration, since two separate transactions can't reliably land inside
  the 60s staleness window (`MAX_PRICE_AGE`) once real block time and signing latency
  are counted. Any excess `msg.value` over the exact Pyth fee is refunded.

## Fee accounting

`PairVault` is the sole liquidity provider for its band. **`PairVault.collectFees`**
is a permissionless harvest that calls the pool's own zero-liquidity `burn` (the
standard "poke this position's fee accounting" idiom, which moves accrued fees into
the position's owed-tokens balance without freeing principal) then `collect`s the
result into `tvlA`/`tvlB`. `test/PairVaultFees.t.sol` verifies this against **real
fees from a real swap** — not a mock, not a zero-fee no-op.

## Frontend

`frontend/` is mostly a static site — `npx serve frontend -l 5173` — plus one
serverless function (see below). Four pages, shared design system:

- **`index.html`** — landing page: the problem (a concentrated position at its range
  edge stops earning), the five-step recenter mechanism, and why a vault managing its
  own band beats a statically wide range.
- **`app.html`** — the live dapp. Reads real state straight off Monad testnet via
  viem + the public RPC (no wallet needed): each tier's vault resolved live via
  `vaultOfTier`, its NAV/idle balances/band/paused state, and a price-vs-band diagram
  against the on-chain sanity check — the pool's own `slot0()` is a plain public read,
  no storage-slot decoding needed. The deposit flow signs two real transactions
  from the connected wallet — `approve`, then `depositWithPriceUpdate` — with no
  manual steps in between (see `api/pyth-update.js` below).
- **`status.html`** — the build log dashboard. The vault-bands table, band detail,
  and recenter history are live reads, same as the app. A separately, unmistakably
  boxed "Mainnet vision" section below them is a deliberate mockup of what this
  looks like once real pairs exist on mainnet — dashed border, repeated "MOCKUP"
  banners, invented numbers.
- **`whitepaper.html`** — the full mechanism with real equations (position-in-range,
  the z-score trigger, the sanity check, fee split, share pricing), matched by
  equation number to `RiskMath.sol`'s own comments, plus the real deployed addresses.
- **`api/pyth-update.js`** — a Vercel serverless function, the one non-static piece
  of this site. `depositWithPriceUpdate` needs a fresh Pyth Hermes price update in
  the same transaction as the deposit, and Hermes requires an API key that a static
  page has nowhere safe to hold — this function holds it server-side (set
  `HERMES_API_KEY` in the Vercel project's environment variables) and proxies the
  one call `app.html` needs, so the browser never sees the key. Mirrors
  `solver/src/pyth.ts`'s `fetchPythUpdateData` exactly, just running server-side.

## Design decision worth flagging

`RiskMath.sol` does **not** compute the normal CDF (Φ) on-chain. The trigger
condition is monotonic in `d_min / (σ√T)`, so each tier's probability threshold is
pre-converted off-chain into an equivalent z-score threshold (`zStar`) stored in
`ParamsRegistry`. The contract only compares two already-scaled numbers — no CDF
approximation, no precision risk, no extra gas. `kMax`/`lcrMin`/`mStar` remain
declared on `IParamsRegistry.TierParams` but are reserved: `VaultManager` v1 reads
only `zStar`, `sigmaMax`, `rSanityLow`, and `rSanityHigh`. This is a deliberate
simplification for v1 — see `IParamsRegistry.sol`'s field comments.

Every recenter re-derives its own justification on-chain rather than trusting a
keeper's numbers: the trigger from the proof, the sanity check against the pool's own
live price, and a 5-minute per-tier cooldown (`MIN_RECENTER_INTERVAL`) so a keeper
can't thrash a band and burn depositor capital on slippage. Without further care, a
circuit-breaker close could reopen unconditionally on the very next call regardless of
whether conditions had actually calmed down — `VaultManager.paused[tier]` avoids that
by distinguishing "never opened a band yet" (opens unconditionally, there being no
edge to be near yet) from "closed due to high volatility" (requires a later call to
find calm conditions before it resumes) — `test/VaultManager.t.sol`'s
`test_recenter_pausesOnHighVolatility_thenRequiresCalmToResume` is the regression
guard.

## Setup

If Foundry isn't installed yet:

```bash
curl -L https://foundry.paradigm.xyz | bash
# restart your terminal, then:
foundryup
```

Then, from this repo (submodules and `foundry.lock` are already committed, so
a fresh clone only needs `git submodule update --init --recursive` if you
didn't clone with `--recurse-submodules`). The real `UniswapV3Factory` this project
deploys itself predates this repo's own Solidity version and can't compile under the
same settings (`via_ir`) the rest of the contracts need, so it lives in its own
Foundry profile (`vendor/`, see `foundry.toml`) — build that once first:

```bash
forge build --profile vendor   # compiles the real UniswapV3Factory into out/, once
forge build
forge test -vvv
```

For the solver:

```bash
cd solver
npm install     # pulls in viem
cp .env.example .env   # fill in PRIVATE_KEY — the rest already points at the live deployment
npm test        # runs math.ts, chain.ts, and volatility.ts's pure functions against known values
npm run loop    # starts the monitoring loop (logs [recenter:dry-run] instead of
                # sending real txs until .env is filled in)
```

## End-to-end demo (one command)

`script/DemoLoop.s.sol` runs the **entire recenter loop** in a single local
simulation — no broadcast, no keys, no RPC:

```bash
forge script script/DemoLoop.s.sol:DemoLoop -vv
```

It deploys the full stack against a real Uniswap v3 factory and pool (only Pyth is
stubbed), then walks every stage with narrated `console.log` output:

1. governance queues tier params and waits out the real 2-day timelock;
2. depositors fund the `PairVault` (NAV-priced shares, atomic Pyth push);
3. the vault opens its own **first band, unconditionally** — nothing to be "near the
   edge" of yet;
4. a keeper tries to recenter while the band is genuinely **centered** → rejected
   with `NotTriggered()`/`OutOfSanityBand()`: the pool's own real live price
   contradicts the "urgent" proof, so no capital moves;
5. swaps push the price to the band's edge;
6. the same recenter now **clears both gates** → the old band closes for real
   (the pool's own position record drops to zero), a new one opens centered on
   the drifted price, and the vault's NAV is unchanged by the move (modulo rounding);
7. more swaps accrue real 0.3% fees; `PairVault.collectFees` harvests them into NAV;
8. a volatility spike trips the **circuit breaker** — the band closes and does *not*
   reopen; capital sits idle, not lost;
9. calmer conditions let a later recenter **resume**, opening a fresh band and
   clearing the pause.

Every step asserts a real on-chain effect (pool position records, token balances,
vault NAV), not just that the call didn't revert.

## Confirmed infra (see architecture spec §8 for sourcing + caveats)

| | Value |
|---|---|
| Monad testnet | chainId `10143`, `https://testnet-rpc.monad.xyz` |
| Monad mainnet | chainId `143`, `https://rpc.monad.xyz` |
| Uniswap v3 factory (mainnet only) | `0x204FaCa1764B154221e35c0d20aBB3c525710498` — confirmed via `eth_getCode` on both networks: real bytecode on mainnet, none on testnet |
| Pyth price feeds (testnet) | `0x2880aB155794e7179c9eE2e38200202908C17B43` — confirmed live (on-chain read succeeded) |
| Testnet faucet (native MON) | `https://faucet.monad.xyz` — confirmed working directly |
| USDC (Circle, testnet) | `0x534b2f3A21130d7a60830c2Df862319e593943A3` — confirmed on-chain (`symbol()`="USDC", `decimals()`=6) |
| AUSD (testnet) | `0xa9012a055bd4e0eDfF8Ce09f960291C09D5322dC` — confirmed on-chain (`symbol()`="AUSD", `decimals()`=6) |

The RPC hostname is `testnet-rpc.monad.xyz` (note the hyphen placement) — verified
against `docs.monad.xyz/developer-essentials/testnet` directly. Monad's own canonical
contract list (`monad-crypto/protocols`) lists a Wrapped MON address with **zero code
on-chain** on testnet (confirmed directly via `eth_getCode`, real bytecode on mainnet
instead) — the same testnet/mainnet split as the Uniswap v3 factory above. USDC and
AUSD are both independently verified live and correct on-chain instead (see table
above), with real Pyth feed ids (`eaa020c6...9e9c94a` / `d9912df3...e07fb2a`).

## Status

**73/73 Foundry tests pass** across `RiskMath`, `LiquidityMath` (including
`getAmountsForLiquidity`), `PairVault`, `PairVaultBand` (a full open/close cycle
against a real deployed Uniswap v3 pool, including the NAV-neutrality regression
guard), `PairVaultFees` (real fees from a real swap, including the 80/15/5
depositor/treasury/keeper split below), `PairVaultYield` (the spare-pocket
sweep/NAV/withdraw wiring below, against a real yield adapter), `AaveV3YieldAdapter`
(real Aave-V3-shaped share accounting, including proportional yield accrual
between two depositors), `DemoTokenFaucet` (rate-limited, per-address, pays
out whatever's left rather than reverting once low), `VaultManager` (including
admin-gating on `setVaultForTier`), and `VaultManagerRecenter` (a
real end-to-end recenter — including the refund-chain proof and a real
circuit-breaker pause/resume with real swaps moving price), plus **24/24
off-chain solver tests** (`math.ts`/`chain.ts`/`volatility.ts`).

**Fee split on every harvest**: `PairVault.collectFees()` splits each
permissionless harvest 80% depositors / 15% protocol treasury / 5% straight to
whoever called it — a starting point, not scripture, matching the source
paper's own framing. The treasury slice funds protocol-owned liquidity later;
there's no token or option mechanism yet on purpose (ship real fees first).
This only applies to standalone `collectFees()` harvests, not the
principal-plus-fees a recenter's `closeBand()` returns — separating those
would need per-position fee-growth snapshotting this version doesn't do,
flagged rather than silently approximated.

**Spare-pocket yield**: `PairVault.sweepIdleToYield()`/`sweepYieldToIdle()` move
idle balance to and from a pluggable `IYieldSource` — `AaveV3YieldAdapter` is a
real implementation against Aave V3's actual `supply`/`withdraw` interface,
tested against a mock Aave pool including proportional interest accrual
between depositors. `navWad()` and `withdraw()` both count whatever's parked
there (live, including accrued interest) as part of a depositor's real claim —
`withdraw()` auto-pulls from the yield source if local balance is short, which
matters: without that, the swept portion would become permanently unclaimable
the moment every share is redeemed. **Unset (`address(0)`) on the live
deployment below** — checked directly, not assumed: Aave V3 is Monad-mainnet-only
(live since July 2026), and the one lending market that existed on Monad
testnet, Kinza Finance, has been retired by its own team in favor of mainnet.
Wires in for real the moment a vault deploys somewhere with an actual venue —
see `PairVault.sol`'s `yieldSource` comment.

**Public demo-token faucet**: `DemoToken.mint` is owner-only, which meant a
stranger connecting a wallet had nothing to deposit and no way to get
anything — `DemoTokenFaucet` is what actually lets someone try the deposit
flow at all. `claim()` pays out 1,000 of each demo token, once per address
per day; funded the plain way (the deployer mints a batch directly into the
faucet's own address — no special minting privilege lives in the faucet
itself). Linked from `app.html` right above the deposit form, along with a
pointer to `faucet.monad.xyz` for real testnet MON (that one needs a human to
clear its own CAPTCHA — can't be automated from here).

**Live on Monad testnet** (chain `10143`):

| Contract | Address |
|---|---|
| Uniswap v3 factory | `0x7Dc4f0eC255F10AB04D46E118Aa4cD2bBCE375B9` |
| ParamsRegistry | `0x8F2A67eb13b3BE226439e0cc446755AA1664a08b` |
| VaultManager | `0x28AC946761572E3b4FeA03163Dc894997b9677FE` |
| VaultFactory | `0xA905e132E5A59d60Edb3C2B387173359A5085922` |
| Tier 1 vault | `0xD534BdcC0E5a4E703A43Be055c5EFFD938114528` |
| Tier 1 pool | `0x0c10bFA619EC1570F76b02562423D7e1e992e5c0` |
| Tier 2 vault | `0xE7C37B9f89A5638d0d6eBAea6eee782DfAdE7F66` |
| Tier 2 pool | `0x29dc969A4CF804Ee8f24DC491F9f30d7545d23a2` |
| Protocol treasury | `0xC4DF991237aFA782885014034eeE8DbDaE95324d` (the team's own wallet for now — no separate treasury contract or DAO yet) |
| Yield source | unset (`address(0)`) — see "Spare-pocket yield" above |
| Demo token faucet | `0x1127012EA9565880aa49Eab79487E1736E228Fb0` |

Each tier has exactly one vault, permanently, resolvable with a single
`vaultOfTier(tier)` view call — no log-scanning indexer needed to discover it.
`solver/src/loop.ts`'s header comment has the full explanation. The vault's own pool,
its two Pyth feed ids, and the pool's tick spacing are all public immutables read
live off the vault and pool contracts themselves — no separate per-tier config beyond
which tier numbers to watch (`TIERS=1,2`).

**Tier 1** — DMOB/DMOA (demo tokens), fee/tickSpacing 3000/60, first band open at
ticks `[-600, 600]`, funded from the vault's own idle balances. Tier-1 risk params
are queued in `ParamsRegistry` and, like any parameter change, sit behind a 2-day
timelock before `execute()` activates them.

**Tier 2 is a real pair**: real testnet USDC (`0x534b2f...`) against DMOA, minted 1:1
by value to match the deployer's own real USDC — the first vault whose value isn't
entirely demo tokens. Its fee/tickSpacing (500/10) differ from tier 1's (3000/60)
since it's a different pair, priced differently. Pairing assets with different
decimals (USDC has 6, DMOA has 18) needs a decimal-adjusted initial pool price, not a
naive raw 1.0 — a raw price of 1.0 only means equal *value* when both assets share
decimals — so the pool is initialized at `sqrtPriceX96` derived from each token's own
decimals (whichever ends up as token0, decided only by address at deploy time),
verified afterward by reading the pool's real `slot0()` directly rather than assumed.

Each tier's vault card on `app.html` loads its ~15 reads sequentially rather than in
parallel across vaults, and caches per-token `symbol()` lookups (DMOA is shared by
both tiers) — the public Monad testnet RPC hard-429s under enough concurrent load
that loading every vault's reads in parallel at once made the page fail to load at
all, not just slowly.

The Aurora Intents integration (`integrations/aurora-intents/`) has real, fetched
Monad-side NEAR omft asset ids now (`GET /api/v1/supported_tokens`) — and that lookup
surfaced a real blocker: every Monad entry in Aurora's supported-token list encodes
chain id `143` (Monad **mainnet**), with no separate testnet entry. Aurora Intents
Connect has no route into Monad testnet, where the deployed vault above actually
lives. The contract-side support this integration needs (`depositFor`) is done and
tested; the cross-chain path itself has nothing to land on until either Aurora adds
testnet support or a vault exists on Monad mainnet. Separately, **AUSD is not the
same as Aurora** — a real mix-up worth recording since the names look similar: it
isn't in Aurora Intents' supported-assets catalog either.

## MetaMask Agent Wallet plugin

`integrations/metamask-agent-wallet/` adds `mm rangekeeper status` and `mm
rangekeeper deposit` to MetaMask's Agent Wallet CLI (`mm`). Every command routes
through Agent Wallet's own signing and policy; the plugin never handles a key.
`deposit` follows the documented quote-then-submit pattern — it prints a plan
(amount, asset, exact Pyth fee) and only signs anything once `--confirm` is passed.

Checked directly against Agent Wallet's own docs before writing any code (its plugin
guide, the real `ens` example plugin, and the `agent-wallet-plugin` authoring skill).
That check also confirmed **Monad Testnet (chainId 10143) is a preconfigured chain**
in Agent Wallet — not a "bring your own RPC" workaround.

Built, installed, and verified locally: `npm run build` produces a real
`oclif.manifest.json` listing exactly `rangekeeper:status` and `rangekeeper:deposit`;
`mm plugins install file:///...` installs it for real (a plain `$PWD`-based path
failed with a confusing npm `ENOENT` on Windows — needs an explicit `file:///C:/...`
URI, found live); `mm plugins` and `mm rangekeeper --help` both confirm it's
registered; running a command before `mm login` returns a clean host-level
`AUTH_FAILED` rather than a plugin crash, confirming the auth gate actually reaches
this plugin. See `integrations/metamask-agent-wallet/README.md` and its
`skills/rangekeeper/SKILL.md` for the full command reference.
