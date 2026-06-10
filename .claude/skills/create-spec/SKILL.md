---
name: create-spec
description: "Generate a single Lava chain spec JSON file at specs/testnet-2/specs/<chain>.json containing both mainnet and testnet entries under one proposal.specs[] array. Use when the user asks to add support for a new blockchain, create or build a chain spec, or onboard a chain to Lava. Runs a 12-phase pipeline with parallel research agents, formula-gated synthesis, autonomous jq validation, local provider boot + multi-node method probing, and worktree-isolated parallel /review-spec reviewers."
---

# Create Spec — Lava Chain Specification

This skill produces a single JSON file at `specs/testnet-2/specs/<chain>.json` that contains both mainnet and testnet spec entries under one `proposal.specs[]` array (matching the format of `specs/testnet-2/specs/iota.json`). The testnet entry imports the mainnet entry and overrides only the `chain-id` verification value.

The skill orchestrates a 12-phase pipeline. It does NOT generate documentation, governance proposals, or execute git operations. If the user asks for any of those, stop and confirm scope before continuing.

`build-spec` and `create-lava-spec` are NOT replaced by this skill — they remain on disk untouched.

## Model assignment (per-role)

This skill is cost-optimized as a **hybrid**: the orchestrator (you) inherits whatever model the session runs, while dispatched subagents carry an explicit `model:` per role. Every `Agent(...)` template below already includes the `model:` value to copy. Rationale and override paths:

| Role | Phase | `model:` | Why |
|---|---|---|---|
| Orchestrator (synthesis, gate judgment) | 4, 5, 10 | *(inherits session)* | Correctness-critical — run the session on **opus** (or **sonnet** if cost-bound) |
| Research agents | 3 | `sonnet` | Web search + extraction; token-heavy, so the cheaper tier matters most here |
| Static validators | 6 | `haiku` | Deterministic-leaning, several jq-backed. **Bump `cu-semantic` / `parse-directive` / `methods-coverage` to `sonnet`** if they emit false PASSes on complex chains |
| Reviewers (`/review-spec`) | 9, 11 | `sonnet` | Judgment-heavy safety net; **bump to `opus`** if reviews miss issues on hard chains |
| Fixers | 6, 10 | `sonnet` | Apply a given edit list — needs care but not deep reasoning |
| Provider boot + probe | 8, 10b | `sonnet` | Mostly bash/build/curl execution |

To run the whole skill on one tier, ignore the per-role values and set every dispatch's `model:` the same (or drop it to inherit). The `run_stats` report at Phase 12 prints which model(s) actually ran.

## Output target

- **Path:** `specs/testnet-2/specs/<chain>.json` (lowercase filename matching the mainnet `index` lowercased — e.g. `iota.json`, `polygon.json`)
- **Structure:** single file, `proposal.title` + `proposal.description` + `proposal.specs[]` (2 entries: mainnet + testnet) + `deposit: "10001000ulava"`
- **Reference:** `specs/testnet-2/specs/iota.json` is the canonical example

## Full-read enforcement (mandatory)

Each reference file under `references/` ends with a sentinel line of the form `END-OF-<NAME>-SENTINEL`. Before each phase transition you must have observed the sentinel of the file required by that phase.

To read a reference file fully:

1. Run `wc -l <path>` to get the total line count `N`.
2. Read the file in 500-line chunks using the Read tool's `offset` parameter (1, 501, 1001, ...) until you have covered all `N` lines.
3. The final chunk MUST contain the sentinel. If you have not seen it, you have not finished — continue reading from a higher offset.
4. Do NOT begin the next phase until you have observed the sentinel.

## Phase 1 — Pre-flight

**First action of the run — record the start time** so Phase 12 can report wall-clock elapsed and scope the token tally to this run only:

```bash
date +%s > /tmp/create_spec_run_start.epoch
cat /tmp/create_spec_run_start.epoch
```

Then check whether `specs/testnet-2/specs/<chain>.json` already exists, where `<chain>` is the lowercased mainnet index the user wants to add.

Run:

```bash
ls specs/testnet-2/specs/<chain>.json 2>/dev/null
```

- If the file exists, ask the user: "Use as base / adapt / scratch?" Do not overwrite without explicit confirmation.
- If it does not exist, proceed to Phase 2.

## Phase 2 — Gather inputs

Ask the user only for what they alone can decide. Do not guess defaults:

- **Chain name** (e.g., "Iota")
- **Mainnet spec index** (uppercase, 3–10 chars, e.g., `IOTA`)
- **Testnet spec index** (uppercase, e.g., `IOTAT` or `IOTAS`)
- **Docs URL** (optional — Phase 3 will pick one and report if missing)
- **Public RPC URLs** (optional — Phase 3 will pick 2-3 each for mainnet and testnet if missing)
- **Inheritance hint** (optional — e.g., "EVM-compatible, imports ETH1")

If the user is vague ("add Polygon"), ask. Don't proceed until you have at minimum the chain name, mainnet index, and testnet index.

## Phase 3 — Parallel research (5 background agents)

Before dispatching, read `references/phase1-research.md` end-to-end (full-read, observe `END-OF-PHASE1-SENTINEL`). It contains the blockchain-analysis framework, third-party-API decision tree, index-naming conventions, and API-discovery patterns that inform how to brief the research agents. Subagents will not read this file themselves — you (the orchestrator) extract the relevant context from it and weave it into each agent prompt's `{chain_name}`, `{docs_url}`, etc. substitutions.

Dispatch five research agents in parallel via a SINGLE message with five Agent tool calls. Each agent runs in the background (`run_in_background: true`) and uses `subagent_type: general-purpose`.

Read the five agent prompt files first (full-read with sentinel verification, where applicable):

- `.claude/skills/create-spec/references/agents/api-docs-researcher.md`
- `.claude/skills/create-spec/references/agents/chain-metadata-researcher.md` (observe `END-OF-AGENT-CHAIN-METADATA-SENTINEL`)
- `.claude/skills/create-spec/references/agents/upstream-spec-scout.md`
- `.claude/skills/create-spec/references/agents/plugin-researcher.md`
- `.claude/skills/create-spec/references/agents/archive-researcher.md` (observe `END-OF-ARCHIVE-RESEARCHER-SENTINEL`)

Substitute placeholders (`{chain_name}`, `{chain_index_lower}`, `{docs_url}`, `{mainnet_indices_or_known_parents}`, `{public_repo_path}`) with the values gathered in Phase 2 plus any heuristics. `{chain_index_lower}` is the mainnet index lowercased (e.g., `iota` for `IOTA`); it is passed to BOTH `api-docs-researcher` (which names `/tmp/<chain_index_lower>_methods.txt`) AND `upstream-spec-scout` (which names `/tmp/<chain_index_lower>_directives.txt` when a template is found). `{public_repo_path}` is empty unless the user has resolved a lava-specs clone. `{mainnet_rpc_url}` and `{testnet_rpc_url}` are the primary live RPC URLs gathered in Phase 2; pass them to `archive-researcher` for its Layer 2 live probe (empty string if a network has no public RPC). `{chain_family}` and `{api_interface}` are also gathered in Phase 2; pass them to `archive-researcher` so it picks the correct per-family probe recipe.

