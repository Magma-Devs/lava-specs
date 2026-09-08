# Inheritance audit of every spec added 2026-07-08 → 2026-09-08

Triggered by TRAC (`trac.json`, added 2026-08-27): "this is an EVM chain, it
doesn't import ETH1, it's literally defining all of the ETH1 methods again."

The complaint is right about the duplication and wrong about the chain class,
and the difference matters for the fix.

## What TRAC actually is

NeuroWeb (OriginTrail Parachain) is a **Polkadot parachain with a Frontier EVM
pallet**, not an EVM chain. `trac.json` had two collections:

| collection | methods | what it is |
|---|---|---|
| `add_on: ""` | 102 | Substrate JSON-RPC (`chain_*`, `state_*`, `author_*`, `chainHead_v1_*`) — legitimate, kept |
| `add_on: "evm"` | 49 | 47 ETH1 methods retyped by hand + `eth_submitHashrate`/`eth_submitWork` |

So the Substrate half was never the problem. The EVM half was:

- **47 of 49 methods are ETH1's**, copied rather than inherited.
- **14 of those 47 had already drifted** from ETH1 — `eth_feeHistory`,
  `eth_chainId`, `eth_syncing`, `web3_clientVersion`, `web3_sha3` and 9 more
  differed in `block_parsing`, `compute_units`, or both.
- **7 ETH1 methods were simply missing** (`eth_getProof`,
  `eth_createAccessList`, `eth_sign`, `eth_signTransaction`, `rpc_modules`,
  `eth_getCompilers`, `eth_compileLLL`).
- The `evm` add-on also **hides the EVM surface behind an add-on request**. An
  EVM dapp pointing at a Lava endpoint does not know to ask for an `evm`
  add-on; on NeuroWeb the EVM RPC is served unconditionally on the same URL.

## The decision rule (this is what was missing)

`add_on` is part of the collection key, so **ETH1's `add_on: ""` collection can
never merge into a child's `add_on: "evm"` collection.** Choosing the add-on is
choosing permanent duplication. Which shape is correct is not a style question —
it is an empirical one, settled by one probe against the chain's public RPC:

```
curl -sX POST $RPC -d '{"jsonrpc":"2.0","method":"system_chain","params":[],"id":1}'
curl -sX POST $RPC -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}'
```

Probed 2026-09-08:

| chain | endpoint | `system_chain` | `eth_chainId` | verdict |
|---|---|---|---|---|
| TRAC | astrosat.origintrail.network | OriginTrail Parachain | `0x7fb` | one endpoint → **import ETH1** |
| HYDRATION | rpc.hydradx.cloud | Hydration | `0x3640e` | one endpoint → **import ETH1** |
| BITTENSOR | entrypoint-finney.opentensor.ai | Bittensor | `0x3c4` | one endpoint → **import ETH1** |
| LIT | rpc.litentry-parachain.litentry.io | Heima | `0x33c2d` | one endpoint → **import ETH1** |
| ACA | acala-rpc-0.aca-api.network | Acala | **`-32601`** | separate host → **add-on is correct, no change** |
| ACA (EVM) | eth-rpc-acala.aca-api.network | `-32601` | `0x313` | |

Acala routes EVM through a separate `eth-rpc-adapter` host. Its `evm` add-on is
structurally right and its duplication is forced by the merge rules, so it is
recorded in `spec-inheritance-exceptions.txt` rather than "fixed".

#### Is the base collection right if EVM is only *some* providers' capability?

This is the real objection to the change, because moving `eth_*` into the base
collection and pointing `chain-id` at `eth_chainId` means **a provider whose node
does not answer `eth_chainId` fails startup verification and can no longer serve
the chain at all** — not even its Substrate half. That is only acceptable if the
EVM surface is a property of the chain's node software rather than an operator
opt-in.

Probed across independent operators, not just the official endpoint:

| chain | operators probed | all serve `eth_chainId`? |
|---|---|---|
| TRAC | astrosat, parachain-rpc (2 distinct deployments) | yes |
| HYDRATION | rpc.hydradx.cloud, **Dwellir** | yes |
| BITTENSOR | Opentensor, **latent.to**, **OnFinality** | yes |
| LIT | litentry.io, heima.network | yes |

Ten endpoints, zero counterexamples — including three third-party infra
providers running stock node images. If the EVM RPC needed an opt-in flag, one
of them would have had it off.

