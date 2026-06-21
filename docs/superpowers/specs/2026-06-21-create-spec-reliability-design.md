# Create-Spec Reliability Improvements — Design

**Date:** 2026-06-21
**Status:** approved for planning
**Scope:** harden `/create-spec` so a generated spec is production-reliable, judged by what smart-router actually reads at runtime — not by similarity to a (possibly stale) upstream gold.

## Problem

`/eval-spec` grades a generated spec by comparing it to an existing upstream gold. That answers "can you reproduce a known answer," not "is this spec correct for a chain nobody has done yet" — and golds can be out of date. We want reliability measured against the **live chain and the router's own runtime behavior**.

Phase 8 (smart-router boot + probe) already catches everything that fails *loudly*: boot failures, failed verifications, parse-directive failures, methods that error when probed. The gap is the **silent** band — defects that boot clean and serve wrong. After tracing smart-router source, that band is small: most "wrong value" defects either self-heal or fail loud, and many spec fields the router never reads at all.

### What smart-router does with each field (the grounding)

Three buckets, from runtime tracing:

- **Self-healing / boot-verified — already covered, do not add checks:**
  `average_block_time` (router measures real cadence and overrides the spec value; logs `chainParser updated block time oldTime→newTime` at `base_chain_parser.go:68`; only hard-gates on `==0`), `chain-id` verification (provider startup fails loud on mismatch), pruning `latest_distance` (boot-verified loud), parse directives `GET_BLOCKNUM`/`GET_BLOCK_BY_NUM` (chain tracker executes them at boot, fails loud), empty `api_interface`/`api.name` (collection/api silently dropped but observable at boot).

- **Dead weight — router never reads, stop spending review effort:**
  `reliability_threshold`, `data_reliability_enabled`, `block_last_updated`, `min_stake_provider`, `providers_types`, `shares`, `contributor*`, `identity`.

- **Silent in production — the only place reliability work pays off:**
  finalization depth (`block_distance_for_finalized_data`), method-discovery completeness for high-risk method kinds, and QoS sync behavior (`allowed_block_lag_for_qos_sync`).

### Findings that shaped (and shrank) the scope