Dispatch all five in a single message:

```
Agent(description: "Research api-docs for {chain}", subagent_type: "general-purpose", model: "sonnet", run_in_background: true, prompt: <api-docs-researcher.md with placeholders substituted>)
Agent(description: "Research chain metadata for {chain}", subagent_type: "general-purpose", model: "sonnet", run_in_background: true, prompt: <chain-metadata-researcher.md with placeholders substituted>)
Agent(description: "Find upstream parent spec for {chain}", subagent_type: "general-purpose", model: "sonnet", run_in_background: true, prompt: <upstream-spec-scout.md with placeholders substituted>)
Agent(description: "Detect plugins/extensions for {chain}", subagent_type: "general-purpose", model: "sonnet", run_in_background: true, prompt: <plugin-researcher.md with placeholders substituted>)
Agent(description: "Research archive/prune for {chain}", subagent_type: "general-purpose", model: "sonnet", run_in_background: true, prompt: <archive-researcher.md with placeholders substituted>)
```

When all five agents complete (you will receive notifications), collect their reports.

**Before proceeding to Phase 4, print the archive-researcher's full report to the user verbatim — copy the entire block between `=== ARCHIVE RESEARCHER ===` and `END-OF-ARCHIVE-RESEARCHER-SENTINEL` into your response. Do NOT paraphrase, summarize, or condense any section.**

**If the archive-researcher's report is missing the `=== ARCHIVE RESEARCHER ===` start marker, missing the `END-OF-ARCHIVE-RESEARCHER-SENTINEL` end marker, or has no `SUMMARY: status:` line**, re-dispatch the archive-researcher with explicit instructions to emit the full output template (Sources, Doc-mined defaults, Live probe results, Recommendation, Conflicts, and SUMMARY) before returning. Do not proceed to Phase 4 with a malformed report.

**On `status: NEEDS_HUMAN_DECISION`**: STOP. Quote the `## Conflicts` section and any Recommendation rows marked `chain-discretion` from the report you just printed, and ask the user to make a call on each — specifically: (a) include or omit the `archive` extension on mainnet, (b) include or omit on testnet, (c) the `rule.block` value if mainnet uses archive, (d) the `pruning` verification `expected_value` if it isn't `*`. Record their decisions and use them as Phase-3 inputs when proceeding to Phase 4.

**On `status: OK`**: keep the `## Recommendation` block in working memory and consult it when constructing the spec in Phase 4 — specifically, it determines (a) whether the spec's mainnet entry includes an `archive` extension on the primary api_collection, (b) whether the testnet entry does, (c) the `rule.block` integer value on any archive extension, and (d) the `pruning` verification's `values[0].expected_value` (almost always `"*"`).

Then proceed to Phase 4.

If the upstream-spec-scout agent reports that no lava-specs clone was resolved, treat its output as empty (no parent-spec hints) and continue.

**Verify the scout's method-list file exists.** The api-docs-researcher is required to write `/tmp/<chain_index_lower>_methods.txt` (one method per line, no commentary) — this file is what downstream `/review-spec` reviewers diff against the spec via `compare_spec_methods.sh`. Confirm it before proceeding:

```bash
wc -l /tmp/<chain_index_lower>_methods.txt
```

The line count must match the unique-method count in the researcher's structured report. If the file is missing, partial, or has only a few lines despite the report claiming dozens of methods, re-dispatch the api-docs-researcher with explicit instructions to write the file before returning.

## Phase 4 — Synthesis (gated by phase-file reads)

Before constructing any spec JSON, you must observe sentinels for these reference files in this order:

1. `references/phase2-network-params.md` → observe `END-OF-PHASE2-SENTINEL`
2. `references/phase3.1-inheritance.md` → observe `END-OF-PHASE3.1-SENTINEL`
3. `references/phase3.2-api-methods-configuration.md` → observe `END-OF-PHASE3.2-SENTINEL`
4. `references/phase3.3-api-collections.md` → observe `END-OF-PHASE3.3-SENTINEL`
5. `references/phase3.4-parse-directives-and-extensions.md` → observe `END-OF-PHASE3.4-SENTINEL`
6. `references/appendix-reference-tables.md` → observe `END-OF-APPENDIX-SENTINEL`
7. `references/common-pitfalls.md` → observe `END-OF-PITFALLS-SENTINEL`

Then before writing any JSON, emit a **calculations table** to the user showing every derived network parameter and the math behind it:

| Parameter | Source | Formula | Computed value |
|---|---|---|---|
| `average_block_time` | (docs / empirical measurement — cite which) | — | (ms) |
| `block_distance_for_finalized_data` | (consensus type — PoW=6–12, BFT=1–3, instant=1) | — | (int) |
| `blocks_in_finalization_proof` | finality-typed | `3` if probabilistic finality (PoW / slow PoS, e.g. Ethereum, Arbitrum); `1` if fast/instant finality (BFT, Tendermint/Cosmos, Solana, BTC-style longest-chain-with-checkpoints, L2s that inherit instant settlement). **Fallback when finality model can't be confidently classified:** `max(ceil(1000 / average_block_time), 3)` (floors at 3 → conservative; never falls back to 1) | (int) |
| `allowed_block_lag_for_qos_sync` | derived | `max(ceil(10000 / average_block_time), 1)` | (int) |
| `reliability_threshold` | standard | `268435455` | `268435455` |
| `data_reliability_enabled` | standard | `true` | `true` |

**Block-time tie-breaker rule (C):** Determine `average_block_time` by this exact priority:

1. **If docs publish a single canonical value** (one number, not a range): **USE THE DOCS VALUE** unless empirical measurement disagrees by MORE than 20%. Drift up to 20% is normal RPC jitter and is NOT a reason to deviate. (For example, if empirical = 3800ms and docs = 4000ms, lock **4000** — the 5% drift is jitter.)
2. **If docs publish a range** (e.g., "X–Y ms"): use the **lower bound of the range** OR the empirical value, **whichever is lower**. Never round UP "for safety" or "conservatively" — `average_block_time` directly multiplies into `blocks_in_finalization_proof` and `allowed_block_lag_for_qos_sync` via the formulas above, and rounding up cascades into wrong downstream values. (For example, if empirical = 219ms and docs say 200–250ms, lock **200**, not 250.)
3. **If docs are silent**: use the empirical median directly.
4. **If empirical and a single docs value disagree by >20%**: ask the user which to trust — do not silently pick one.