The genuinely flag-gated surfaces behave exactly the other way on the *same*
endpoints: `debug_traceBlockByNumber`, `trace_filter` and `txpool_status` all
return `-32601` on all four. That is the line the repo's convention already
draws, and it holds:

> **unconditional surface → base collection; flag-gated surface → add-on.**

So `evm` was the wrong add-on to have. `debug`, `trace` and `txpool` are the
right ones, and they are what the import now supplies.

Substrate and EVM block height were also probed and are **equal** on all four
(delta 0), which is why the base `GET_BLOCKNUM` can stay `chain_getHeader`.

## What changed

### Restructured: 4 specs (7 indices)

TRAC, HYDRATION/HYDRATIONT, BITTENSOR/BITTENSORT, LIT/LITT:

1. `imports: ["ETH1"]`.
2. The `evm` collection folded into the base collection; every method ETH1
   already supplies (base **or** its `debug`/`trace`/`bundler` add-ons) dropped.
   Only genuinely chain-specific methods moved across —
   `eth_submitHashrate`, `eth_submitWork`, `eth_pendingTransactions`.
3. The base `chain-id` verification switched from the Substrate genesis hash to
   `eth_chainId` with the chain's own EVM id — matching MOONBEAM (`0x504`),
   MOONRIVER (`0x505`) and PEAQ (`0xd0a`). Verifications key on `name`, so a
   collection holds exactly one `chain-id`; leaving it as a genesis hash while
   inheriting ETH1 would have meant **silently inheriting ETH1's `0x1`**
   (MAG-3354).
4. Each testnet's `chain-id` hoisted to its EVM id (BITTENSORT `0x3b1` —
   verified live; LITT `0x7dd` — carried forward, endpoint unreachable;
   HYDRATIONT `0x3640e` — verified live, Hydration Paseo reuses the mainnet id).
   Without this the testnets would have inherited the new `eth_chainId` template
   while keeping a 32-byte genesis hash as the expected value, and could never
   have passed verification.
5. The `evm` collection deleted.

Result per spec, verified by resolving the full import closure before and after:

| index | enabled base methods | disabled (probed `-32601`) | chain-id | net served |
|---|---|---|---|---|
| TRAC | 151 | 7 | `0x7fb` | **+24** |
| HYDRATION / HYDRATIONT | 154 | 7 (+13 pre-existing substrate admin) | `0x3640e` | **+24** |
| BITTENSOR / BITTENSORT | 180 | 8 | `0x3c4` / `0x3b1` | **+19** |
| LIT / LITT | 161 | 7 | `0x33c2d` / `0x7dd` | **+24** |

**Nothing served was lost** (the one exception, `BITTENSOR.eth_sendTransaction`,
is a correction — see below). The gains are ETH1's `debug`, `trace` and `bundler`
add-on collections, which now attach automatically, plus `eth_subscribe` /
`eth_unsubscribe` SUBSCRIBE directives that land *alongside* the 12 Substrate
ones (those two tags key on `tag + api_name`, so nothing is displaced).

`GET_BLOCKNUM` still resolves to `chain_getHeader` and `GET_BLOCK_BY_NUM` to
`chain_getBlockHash` on all seven — `ParseDirective.Differeniator()` is the bare
function tag for everything except SUBSCRIBE/UNSUBSCRIBE, and the child's entry
wins over the parent's (`x/spec/types/combinable.go`).

### Cleaned: 14 dead-weight copies in 6 more specs

Methods a spec re-declared with definitions **byte-identical** to the parent it
already imports. Deleting them changes no behaviour:

| spec | removed |
|---|---|
| MOONBEAM | `eth_getProof`, `eth_createAccessList`, `eth_sign`, `eth_signTransaction` |
| PEAQ | `eth_getProof`, `eth_createAccessList`, `eth_sign`, `eth_signTransaction` |
| MOONRIVER | `debug_traceCall`, `trace_filter` |
| FLOW | `debug_traceCall` |
| FTM250 | `trace_filter` |
| SONIC | `trace_filter` |
| BCH | `getnetworkhashps` (from BTC) |

### The import is not free: 7–8 methods had to be disabled