- **Omitted plain-read methods are harmless.** An undefined method is passed through to the upstream with defaults (`defaultApiContainer()`, `base_chain_parser.go:366-396`: CU=20, `deterministic=true`, `stateful=false`, `ParserArg=["latest"]`). So a forgotten ordinary read still works. Only methods whose *correct* config differs from those defaults are dangerous to omit — **writes** (need `stateful`), **archive** (need the extension), **subscriptions** (need ws). A write omitted (or present but not `stateful`) routes to **one** provider with **no retry** → silent dropped tx (`consumer_session_manager.go:1256`, `unified_relay_state_machine.go:357`).
- **The general "method omitted" case is already gated.** `methods-coverage-validator` (Phase 6) diffs the spec against `api-docs-researcher`'s discovered list and FAILs on unjustified `MISSING`. The residual hole is *under-discovery*: a method the researcher never found can't be flagged.
- **Stateful-by-name lint rejected.** The skill already assigns `stateful` by *effect*, with explicit warnings against the name trap (`spec-builder.md:60`, `phase3.2:202`: `eth_fillTransaction` looks like a tx but isn't). A name-match lint would be redundant and false-positive-prone.
- **Archive `cu_multiplier=0` guard rejected.** The skill always templates archive at 5 (or 1.5–2.0). It never emits 0, so guarding against 0 guards against an impossible output. Also, in smart-router (no provider payment) the *magnitude* of `cu_multiplier` is economically meaningless; archive only matters for **routing** deep queries to archive-capable upstreams and for **timeout** (`timeout_ms:0` → timeout computed from CU, `common.go:537`). Low priority for spec reliability.
- **Finalization fields disambiguated.** `block_distance_for_finalized_data` = finality depth (`finalized = latest − distance`, `constants.go:27-40`): drives cache TTL, finality labels, lag threshold, and is part of the fork-detection window. Too low → unfinalized blocks cached and served as final (reorg-prone), and nothing fails loud. `blocks_in_finalization_proof` is **not** dead (a prior trace got this wrong): it is summed with the distance to set the chain tracker's `blocksToSave` (fork-detection window) at `rpcsmartrouter.go:1629-1635`, logged as `blocksToSave` at `:1659`; sum `==0` fails tracker startup. Its window depth has no clean empirical oracle, so it stays a family-convention value — no new check.
- **QoS sync is observable, not silent.** `allowed_block_lag_for_qos_sync` sets when a provider is judged behind. Wrong value → good providers wrongly down-weighted. Visible via `QoS Sync report block_diff` (DEBUG, `qos_mutator_relay_success.go:79`) and metric `lava_rpc_optimizer_selection_score{score_type="sync"}`. Availability `<0.80` → normalized score `0` → dropped from selection (`weighted_selector.go:317`).

## Changes

Three concrete changes. Each is placed to reuse machinery that already exists.

### 1. Finality depth: docs → empirical → formula (mirror `average_block_time`)

**Owner:** `references/agents/chain-metadata-researcher.md`

Today finality comes from docs/L2Beat/Chainspect (`:39,47`) with a family-formula fallback (`:65-67`); there is no empirical step. `average_block_time` already uses a stronger pattern (`:51,191-198`): docs give the headline value, but **empirical measurement is a required check that beats any website and overrides weak doc sources** — there is no formula tier because block time is measured, not derived.

Apply the same pattern to `block_distance_for_finalized_data`, reusing the block-time probing machinery the agent already has:

1. **Docs / canonical registry** → headline finality depth.
2. **Empirical probe** (the new step): if the chain exposes a finality tag (`finalized`/`justified` block, or an instant-finality family), fetch `finalized` and `latest`, compute the gap. This is a **verifier and safety floor**: `block_distance_for_finalized_data ≥ observed gap`. Empirical may only push the value *up* (serving an unfinalized block as final is the dangerous direction); it never lowers below the measured gap.
3. **Family formula** (instant=1, PoS≈2 epochs) → last resort only when neither docs nor a finality tag exist.

Report the source used and the measured gap, same discipline as block time ("never copy without an empirical check").

### 2. Three-bucket discovery affirmation

**Owner:** `references/agents/api-docs-researcher.md` (enforcement already lives in `methods-coverage-validator`)

The agent already records `is_write` / `is_subscription` / `deterministic` per method (`:76-77,131`) and writes the full list to `/tmp/<chain>_methods.txt`. The only uncovered failure is **under-discovery** of a high-risk method kind — if it never finds a write/archive/subscription method, that method never enters the list, so Phase 6 can't flag it missing (`:34`: "the orchestrator cannot recover methods you didn't report").

Add three required affirmation lines to the agent's output contract, forcing it to actively confirm it looked for each high-risk bucket:

```
writes:        found [eth_sendRawTransaction, ...]  | N/A — chain has no tx submission
archive/trace: found [...]                          | N/A — no archival support
subscriptions: found [...]                          | N/A — no websocket
```

No new validator and no spec-builder gate: once these methods are in the list, the existing `methods-coverage-validator` enforces presence, and existing skill guidance handles their categorization. This change only guarantees they get *into* the list.

### 3. Per-upstream QoS table in the PR comment

**Owner:** `references/agents/smart-router-tester.md`

After the ~15-minute Phase 8 probe run, read the optimizer metrics and write a per-upstream QoS table into the PR comment — every probed node listed, not just survivors:

```
| node_url | availability | latency | sync | composite | |
|----------|-------------|---------|------|-----------|---|
| node-1   | 0.98        | 0.15s   | 0.99 | 0.94      | ✓ |
| node-2   | 0.62        | 1.2s    | 0.80 | 0.55      |   |
```

Source: `lava_rpc_optimizer_selection_score{score_type=...}` at `/metrics`. Mark a row with a green ✓ when **availability ≥ 0.80** (the selection floor — below it the node is dropped, `weighted_selector.go:317`). Pass signal: **at least one node ends ✓** proves the spec's sync/finality config lets the router keep a real provider in-sync. Showing all nodes (a fleet where 2 of 3 dropped is a yellow flag even if one survived) keeps the signal honest.

## Out of scope / deliberately rejected

- Stateful-by-name lint (already handled by effect-based assignment + `cu-semantic-validator` advisory).
- Archive `cu_multiplier ≥ 1` guard (skill never emits 0; magnitude is meaningless without payment).
- `blocks_in_finalization_proof` precise check (no empirical oracle; family-convention value; boot already gates the sum `==0`).
- `average_block_time` accuracy check (router self-heals and logs the correction).
- Live method-introspection diff (`rpc.discover`/reflection) — rejected as unreliable: optional on many nodes and node-dependent (pruned/namespace-limited nodes report different sets).
- Dead-weight fields — explicitly excluded from scoring.

## Verification

- Change 1: on a finality-tag chain (e.g. an Ethereum-family testnet), confirm the agent emits a measured `finalized−latest` gap and that the written `block_distance_for_finalized_data` is ≥ that gap.
- Change 2: run `api-docs-researcher` on a chain with writes + subscriptions; confirm the three affirmation lines appear and that an artificially omitted write is caught downstream by `methods-coverage-validator`.
- Change 3: run Phase 8 on a multi-upstream chain; confirm the PR comment contains the per-node table with at least one ✓ row.