After the user has had a chance to challenge the table, construct draft JSON applying these strict synthesis rules:

- **NEVER extract spec content from git history.** You (the orchestrator) MUST NOT run `git show <commit>:specs/...`, `git log -p -- specs/...`, `git restore --source=<commit> specs/...`, or any similar command to retrieve the contents of a spec that previously existed in this repo but is no longer in the working tree. The `upstream-spec-scout` agent is bound by the same rule (see `references/agents/upstream-spec-scout.md`). Two reasons: (1) **Evaluation bias** — when this skill is being evaluated, the "gold" spec being scored against is frequently the recently-deleted file one or two commits back; recovering it via git makes the candidate-vs-gold comparison circular and invalidates the score. (2) **Staleness** — a deleted spec was deleted for a reason, usually because it was wrong; recovering it bakes the defects back in. If the scout's report mentions "X previously existed in git history", treat that as a name-level note only — do NOT go retrieve the file yourself. Build from the chain's current docs + sibling-spec templates in the working tree (e.g., `sui.json` for IOTA).
- **REJECT all agent "trim", "scope", "exclude", or "narrow" recommendations.** Research agents (api-docs-researcher in particular) may suggest reducing the method set with framing like "scoping suggestions trim to ~50" or "consider excluding the foo_* family". You MUST ignore these suggestions. The full discovered method list is the input to synthesis. Apply only the explicit-omission rule below — never the agent's opinion.
- **Method-set input = UNION of api-docs-researcher AND upstream-spec-scout (A).** The synthesis input is the union of: (1) every method `api-docs-researcher` discovered from chain docs/WebSearch, AND (2) every method `upstream-spec-scout` found in any existing spec (deleted-from-branch, sister-ecosystem template like `sui.json` for IOTA, prior version in `specs/mainnet-1/`, or any matching upstream). If the scout found a method that the researcher didn't, **INCLUDE IT** — existing-spec evidence is higher quality than fresh web search. The only valid reason to omit a scout-found method is an empirical curl proving the method no longer exists on the chain (`-32601 method not found` against the public RPC). "Researcher didn't find it" is NOT a valid omission reason.
- **All methods from chain docs MUST appear in the spec.** Take the COMPLETE method list (union of researcher + scout) and include every method. The only acceptable reasons to omit are documented in the chain's API reference itself: explicitly marked deprecated, explicitly internal/admin-only, or explicitly platform-specific (e.g., GraphQL-only on a JSON-RPC spec). "The agent suggested trimming" is NOT a valid reason.
- **Subscription methods belong in MAIN, not in an add-on (B).** Methods with `category.subscription: true` (subscribe/unsubscribe pairs) live in the **same collection as the chain's core read API**, NOT in a separate `add_on: "indexer"` collection. The `indexer` add-on is for methods that require an external indexer service running (e.g., metrics aggregations like `iotax_getNetworkMetrics`, `iotax_getMoveCallMetrics`, address rollups, epoch rollups). Methods served by every regular full node — including dynamic-fields queries, owned-objects, query-events, query-transactions, and ALL subscriptions — belong in MAIN. Cross-check the scout's findings: if the scout's template spec has a method in MAIN, KEEP IT IN MAIN.
- **Parse-directive completeness for subscriptions (D).** For every API with `category.subscription: true`:
  - Subscribe variants (method name contains `ubscribe` but NOT `nsubscribe`) → MUST have a matching `parse_directive` entry with `function_tag: "SUBSCRIBE"` and `api_name: "<that method's name>"` in the same collection.
  - Unsubscribe variants (method name contains `nsubscribe`) → MUST have a matching `parse_directive` entry with `function_tag: "UNSUBSCRIBE"`, an explicit `function_template` (e.g., `"{\"jsonrpc\":\"2.0\",\"method\":\"<name>\",\"params\":[\"%s\"],\"id\":1}"`), and `api_name: "<that method's name>"`.
  - Without these parse_directives, the methods are listed but the relay layer cannot route them — they are effectively broken.
- **Parse-directives, extensions, and verifications follow the references — not the template (F).** The canonical structures (function tags, function_template shapes, result_parsing patterns, archive/pruning encoding) live in `references/phase3.4-parse-directives-and-extensions.md` and `references/appendix-reference-tables.md`. You already observed their sentinels in Phase 4 — use that content as the source of truth. A template spec (when `upstream-spec-scout` found one) is a **concrete syntax example** for chains in the same ecosystem — useful for copying the exact `function_template` arg shape for non-obvious cases (e.g., `params: [null, 1, false]` for `GET_EARLIEST_BLOCK` in Sui/IOTA). The reference dictates WHICH elements must exist; the template (if any) shows what they look like. Completeness is enforced by the Phase 6 gates, not by template diff.
- **Multi-collection splits.** Many chains DO have a legitimate add-on collection (e.g., IOTA's `iotax_*` address-metrics methods, EVM's `debug_*`/`trace_*` add-ons). Add an `add_on` collection ONLY when the methods require external infrastructure (indexer service, archive node, trace database). Default everything else to MAIN.
- **Every addon and extension has a matching `verifications` block.** An archive extension requires a `pruning` verification with `GET_EARLIEST_BLOCK`. An `add_on` collection requires its own verification (e.g., the indexer collection verifies via `iotax_getTotalTransactions` returning `*`).
- **SUBSCRIBE and UNSUBSCRIBE methods share the same `local` and `stateful` flags as each other** (typically both `local: false, stateful: 0, subscription: true`).
- If `imports` is set AND the child's `average_block_time` is materially faster than the parent's: **explicitly override** the inherited `archive.rule.block` and `pruning.latest_distance` in the child's main collection. The parent's values are calibrated for the parent's block rate — silently inheriting them produces a wrong pruning window for the child. (For example, a chain with 1s blocks importing `ETH1` would silently inherit ETH1's archive/pruning sizing that was calibrated for 12s blocks — the resulting archive window is ~12× too short.)
- `stateful: 1` ONLY for state-modifying broadcasts. Read-only helpers like `eth_call`, `eth_estimateGas`, `eth_fillTransaction`, `debug_traceCall` are `stateful: 0` even when they take tx-shaped args.
- Every API with `category.hanging_api: true` has an explicit `timeout_ms` set. The `hanging_api` flag alone only adds `2 * average_block_time` to the relay timeout — insufficient on fast chains.

### Per-method `block_parsing` inference (H)

For every method, infer `block_parsing` from the method's argument signature — do NOT default every method to `DEFAULT` / `["latest"]`. Wrong `block_parsing` produces wrong CU values via rule E below, AND breaks block-aware routing at relay time. Map each method through this table:

| Argument shape | `parser_func` | `parser_arg` |
|---|---|---|
| Method takes a positional state-selecting identifier (block number, ledger index, checkpoint sequence, object ID, tx hash) — i.e., the arg's value selects WHICH historical state is queried | `PARSE_BY_ARG` | `["<position-index>"]` (e.g., `["0"]` for the first param) |
| Method takes a request object with a nested state-selecting field | `PARSE_CANONICAL` | dotted path to that field (e.g., `["params", "ledger_index"]`) |
| Method takes NO state-selecting arg AND returns current-state data (latest balance, current fee, latest block) | `DEFAULT` | `["latest"]` |
| Method takes a tag like `"latest" \| "earliest" \| "pending"` or a block-or-hash union | `PARSE_DICTIONARY_OR_ORDERED` | the position index or path |
| Method takes NO args and returns static / computational data (genesis info, network constants, node identity, chain ID) | `EMPTY` | `[""]` |

Cross-check against `references/phase3.2-api-methods-configuration.md` (you already observed `END-OF-PHASE3.2-SENTINEL` in this phase) for the canonical mapping per parser_func.

### CU value rules (E) — mechanical from block_parsing + category

Use this table to assign `compute_units`. The table is exhaustive — do NOT apply "generic CU bands" from memory; map every method through these rules:

| Method shape | CU |
|---|---|
| `block_parsing.parser_func == "EMPTY"` (static, no chain state) | 10 |
| `block_parsing.parser_func == "DEFAULT"` with `parser_arg == ["latest"]` (simple read of current state) | 10 |
| `block_parsing.parser_func == "PARSE_BY_ARG"` OR `"PARSE_CANONICAL"` (state-by-id query — fetch object/tx/checkpoint by hash or sequence number) | 20 |
| `block_parsing.parser_func == "PARSE_DICTIONARY_OR_ORDERED"` (block-or-tag query, e.g., EVM `eth_getBlockByNumber`) | 20 |
| `category.subscription: true` AND method name is a **subscribe** variant (name contains `ubscribe` but NOT `nsubscribe`) | 1000 |
| `category.subscription: true` AND method name is an **unsubscribe** variant (name contains `nsubscribe`) | 10 |
| `category.stateful: 1` (broadcast/state-modifying) | 10 |
| Heavy compute (full-scan, `getLogs`-style) when explicitly classified as such by api-docs-researcher | 60–100 |
| Traces / debug_* | 100–200 |

If a method falls outside this table, default to 10 and flag to the user. **`unsubscribe` is not a subscribe — never give it CU=1000.** **State-by-id reads are not simple reads — never give them CU=10.**

### Before writing JSON (G): mandatory pre-write summary, refuse-to-write gate

Print to the user this exact summary BEFORE calling Write on the spec file:

```
Methods discovered by api-docs-researcher: <N_researcher>
Methods found by upstream-spec-scout:      <N_scout>
Union (deduplicated):                       <N_union>
Methods included in spec:                   <M> (split: main=<X>, <addon1>=<Y>, ...)
```

**Refuse-to-write gate.** If `M < N_union`, you MUST list every omitted method with an explicit reason from the allowed set: `deprecated` / `admin-only` / `platform-specific (e.g., GraphQL-only)` / `empirically absent (curl returned -32601 against <node_url>)`. If any omission lacks a documented reason from this set, ADD THE METHOD BACK and re-print the summary before proceeding. Do NOT call the Write tool until either `M == N_union` OR every gap is justified with one of the four allowed reasons.

After the summary prints and any gaps are reconciled, validate one more shape detail before Write:

- For every method with `category.subscription: true`, confirm a matching `parse_directive` exists in the same collection (rule D). If any subscription method lacks its parse_directive, ADD IT before writing.

Then call Write.

## Phase 5 — Inheritance audit (CONDITIONAL)

Skip this phase entirely if the mainnet draft's `imports` array is empty.

If `imports != []`, perform the two-step audit from `references/phase3.1-inheritance.md` (you should have already observed its sentinel in Phase 4):

**Step 1 — Parent's APIs vs chain's documented APIs.** Use `jq` to extract parent method names and `comm -23` to diff:

```bash
PARENT="ETH1"  # or whatever the import is
PARENT_FILE="specs/mainnet-1/specs/${PARENT,,}.json"
[ -f "$PARENT_FILE" ] || PARENT_FILE="specs/testnet-2/specs/${PARENT,,}.json"
jq -r '.proposal.specs[] | select(.index == "'$PARENT'") | .api_collections[].apis[].name' "$PARENT_FILE" | sort -u > /tmp/parent_methods.txt
# Compare against chain-docs methods (from api-docs-researcher report); write its method list to /tmp/chain_methods.txt
comm -23 /tmp/parent_methods.txt /tmp/chain_methods.txt > /tmp/ghosts.txt
```

For each "ghost" method (in parent but not chain docs), run an empirical curl probe against the chain's public RPC:

```bash
curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"<ghost>","params":[],"id":1}' \
  <chain_rpc_url>
```

If the response is `-32601 method not found` → the method is a ghost, disable or remove it in the child spec. If the response is anything else → method exists; retain inheritance.

**Step 2 — Chain-specific additions.** Diff chain docs against parent:

```bash
comm -13 /tmp/parent_methods.txt /tmp/chain_methods.txt > /tmp/additions.txt
```

Every method in `/tmp/additions.txt` MUST appear in the child spec. Commonly missed categories: `admin_*`, `txpool_*`, `*_Sync` variants.

Output the diff results and probe results verbatim to the user before proceeding.

## Phase 6 — Static validation gates (parallel dispatch + single-pass fixer)

This phase runs 9 deterministic static-check gates in parallel and, on any failure, dispatches a single fixer subagent to apply edits before proceeding to Phase 7. Phase 9's parallel reviewers + Phase 11's final reviewer catch any residual issues from the fixer.

### Pre-flight checklist (informational; the gates below are authoritative)

Walk this checklist to confirm the orchestrator's working state. The first four bullets surface as gate failures below; the last two are NOT covered by any validator and must be hand-checked here:

- `index` is uppercase, unique, matches the chain
- `name`, `enabled`, `min_stake_provider`, `shares` present at top level of each spec entry
- `chain-id` `expected_value` obtained from a **live curl** against the mainnet RPC (not converted from a docs decimal)
- Testnet entry's `chain-id` `expected_value` obtained from a live curl against the testnet RPC
- Every API with `category.hanging_api: true` has an explicit `timeout_ms` (no validator covers this — confirm by running `jq -r '.proposal.specs[].api_collections[].apis[] | select(.category.hanging_api == true and (.timeout_ms // null) == null) | .name' specs/testnet-2/specs/<chain>.json` and confirming the output is empty)
- `category.stateful` is set only on broadcast / state-modifying methods (read methods must have `stateful: 0` or unset; no validator enforces direction — spot-check the spec's stateful methods against the chain's docs)