Importing ETH1 brings its **whole** base collection, including methods a Frontier
parachain does not implement. The hand-rolled `evm` add-on had 47 of ETH1's 54
methods — the 7 it omitted were omitted *correctly*. A naive import silently
re-advertises them.

Every ETH1 base method was therefore probed against each chain's live endpoint
(and a second independent operator for Hydration). `-32601` on all four:

| method | TRAC | HYDRATION | BITTENSOR | LIT |
|---|---|---|---|---|
| `eth_getProof`, `eth_createAccessList`, `eth_sign`, `eth_signTransaction`, `rpc_modules`, `eth_getCompilers`, `eth_compileLLL` | ✗ | ✗ | ✗ | ✗ |
| `eth_sendTransaction` | ok | ok | **✗** | ok |

All are now declared `"enabled": false` in each base collection — the documented
positive-evidence disable, and exactly what MOONRIVER already does for four of
them. `BITTENSOR.eth_sendTransaction` was **enabled before this PR and is not
served**; disabling it is a correction, not a regression.

Net effect per chain: **+24 methods**, all of them in ETH1's `debug`, `trace` and
`bundler` add-on collections — which are opt-in per provider, so they cost a
Substrate-only operator nothing.

### One correction

`HYDRATION.eth_feeHistory` was **corrected** to `PARSE_BY_ARG ["1"]`: unlike
TRAC/BITTENSOR/LIT it had shipped a byte-identical copy of ETH1's wrong
`DEFAULT ["latest"]`, so it did not already have the right parsing.

## Findings NOT fixed here, and why

1. **`ethereum.json` parses `eth_feeHistory` wrongly.** The signature is
   `eth_feeHistory(blockCount, newestBlock, rewardPercentiles)` — the block
   parameter is `params[1]` — but ETH1 declares `DEFAULT ["latest"]`, so a
   historical fee-history query routes as a latest query and can land on a
   pruned node. TRAC/BITTENSOR/LIT already had the correct
   `PARSE_BY_ARG ["1"]`; those overrides are kept and ledgered. Fixing ETH1 is a
   one-line change with **64 importers**, so it belongs in its own PR, not
   bundled into a trust-repair change.

2. **HYPERLIQUID, TRX, VECHAIN declare 24–42 ETH1 methods without importing
   ETH1.** Unlike the Frontier parachains these are *partial* EVM surfaces
   (Tron's and VeChain's eth-compat layers implement a subset with differing
   semantics), so importing ETH1 would advertise methods the chains do not
   serve. Each needs a per-method probe before any change. HYPERLIQUID and TRX
   also predate this window (2025-09-18); VECHAIN is 2026-07-11.

3. **Enabled `debug_*`/`trace_*` overrides that differ from ETH1** — 3 each in
   FLOW, MOONRIVER, FTM250, 2 in SONIC, plus
   `/cosmos/mint/v1beta1/annual_provisions` in BABYLON. Inspected: these are
   real decisions, not copy-paste — `category.deterministic: true` where ETH1
   says false, `compute_units: 200` vs 100, and
   `debug_traceTransaction` parsed by `params[0]` (a tx hash) instead of ETH1's
   `DEFAULT ["latest"]`. Whether each is right needs per-chain evidence this
   audit did not gather, so they are flagged for review and deliberately left
   outside the guard.

4. **THORCHAIN declares 42 COSMOSSDK methods but imports only TENDERMINT.**
   Same shape as CANTO, one base up. Thorchain serves its own `/thorchain/*`
   REST surface alongside `/cosmos/*` paths, so whether the overlap is real
   coverage or retyping needs a probe against its public LCD.

5. **CANTO declares 30 ETHERMINT methods without importing ETHERMINT**, while
   its peers EVMOS, SEI and KAVA all import it. `canto.json` predates this
   window (2025-09-18) and Canto's Cosmos/EVM split needs its own probe, so it
   is flagged rather than changed.

6. **There is no shared Substrate base spec.** Ten pure-Substrate specs (AVT,
   BSX, ENJ, ENJIN, KUSAMA, KUSAMAASSETHUB, POLKADOT, POLKADOTASSETHUB,
   POLYMESH, XRT) each retype 115–143 Substrate methods with `imports: []`,
   because there is no `SUBSTRATE` analogue of `COSMOSSDK`/`TENDERMINT` to
   import. This is the same class of problem one level up and the largest
   remaining duplication in the repo.