For the chain-id curl step, run this for both mainnet and testnet:

```bash
curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
  <mainnet_rpc_url>
# For non-EVM chains, use the chain's equivalent (e.g., iota_getChainIdentifier).
```

Capture the returned hex value VERBATIM into the spec's `verifications[].values[0].expected_value`. Show the response to the user.

### Archive ↔ pruning ↔ GET_EARLIEST_BLOCK triplet (inline pre-flight)

For each spec entry: `archive` extension, `pruning` verification, and `GET_EARLIEST_BLOCK` parse_directive are an indivisible triplet — all present or all absent. The canonical structure of each lives in `references/phase3.4-parse-directives-and-extensions.md`.

```bash
CAND=specs/testnet-2/specs/<chain>.json
jq '.proposal.specs[] | {
  index,
  archive_ext:        ([.api_collections[].extensions[]?.name] | contains(["archive"])),
  pruning_ver:        ([.api_collections[].verifications[]?.name] | contains(["pruning"])),
  earliest_directive: ([.api_collections[].parse_directives[]?.function_tag] | contains(["GET_EARLIEST_BLOCK"]))
}' "$CAND"
```

For each entry, the three booleans must be all `true` or all `false`. Any mixed row → STOP, fix by reading `references/phase3.4-...md` and adding the missing element(s).

### Parallel static gates dispatch

Read each validator agent prompt fully (full-read with sentinel verification) before dispatch:

- `.claude/skills/create-spec/references/agents/methods-coverage-validator.md` (observe `END-OF-METHODS-COVERAGE-VALIDATOR-SENTINEL`)
- `.claude/skills/create-spec/references/agents/parse-directive-validator.md` (observe `END-OF-PARSE-DIRECTIVE-VALIDATOR-SENTINEL`)
- `.claude/skills/create-spec/references/agents/chain-metadata-validator.md` (observe `END-OF-CHAIN-METADATA-VALIDATOR-SENTINEL`)
- `.claude/skills/create-spec/references/agents/verifications-validator.md` (observe `END-OF-VERIFICATIONS-VALIDATOR-SENTINEL`)
- `.claude/skills/create-spec/references/agents/extensions-validator.md` (observe `END-OF-EXTENSIONS-VALIDATOR-SENTINEL`)
- `.claude/skills/create-spec/references/agents/cu-semantic-validator.md` (observe `END-OF-CU-SEMANTIC-VALIDATOR-SENTINEL`)
- `.claude/skills/create-spec/references/agents/pruning-validator.md` (observe `END-OF-PRUNING-VALIDATOR-SENTINEL`)
- `.claude/skills/create-spec/references/agents/enabled-validator.md` (observe `END-OF-ENABLED-VALIDATOR-SENTINEL`)
- `.claude/skills/create-spec/references/agents/method-schema-validator.md` (observe `END-OF-METHOD-SCHEMA-VALIDATOR-SENTINEL`)

Gather inputs:
- `<spec_path>` — `specs/testnet-2/specs/<chain>.json`
- `<chain>` — lowercased chain name (filename stem)
- `<INDEX>` — spec index UPPERCASE
- `<api_interface>` — from the spec's primary `api_collections[].collection_data.api_interface`
- `<chain_family>` — from `upstream-spec-scout`'s ecosystem classification (`evm`, `solana`, `cosmos`, or other)
- `<mainnet_rpc_url>` — public mainnet RPC URL (empty if none; parse-directive Layer 3 will skip)
- `<has_archive>` — `true` if any collection has an `archive` extension, else `false`
- `<has_websocket>` — `true` if the chain has SUBSCRIBE/UNSUBSCRIBE directives, else `false`
- `<methods_file>` — `/tmp/<chain_index_lower>_methods.txt`
- `<retention_blocks>` — integer block count from archive-researcher's `retention_blocks` output, or the literal `unknown`. Passed to `pruning-validator`.
- `<research_unsupported>` — distilled list of methods research explicitly flagged unsupported/deprecated/`-32601` (from api-docs-researcher / plugin-researcher reports). May be empty. Passed to `enabled-validator`.

**Dispatch all 9 in a single message, each with `subagent_type: general-purpose`, `run_in_background: true`, NO `isolation`.** Validators run on `haiku` by default (deterministic-leaning, several jq-backed); the three semantic gates — `cu-semantic`, `parse-directive`, `methods-coverage` — are marked `sonnet` because they involve judgment. Downgrade those three to `haiku` for max savings, or upgrade the rest to `sonnet` if Phase 6 lets defects through:

```
Agent(description: "Gate: methods coverage", subagent_type: "general-purpose", model: "sonnet", run_in_background: true, prompt: <methods-coverage-validator.md with placeholders substituted>)
Agent(description: "Gate: parse directives", subagent_type: "general-purpose", model: "sonnet", run_in_background: true, prompt: <parse-directive-validator.md with placeholders substituted>)
Agent(description: "Gate: chain metadata", subagent_type: "general-purpose", model: "haiku", run_in_background: true, prompt: <chain-metadata-validator.md with placeholders substituted>)
Agent(description: "Gate: verifications", subagent_type: "general-purpose", model: "haiku", run_in_background: true, prompt: <verifications-validator.md with placeholders substituted>)
Agent(description: "Gate: extensions", subagent_type: "general-purpose", model: "haiku", run_in_background: true, prompt: <extensions-validator.md with placeholders substituted>)
Agent(description: "Gate: cu semantic", subagent_type: "general-purpose", model: "sonnet", run_in_background: true, prompt: <cu-semantic-validator.md with placeholders substituted>)
Agent(description: "Gate: pruning", subagent_type: "general-purpose", model: "haiku", run_in_background: true, prompt: <pruning-validator.md with placeholders substituted>)
Agent(description: "Gate: enabled", subagent_type: "general-purpose", model: "haiku", run_in_background: true, prompt: <enabled-validator.md with placeholders substituted>)
Agent(description: "Gate: method schema", subagent_type: "general-purpose", model: "haiku", run_in_background: true, prompt: <method-schema-validator.md with placeholders substituted>)
```

### Aggregate + single-pass fixer

Wait for all 9 subagents to return. Parse each one's last `RESULT: PASS | FAIL` line.

**Severity routing.** Three of the nine gates emit ADVISORY findings in addition to their `RESULT` line:
- `cu-semantic` — its Layer-2 ADVISORY rows (out-of-band CU). These DO feed the fixer as suggested CU adjustments.
- `enabled` — its WATCH-LIST rows. These do NOT feed the fixer (never auto-disable — free-tier caveat). Print them to the user and carry them into Phase 8 as a probe watch-list.
- `pruning` — when it prints `INFO: retention unknown`, treat as PASS (no fix); print the INFO to the user.

A gate's `RESULT: FAIL` (cu-semantic Layer-0 subscription-CU violation or Layer-1 anomaly, pruning >3× off, or any existing hard gate) routes to the fixer as a must-fix. The `enabled` gate's `RESULT` is always PASS.

**If all 9 RESULTS are PASS**: print a single-line summary to the user (`Phase 6: all 9 gates PASS`) and proceed to Phase 7 (still printing any advisory cu-semantic / enabled-watch-list rows).

**If any RESULT is FAIL**:

1. Print to the user the aggregated report — one section per failed gate, with the `=== GATE: <name> ===` block from that subagent's response.
2. Dispatch one `general-purpose` fixer subagent (`model: "sonnet"`) with the deduplicated FAIL list. Prompt:

   > You are fixing a Lava blockchain spec. Read `specs/testnet-2/specs/<chain>.json` and the deduplicated FAIL list below from Phase 6's parallel-gate run. Apply EVERY listed fix in one pass. Do not touch any field not mentioned in the FAIL list. Do not refactor, reformat, or improve adjacent fields.
   >
   > [paste deduplicated FAIL list with the per-gate sections from the parallel-gate reports]
   >
   > In addition to the FAIL list, the following are ADVISORY CU suggestions from the cu-semantic gate — apply them ONLY if they are clearly correct (a method's CU obviously outside its semantic band); skip any you are unsure about:
   > [paste cu-semantic Layer-2 ADVISORY rows, or "none"]
   >
   > Return a markdown summary of every change in the format:
   > `- <gate>:<row> — <one-sentence description of fix>`

3. After the fixer returns, validate JSON again:

   ```bash
   jq . specs/testnet-2/specs/<chain>.json > /dev/null
   echo "jq exit: $?"
   ```

   If exit non-zero, present the snapshot path, the `jq` error, and the fixer's diff to the user. STOP.

4. Do NOT re-run the validators — Phase 9's parallel reviewers and Phase 11's final reviewer catch any residual issues. Proceed to Phase 7.

## Phase 7 — Write & autonomous jq validation

Write the single file `specs/testnet-2/specs/<chain>.json` using the Write tool. The file structure must match `specs/testnet-2/specs/iota.json`:

```json
{
  "proposal": {
    "title": "Add Specs: <CHAIN>",
    "description": "<one-sentence description>",
    "specs": [
      { "index": "<CHAIN>", "name": "<chain> mainnet", "imports": [], ... },
      { "index": "<CHAIN_T>", "name": "<chain> testnet",
        "imports": ["<CHAIN>"],
        "api_collections": [{ ..., "apis": [], "verifications": [{ "name": "chain-id", "values": [{ "expected_value": "<testnet_hex>" }] }] }] }
    ]
  },
  "deposit": "10001000ulava"
}
```

Then run `jq` autonomously and report the result:

```bash
jq . specs/testnet-2/specs/<chain>.json > /dev/null
echo "jq exit: $?"
```

If exit is non-zero, capture the error excerpt:

```bash
jq . specs/testnet-2/specs/<chain>.json 2>&1 | head -n 20
```

Fix the JSON and re-run until exit 0. Do not proceed to Phase 8 until `jq` exits 0.

## Phase 8 — Local provider boot + multi-node method probe (delegated subagent)

This phase is delegated to a single `general-purpose` subagent so the orchestrator's context does not have to absorb 5–15 minutes of build/boot/probe output. You (the orchestrator) do NOT execute the boot script, write the provider config, or run probes yourself — you only dispatch and collect the result.

**Inputs to gather before dispatch** (from earlier phases — do NOT re-research):
- `<chain>` — lowercased chain name (filename stem, e.g., `iota`)
- `<INDEX>` — spec index UPPERCASE (e.g., `IOTA`)
- `<INTERFACE>` — `jsonrpc` | `rest` | `grpc` | `tendermintrpc` (the spec's `api_collections[].collection_data.api_interface`)
- `<NODE_URL_1>` (required), `<NODE_URL_2>`, `<NODE_URL_3>` (optional) — 1–3 public node URLs (https://… or wss://…) — from Phase 2 or chain-metadata-researcher. At least one is required to boot.
- `<WS_URL>` (optional) — separate WebSocket URL if not already in the URL list
- `<EXTRA_INTERFACES>` (optional) — additional `(INTERFACE, urls)` blocks for multi-interface chains (Cosmos)

**Boot is mandatory whenever at least one node URL is available.** Boot and probe with however many URLs you have (1, 2, or 3) — the boot itself catches spec-level defects (e.g. a result_parsing bug that blocks provider startup) that the static gates cannot see, so a single URL is worth booting. The orchestrator must not invent URLs.

If ZERO node URLs are available, do NOT silently skip: **STOP and ask the user to supply at least one node URL** before proceeding. Only skip Phase 8 with explicit user consent; if the user consents to skipping, note it in the Phase 12 checklist.

**Read the subagent prompt fully** before dispatch:
- `.claude/skills/create-spec/references/agents/local-provider-tester.md` (observe `END-OF-LOCAL-PROVIDER-TESTER-SENTINEL`)

**Dispatch ONE Agent subagent** with `subagent_type: general-purpose` (no `isolation` parameter — the subagent operates on the live working tree, since the candidate spec is uncommitted). Pass the prompt with all placeholders substituted. Use the Bash tool's `run_in_background` semantics inside the subagent — but the subagent itself runs in the foreground from your point of view (you wait for its single return).

```
Agent(description: "Boot local provider + probe methods for <chain>",
      subagent_type: "general-purpose",
      model: "sonnet",
      prompt: <local-provider-tester.md with placeholders substituted>)
```

When the subagent returns, it reports a short summary (counts including `LOG_WARN` + FAIL/TIMEOUT method names + any methods downgraded to WARN by the probe-window log scan + teardown status) and the path to `specs/docs/<chain>/METHOD_PROBE_REPORT.md`. Read the report from disk if you need detail — do not ask the subagent to echo it back. Carry the log-scan WARNs into the Phase 9 reviewers and the Phase 10 fix list, the same as FAIL methods.

If the subagent reports `SMOKE: BOOT_FAILED` or otherwise indicates the provider could not boot, present the error to the user and STOP. Do not proceed to Phase 9.

If the subagent reports clean teardown and a populated report, proceed to Phase 9.

## Phase 9 — Parallel reviewers (3 fresh subagents, immediate-rename for collision)

**Do NOT use `isolation: "worktree"`.** Worktrees are created via `git worktree add`, which checks out HEAD — the last committed state. Since this skill never commits, the new candidate spec written by Phase 7 is uncommitted and would NOT be visible inside a worktree. A reviewer in a worktree would review the previously-committed (stale) spec, not the candidate. This produces phantom CRITICAL findings with line references outside the real file. Anchoring isolation is achieved by fresh-subagent-context alone, not by filesystem separation.

**Before dispatching:** clear any prior parallel-review report files so the reviewers start clean:

```bash
mkdir -p specs/docs/<chain>
rm -f specs/docs/<chain>/SPEC_REVIEW_GAPS.md
rm -f specs/docs/<chain>/SPEC_REVIEW_GAPS_parallel_*.md
```

Dispatch THREE Agent subagents in parallel via a SINGLE message, each with `subagent_type: general-purpose`, `model: "sonnet"` (bump to `opus` if reviews miss issues on hard chains), and NO `isolation` parameter. Each subagent receives an `N` value (1, 2, or 3) so it knows which numbered output file to write. The prompt for reviewer N:

> You are reviewing a Lava blockchain spec. Your reviewer index is **N** (used in the output filename below).
>
> Run the `/review-spec` skill on `specs/testnet-2/specs/<chain>.json`. Pass through `$ARGUMENTS[1]` (API docs path, may be empty) and `$ARGUMENTS[2]` (credentials path, may be empty).
>
> Before running `/review-spec`, read `specs/docs/<chain>/METHOD_PROBE_REPORT.md` if it exists and incorporate the probe findings into your review (especially any FAIL or WARN classifications).
>
> `/review-spec` writes its report to the hard-coded path `specs/docs/<chain>/SPEC_REVIEW_GAPS.md`. **As the LAST step of your work — immediately after `/review-spec` returns** — rename that file to a unique numbered path so the other parallel reviewers do not clobber it:
>
> ```bash
> mv -n specs/docs/<chain>/SPEC_REVIEW_GAPS.md specs/docs/<chain>/SPEC_REVIEW_GAPS_parallel_N.md
> ```
>
> Use `mv -n` (no clobber) — if the destination already exists, the move fails rather than overwriting another reviewer's work. After the `mv`, verify it succeeded:
>
> ```bash
> test -f specs/docs/<chain>/SPEC_REVIEW_GAPS_parallel_N.md && echo "RENAMED_OK" || echo "RENAMED_FAIL"
> ```
>
> If the rename failed (destination already existed OR source didn't exist because another reviewer's parallel write clobbered yours), retry your `/review-spec` invocation once. Then attempt the rename again.
>
> Return:
> 1. The FULL contents of `specs/docs/<chain>/SPEC_REVIEW_GAPS_parallel_N.md` as the body of your response.
> 2. On the LAST line of your response, print exactly: `TALLY: CRITICAL=<X> MEDIUM=<Y> MINOR=<Z>` with integer counts.
>
> Do not print anything after the TALLY line.

After all three subagents return, in the primary working tree:

1. Parse each subagent's TALLY line. If any TALLY is missing or unparseable, abort and report which reviewer.
2. Verify all three files exist:
   ```bash
   ls -la specs/docs/<chain>/SPEC_REVIEW_GAPS_parallel_{1,2,3}.md
   ```
   If any are missing, the race-condition rename failed for that reviewer. Re-dispatch JUST the missing reviewer index and wait for it to complete (sequential at this point — collision risk is gone because only one reviewer is running).
3. The reports are now on disk at their numbered paths; no further extraction needed.

**Sanity check after collection:** if any reviewer reports CRITICAL findings whose `evidence_line_number` exceeds the actual line count of `specs/testnet-2/specs/<chain>.json`, that reviewer reviewed stale state — likely because the candidate file was modified after the reviewer started. Note the discrepancy to the user and either re-dispatch that one reviewer, or treat its findings as advisory rather than authoritative. Verify with:

```bash
wc -l specs/testnet-2/specs/<chain>.json
```

## Phase 10 — Synthesize gaps + single fix pass

Read all three parallel-reviewer reports. Build a deduplicated list of CRITICAL + MEDIUM gaps, keyed by `(gap_title, evidence_line_number)`. Drop MINOR gaps (they are out of scope for the automated fix pass).

Snapshot the spec before fixing:

```bash
cp specs/testnet-2/specs/<chain>.json /tmp/spec_<chain>_pre_fix.json
```

Dispatch one `general-purpose` Agent subagent (`model: "sonnet"`, no worktree needed — main filesystem) with this prompt:

> You are fixing a Lava blockchain spec. Read `specs/testnet-2/specs/<chain>.json` and the deduplicated gap list below. Apply EVERY listed CRITICAL and MEDIUM fix in one pass. Do not touch any field not mentioned in the gap list. Do not refactor, reformat, or improve adjacent fields.
>
> [paste deduplicated gap list with file:line citations and recommended values]
>
> Return a markdown summary of every change in the format:
> `- <file>:<line> — <one-sentence description> (gap: <severity>, "<gap title>")`

After the fixer returns, validate JSON again:

```bash
jq . specs/testnet-2/specs/<chain>.json > /dev/null
echo "jq exit: $?"
```

If exit non-zero: outcome = `BROKEN_AFTER_FIX`. Present the snapshot path (`/tmp/spec_<chain>_pre_fix.json`), the `jq` error, and the fixer's diff to the user. STOP. Do not proceed to Phase 10b.

## Phase 10b — Smoke regression test (delegated subagent)

Same delegation pattern as Phase 8 — a single `general-purpose` subagent re-boots the local provider against the FIXED spec on disk and re-probes a deterministic minimal set to detect regressions. The orchestrator does NOT execute the boot script or compare classifications inline.

Skip this phase entirely only if Phase 8 was skipped (i.e. the user explicitly consented to skipping when zero node URLs were available).

**Read the subagent prompt fully** before dispatch:
- `.claude/skills/create-spec/references/agents/local-provider-smoke-tester.md` (observe `END-OF-LOCAL-PROVIDER-SMOKE-TESTER-SENTINEL`)

**Dispatch ONE Agent subagent** with `subagent_type: general-purpose` and no `isolation`. Substitute the same `<chain>` / `<INDEX>` / `<INTERFACE>` / node URLs used in Phase 8, and pass the Phase 8 report path (`specs/docs/<chain>/METHOD_PROBE_REPORT.md`) plus the deduplicated Phase 10 fix list (so the smoke tester can suggest a plausible culprit on regression).

```
Agent(description: "Smoke re-test fixed spec for <chain>",
      subagent_type: "general-purpose",
      model: "sonnet",
      prompt: <local-provider-smoke-tester.md with placeholders substituted>)
```

When the subagent returns, expect one of:
- `SMOKE: OK` → proceed to Phase 11.
- `SMOKE: REGRESSION` → present the 7-row probe table and the suspected-culprit note to the user. STOP. Do NOT proceed to Phase 11.
- `SMOKE: BOOT_FAILED` → present the log excerpt. STOP. Do NOT proceed to Phase 11.

## Phase 11 — Final reviewer (clean context)

**Do NOT use `isolation: "worktree"`** — same reason as Phase 9. The candidate spec is uncommitted, so a worktree reviewer would see stale HEAD state. Fresh-subagent-context alone provides the anchoring isolation we need.

Before invoking the final reviewer, archive prior reports so the reviewer's `/review-spec` skill (Phase 1 of which scans `specs/docs/<CHAIN_NAME>/`) does not pick them up as anchoring. Also remove any stale `SPEC_REVIEW_GAPS.md` (without the `_parallel_N` suffix) that might be lingering:

```bash
mkdir -p specs/docs/<chain>/_archive
mv specs/docs/<chain>/SPEC_REVIEW_GAPS_parallel_*.md specs/docs/<chain>/_archive/ 2>/dev/null || true
mv specs/docs/<chain>/SPEC_REVIEW_FIXES_*.md specs/docs/<chain>/_archive/ 2>/dev/null || true
rm -f specs/docs/<chain>/SPEC_REVIEW_GAPS.md
```

Dispatch ONE Agent subagent with `subagent_type: general-purpose`, `model: "sonnet"` (bump to `opus` if the final pass misses issues), and no `isolation` parameter. The prompt:

> You are reviewing a Lava blockchain spec — final pass after fixes were applied.
>
> Run the `/review-spec` skill on `specs/testnet-2/specs/<chain>.json`. Pass through `$ARGUMENTS[1]` and `$ARGUMENTS[2]`.
>
> Before running `/review-spec`, read `specs/docs/<chain>/METHOD_PROBE_REPORT.md` if it exists.
>
> `/review-spec` writes its report to `specs/docs/<chain>/SPEC_REVIEW_GAPS.md`. After it returns, rename to a final-pass-specific path:
>
> ```bash
> mv specs/docs/<chain>/SPEC_REVIEW_GAPS.md specs/docs/<chain>/SPEC_REVIEW_GAPS_final.md
> ```
>
> Return:
> 1. The FULL contents of `specs/docs/<chain>/SPEC_REVIEW_GAPS_final.md` as the body of your response.
> 2. On the LAST line of your response, print exactly: `TALLY: CRITICAL=<X> MEDIUM=<Y> MINOR=<Z>` with integer counts.

**Sanity check (same as Phase 9):** if the reviewer reports CRITICAL findings whose `evidence_line_number` exceeds the actual line count of `specs/testnet-2/specs/<chain>.json`, the reviewer reviewed stale state. Re-dispatch once.

Outcomes:
- TALLY shows `CRITICAL=0 MEDIUM=0` → **APPROVED**. Proceed to Phase 12.
- TALLY shows remaining CRITICAL or MEDIUM gaps → **CHANGES REQUESTED**. Present the report to the user. STOP — do not loop. (Avoids the `/review-and-fix-spec` "max-loops-exit-without-converging" failure mode.) Skip Phase 12.

## Phase 12 — Final summary checklist (printed to user; no auto-action)

Print the checklist below to the user verbatim, with each item annotated:

- `✓` — verified by this run; cite the phase that produced the evidence
- `~` — partially verified; one-line note on what's not covered
- `☐` — user to handle manually (out of skill scope; surfaced as a reminder)

If a phase was skipped (e.g., Phase 8 skipped because user didn't supply node URLs), downgrade the corresponding items from `✓`/`~` to `☐` with a "(phase N skipped)" note.

```text
#### File Validation
- ✓ JSON syntax valid                                    (Phase 7 ran `jq` autonomously)
- ✓ All required fields present                          (Phase 6 completeness checklist)
- ✓ No duplicate API names within any collection         (Phase 6)
- ✓ Proper indentation/formatting                        (jq-formatted output)

#### Configuration Verification
- ✓ Network parameters calculated per formulas           (Phase 4 calculations table)
- ~ All APIs tested and working                          (Phase 8 probe — see specs/docs/<chain>/METHOD_PROBE_REPORT.md; stateful methods skipped)
- ~ Block parsing validated for each API                 (Phase 8 existence-tested; full parse validation requires production traffic)
- ✓ Verifications pass on live nodes                     (Phase 6 chain-id curl + Phase 8 multi-node probe)
- ☐ Compute units benchmarked under expected load        (user to measure)
- ☐ Economic parameters reasonable (min_stake_provider, shares)  (user judgment)

#### Documentation (out of skill scope — manual reminder)
- ☐ SPEC_IMPLEMENTATION.md created
- ☐ API_REFERENCE.md created
- ☐ TESTING_GUIDE.md created
- ☐ QUICK_START.md created

#### Testnet vs Mainnet
- ✓ Mainnet spec complete                                (Phase 7 wrote both entries to single file)
- ✓ Testnet spec inherits correctly                      (single-file pattern; Phase 11 reviewer confirmed)
- ✓ Chain IDs verified for mainnet AND testnet           (Phase 6 dual curl + Phase 8 probe)
- ~ Both tested on respective networks                   (Phase 8 probed all node URLs provided per variant)

#### Governance Prep (out of skill scope — manual reminder)
- ☐ Proposal JSON formatted correctly                    (the file produced has the proposal wrapper; user verifies title/description)
- ☐ Proposal description written
- ☐ Deposit amount confirmed                             (default "10001000ulava" written; user confirms)
- ☐ Community feedback gathered (if applicable)
```

After printing the checklist, emit the **run-stats report** so the user sees wall-clock time and real token consumption for this run. Read the run-start epoch captured in Phase 1 and pass it to `scripts/run_stats.sh`, which parses the actual `usage` blocks from this session's transcript plus every subagent transcript (NOT an estimate) and scopes the tally to entries at/after the start epoch:

```bash
START=$(cat /tmp/create_spec_run_start.epoch)
.claude/skills/create-spec/scripts/run_stats.sh "$START"
```

Print the script's output verbatim to the user. Elapsed is computed from the first→last transcript timestamp in the run window (one server clock), so it does not depend on the machine's wall-clock at run end. If the start-epoch file is missing (e.g. Phase 1 marker was lost), run `scripts/run_stats.sh 0` instead — a `0` threshold covers the whole session transcript, so the token totals stay correct but elapsed will span the entire conversation rather than just this run; note that caveat to the user.

After printing, terminate the skill. The user takes it from here (manual git operations, governance flow if applicable).

## Out of scope

- Writing to `specs/mainnet-1/specs/` or `specs/testnet-1/specs/` — testnet-2 only
- Creating `specs/docs/<chain>/` documentation files beyond the probe and review reports the skill emits during its own run
- Creating governance proposal JSONs or `PROPOSAL_DESCRIPTION.md`
- Any git operations: `git add`, `git commit`, `git push`, `git checkout`, `glab mr create`. User handles all git manually.

If the user asks for any of these, surface the limitation and confirm scope before continuing.