## Audits that came back clean

- **chain-id inheritance.** No spec silently inherits ETH1's `0x1`. The
  AVAX/AVALANCHEC hits are false positives — their `chain-id` lives in the
  `/C/rpc` collection that providers actually serve.
- **`enabled: false` overrides.** All 71 apparent "drifted overrides" across
  ETHEREUMPOW, FLARE, FLOW, MONAD, MOONRIVER, OASIS, OPTM and SEI are deliberate
  positive-evidence disables. That pattern is working.
- **`GET_BLOCKNUM` presence.** Every chain spec resolves one; the seven without
  are base/library specs (IBC, COSMOSWASM, ETHERMINT, …) that are never served
  directly.
- **TRAC's `average_block_time`.** 48529 ms looked implausible for a parachain;
  measured over 1000 live blocks it is 45960 ms — within 6%, correct.

## Why it shipped, and what now stops it

Not skill drift — **the pipeline emitted both shapes on the same day**:

| date | spec | result |
|---|---|---|
| 2026-08-26 | BNC | `imports: ["ETH1"]` |
| 2026-08-26 | ACA, LIT | `imports: []` + `evm` add-on |
| 2026-08-27 | PEAQ, SDN | `imports: ["ETH1"]` |
| 2026-08-27 | **TRAC** | `imports: []` + `evm` add-on |

Same skill version, same chain class, opposite outputs. Three causes, all in the
skill:

1. **`upstream-spec-scout.md` forced a single-ecosystem pick.** Its
   classification table had an `EVM-Compatible → ETH1` row and a
   `Standalone → None` row whose example was *"Polkadot (no direct reuse)"* —
   and no row for a chain that is both. A parachain that describes itself as an
   appchain classified Standalone and got no imports; one that markets itself as
   an EVM L1 classified EVM-Compatible and got ETH1. The output tracked the
   chain's own marketing, not its RPC.
2. **`smart-router-tester.md` asserted a false generalisation:** *"Acala serves
   Substrate in the base collection and EVM in an `evm` add-on, on separate
   infrastructure … `lit.json` and `peaq.json` have the same shape."* Both named
   chains were wrong — peaq never had an `evm` add-on, and Heima's single url
   serves both surfaces. A run reading that line had written permission to treat
   the add-on as the parachain house style.
3. **`phase3.1-inheritance.md` said "*Consider* inheriting from `ETH1`"** and was
   silent on base-collection vs add-on placement, so nothing overruled 1 and 2.

Nothing in the pipeline probed the endpoint, so no step could catch it. Four
changes:

1. **`upstream-spec-scout.md`** replaces the one-row-per-chain table with
   `Substrate`, `Substrate + EVM (Frontier)` and `Substrate + detached EVM`
   rows, states that a chain can be in two rows at once, and requires the probe
   before classifying.
2. **`smart-router-tester.md`** now records ACA as the *only* disjoint add-on in
   the catalog, with the probe output, and says to decide disjoint-vs-extending
   by probing rather than from a list of chain names.
3. **`phase3.1-inheritance.md`** now carries the endpoint probe as a decision
   rule with a precedent table, the merge-key constraint that makes it binding,
   the re-probe-the-parent's-surface step, and the chain-id/testnet traps.
2. **`check_parent_duplication.sh`** (+ self-test, wired into `spec_guards.yml`
   as `parent-duplication`) fails a spec that retypes a base's surface without
   importing it, or re-declares an enabled method its parent already supplies.
   Base specs are derived by import fan-in (≥ 3), so a future `SUBSTRATE` base
   is covered the day it exists. Exceptions go in
   `spec-inheritance-exceptions.txt` with a reason.

## Family consistency after the fix

| family | agreement |
|---|---|
| substrate + evm (11) | 10 import ETH1; ACA is the ledgered exception |
| substrate, no evm (10) | all `imports: []` — consistent, but see finding 4 |
| evm (57) | 54 import ETH1; HYPERLIQUID, TRX, VECHAIN are finding 2 |
| cosmos (23) | 8 different import combinations — plausible per SDK version, unreviewed |

Whole-repo run of the new guard (270 indices): **5 findings — CANTO, THORCHAIN,
HYPERLIQUID, TRX, VECHAIN**, all of them items 2, 4 and 5 above, all
pre-existing, none in a file this PR touches.
