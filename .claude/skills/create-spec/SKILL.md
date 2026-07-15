---
name: create-spec
description: "Use when the user asks to add support for a new blockchain, create or build a Lava chain spec, or onboard a chain to Lava."
---

# Create Spec — Lava Chain Specification

This skill produces a single JSON file at `<chain>.json` that contains both mainnet and testnet spec entries under one `proposal.specs[]` array (matching the format of `iota.json`). The testnet entry imports the mainnet entry and overrides only the `chain-id` verification value.

The skill orchestrates a 12-phase pipeline. It does NOT generate documentation, governance proposals, or execute git operations. If the user asks for any of those, stop and confirm scope before continuing.

`build-spec` and `create-lava-spec` are NOT replaced by this skill — they remain on disk untouched.

## Model assignment (per-role)

This skill is cost-optimized as a **hybrid**: the orchestrator (you) is now a thin conductor — it gathers inputs, dispatches subagents, and routes their verdicts, but does NOT synthesize or hold the spec body — so it can run on a cheap tier. The correctness-critical work lives in the `spec-builder` subagent. Every `Agent(...)` template below already includes the `model:` value to copy. Rationale and override paths:

| Role | Phase | `model:` | Why |
|---|---|---|---|
| Orchestrator (routing, gate judgment) | all | *(inherits session)* | Thin conductor — holds pointers + verdicts, not artifacts. Can run on **sonnet** (or **haiku** for cheap runs); the expensive correctness work is isolated in spec-builder |
| **Spec-builder (synthesis + inheritance + write)** | 4–5 | `opus` | The one correctness-critical role — derives params, applies the method-union/CU/parse rules, writes the spec. Run it at the top tier; bump to **opus** even when the session is cheaper |
| Research agents | 3 | `sonnet` | Web search + extraction; token-heavy, so the cheaper tier matters most here |
| Static validators | 6 | `haiku` | Deterministic-leaning, several jq-backed. **Bump `cu-semantic` / `parse-directive` / `methods-coverage` to `sonnet`** if they emit false PASSes on complex chains |
| Reviewers (`/review-spec`) | 9, 11 | `sonnet` | Judgment-heavy safety net; **bump to `opus`** if reviews miss issues on hard chains |
| Fixers | 6, 10 | `sonnet` | Apply a given edit list — needs care but not deep reasoning |
| Smart-router boot + probe | 8, 10b | `sonnet` | Mostly docker/curl execution |

To run the whole skill on one tier, ignore the per-role values and set every dispatch's `model:` the same (or drop it to inherit). The `run_stats` report at Phase 12 prints which model(s) actually ran.

## Context discipline (orchestrator) — read first, applies to every phase

Your (the orchestrator's) context is the single most expensive resource in this skill: it persists across all 12 phases and is re-sent every turn, so anything you pull into it is paid for dozens of times over. A subagent's context, by contrast, dies when it returns. So **keep large/transient artifacts OUT of your context — push the work into subagents and hold only pointers + short verdicts.** Rules:

- **Return contract.** Every subagent you dispatch returns at most a short verdict block + a file path — never pasted file contents or long logs. When you need detail, read the file from disk on demand with a *targeted* read (`jq`, `sed -n 'A,Bp'`, `grep`), never a whole-file slurp. Tell each subagent this explicitly if its prompt doesn't already.
- **The spec body stays on disk.** After Phase 7 writes `<chain>.json`, hold its **path**, not its body. Do NOT `cat`/`Read` the whole file or print line-numbered dumps of it into your context. Inspect specific fields with `jq`; route any step that needs to read/edit the full spec (validation, probe, fix) through a subagent that reads from disk and returns a short result.
- **Never read smart-router source.** Debugging a boot/probe failure by reading the router's routing/parser/validation code is a permanent context leak. That troubleshooting belongs entirely inside the Phase 8 subagent (which reads that source in its disposable context and returns a one-line diagnosis). If a boot fails and you need more, re-dispatch a subagent — do not read router source yourself.
- **Subagents read their own reference guides.** Where a subagent needs a `references/*.md` guide, pass it the guide **path** and let it read it, rather than full-reading the guide into your context to brief it. In particular the `spec-builder` subagent reads all the synthesis guides (`phase2`, `phase3.1–3.4`, `appendix`, `pitfalls`) itself — you no longer read them. Read into your own context only what your own routing decisions genuinely need.
- **Terse, not silent.** Emit one concise status line per phase plus every decision/auto-decision (those feed the PR body and are the user's audit surface) — but skip prose recaps, re-explanations, and "Now I'll… / Let me check…" narration. The full transcript remains for audit; you're cutting output tokens, not transparency.

## Output target

- **Path:** `<chain>.json` (lowercase filename matching the mainnet `index` lowercased — e.g. `iota.json`, `polygon.json`)
- **Structure:** single file, `proposal.title` + `proposal.description` + `proposal.specs[]` (2 entries: mainnet + testnet) + `deposit: "10000000ulava"`
- **Reference:** `iota.json` is the canonical example

## Full-read enforcement (mandatory)

Each reference file under `references/` ends with a sentinel line of the form `END-OF-<NAME>-SENTINEL`. Before each phase transition you must have observed the sentinel of the file required by that phase.

To read a reference file fully:

1. Run `wc -l <path>` to get the total line count `N`.
2. Read the file in 500-line chunks using the Read tool's `offset` parameter (1, 501, 1001, ...) until you have covered all `N` lines.
3. The final chunk MUST contain the sentinel. If you have not seen it, you have not finished — continue reading from a higher offset.
4. Do NOT begin the next phase until you have observed the sentinel.

## Resumable entry points (CI pipeline only)

When invoked by `spec_pipeline.yml`, the orchestrator prompt may say **"Start at
Phase N"** (N ∈ {8,9,10,11}) with a `PR_NUMBER` and pre-resolved endpoint lists. In
that mode you SKIP Phases 1-7 and reconstruct context from the committed
`<chain>.json` + prior PR comments. Read the full contract before doing anything else:

- `.claude/skills/create-spec/references/phase-entrypoints.md` (observe `END-OF-PHASE-ENTRYPOINTS-SENTINEL`)

The full-read sentinel enforcement below applies only to the reference files for the
phases you will actually run (Phase N..end); you need not observe sentinels for the
skipped earlier phases. A normal interactive run (no "Start at Phase N") is unaffected
and runs Phases 1-12 linearly as documented.

## Phase 1 — Pre-flight

**First action of the run — record the start time** so Phase 12 can report wall-clock elapsed and scope the token tally to this run only:

```bash
date +%s > /tmp/create_spec_run_start.epoch
cat /tmp/create_spec_run_start.epoch
```

Then check whether `<chain>.json` already exists, where `<chain>` is the lowercased mainnet index the user wants to add.

Run:

```bash
ls <chain>.json 2>/dev/null
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

## Phase 3 — Parallel research (5 foreground Agent calls)

Before dispatching, read `references/phase1-research.md` end-to-end (full-read, observe `END-OF-PHASE1-SENTINEL`). It contains the blockchain-analysis framework, third-party-API decision tree, index-naming conventions, and API-discovery patterns that inform how to brief the research agents. Subagents will not read this file themselves — you (the orchestrator) extract the relevant context from it and weave it into each agent prompt's `{chain_name}`, `{docs_url}`, etc. substitutions.

Dispatch five research agents in parallel via a SINGLE message with five Agent tool calls. Each uses `subagent_type: general-purpose`. Dispatch them in the **foreground** (do NOT set `run_in_background`) — the five calls still run concurrently, but the tool-use keeps your turn open until all five return.

**CI foreground rule (mandatory).** In the unattended CI runner there is no interactive event loop: ending a turn with background agents still pending terminates the job and can report success with no spec produced. **Never set `run_in_background`, never call `ScheduleWakeup`, and never end your turn while subagents are still running.** When you have nothing to do but wait, you are waiting, not done.

**Red flag:** "Background agents plus `ScheduleWakeup` saves budget" is wrong for this skill. It loses the unattended run. Use foreground Agent calls and wait for their returns.

Read the five agent prompt files first (full-read with sentinel verification, where applicable):

- `.claude/skills/create-spec/references/agents/api-docs-researcher.md`
- `.claude/skills/create-spec/references/agents/chain-metadata-researcher.md` (observe `END-OF-AGENT-CHAIN-METADATA-SENTINEL`)
- `.claude/skills/create-spec/references/agents/upstream-spec-scout.md`
- `.claude/skills/create-spec/references/agents/plugin-researcher.md`
- `.claude/skills/create-spec/references/agents/archive-researcher.md` (observe `END-OF-ARCHIVE-RESEARCHER-SENTINEL`)

Substitute placeholders (`{chain_name}`, `{chain_index_lower}`, `{docs_url}`, `{mainnet_indices_or_known_parents}`, `{public_repo_path}`) with the values gathered in Phase 2 plus any heuristics. `{chain_index_lower}` is the mainnet index lowercased (e.g., `iota` for `IOTA`); it is passed to BOTH `api-docs-researcher` (which names `/tmp/<chain_index_lower>_methods.txt`) AND `upstream-spec-scout` (which names `/tmp/<chain_index_lower>_directives.txt` when a template is found). `{public_repo_path}` is empty unless the user has resolved a lava-specs clone. `{mainnet_rpc_url}` and `{testnet_rpc_url}` are the primary live RPC URLs gathered in Phase 2; pass them to `archive-researcher` for its Layer 2 live probe (empty string if a network has no public RPC). `{chain_family}` and `{api_interface}` are also gathered in Phase 2; pass them to `archive-researcher` so it picks the correct per-family probe recipe.

Dispatch all five in a single message:

```
Agent(description: "Research api-docs for {chain}", subagent_type: "general-purpose", model: "sonnet", prompt: <api-docs-researcher.md with placeholders substituted>)
Agent(description: "Research chain metadata for {chain}", subagent_type: "general-purpose", model: "sonnet", prompt: <chain-metadata-researcher.md with placeholders substituted>)
Agent(description: "Find upstream parent spec for {chain}", subagent_type: "general-purpose", model: "sonnet", prompt: <upstream-spec-scout.md with placeholders substituted>)
Agent(description: "Detect plugins/extensions for {chain}", subagent_type: "general-purpose", model: "sonnet", prompt: <plugin-researcher.md with placeholders substituted>)
Agent(description: "Research archive/prune for {chain}", subagent_type: "general-purpose", model: "sonnet", prompt: <archive-researcher.md with placeholders substituted>)
```

When all five agents return (the foreground dispatch blocks your turn until they do), collect their reports and **write a consolidated research brief to `/tmp/<chain_index_lower>_research_brief.md`** — this is the file the Phase 4 `spec-builder` subagent reads, so it must be self-contained. From the four non-archive reports, distill what synthesis needs: the method union with per-method source tags (researcher / scout / both), network params (including the resolved `average_block_time`), inheritance/template hints, and the plugin/addon list. Do NOT retain all five full reports in your own context — the brief on disk plus the `/tmp/<chain_index_lower>_methods.txt` and `_directives.txt` files are the handoff. (The archive report is the one exception — it must still be printed verbatim per the requirement immediately below, and its resolved decisions are passed to spec-builder as explicit inputs.)

**Before proceeding to Phase 4, print the archive-researcher's full report to the user verbatim — copy the entire block between `=== ARCHIVE RESEARCHER ===` and `END-OF-ARCHIVE-RESEARCHER-SENTINEL` into your response. Do NOT paraphrase, summarize, or condense any section.**

**If the archive-researcher's report is missing the `=== ARCHIVE RESEARCHER ===` start marker, missing the `END-OF-ARCHIVE-RESEARCHER-SENTINEL` end marker, or has no `SUMMARY: status:` line**, re-dispatch the archive-researcher with explicit instructions to emit the full output template (Sources, Doc-mined defaults, Live probe results, Recommendation, Conflicts, and SUMMARY) before returning. Do not proceed to Phase 4 with a malformed report.

**On `status: NEEDS_HUMAN_DECISION`**: STOP. Quote the `## Conflicts` section and any Recommendation rows marked `chain-discretion` from the report you just printed, and ask the user to make a call on each — specifically: (a) include or omit the `archive` extension on mainnet, (b) include or omit on testnet, (c) the `rule.block` value if mainnet uses archive, (d) the `pruning` verification `expected_value` (a base-10 integer such as `"1"`, or omit it with `latest_distance` set; never `*`). Record their decisions and use them as Phase-3 inputs when proceeding to Phase 4.

**On `status: OK`**: keep the `## Recommendation` block in working memory and consult it when constructing the spec in Phase 4 — specifically, it determines (a) whether the spec's mainnet entry includes an `archive` extension on the primary api_collection, (b) whether the testnet entry does, (c) the `rule.block` integer value on any archive extension, and (d) the `pruning` verification's archive-tier `expected_value` — the value on the `extension: "archive"` entry (e.g. `values[1]`, NOT `values[0]`, which holds `latest_distance`); a base-10 integer for non-EVM (commonly `"1"`, archive from block 1; never `"*"` — the router parses it as an integer and would exclude the archive provider at boot), or `"0x0"` for the EVM gold (see ETH1); alternatively omit `expected_value` and rely on `latest_distance`.

Then proceed to Phase 4.

If the upstream-spec-scout agent reports that no lava-specs clone was resolved, treat its output as empty (no parent-spec hints) and continue.

**Verify the scout's method-list file exists.** The api-docs-researcher is required to write `/tmp/<chain_index_lower>_methods.txt` (one method per line, no commentary) — this file is what downstream `/review-spec` reviewers diff against the spec via `compare_spec_methods.sh`. Confirm it before proceeding:

```bash
wc -l /tmp/<chain_index_lower>_methods.txt
```

The line count must match the unique-method count in the researcher's structured report. If the file is missing, partial, or has only a few lines despite the report claiming dozens of methods, re-dispatch the api-docs-researcher with explicit instructions to write the file before returning.

## Phase 4 — Synthesis (delegated to spec-builder subagent)

Synthesis — deriving network params, applying the method-union + CU + `block_parsing` rules, the refuse-to-write gate, the inheritance audit, and writing `<chain>.json` — is delegated to the `spec-builder` subagent so the reference guides and the spec body never enter your context. You do three things: resolve the block-time tie-breaker, dispatch spec-builder, and surface what it returns.

**Block-time tie-breaker (resolve BEFORE dispatch).** Determine `average_block_time` by this priority and pass the single resolved value to spec-builder:

1. **Single canonical docs value** → USE IT unless empirical disagrees by >20% (drift ≤20% is RPC jitter; e.g. empirical 3800ms vs docs 4000ms → lock 4000).
2. **Docs range** → lower bound OR empirical, whichever is lower. Never round up — it cascades into `blocks_in_finalization_proof` and `allowed_block_lag_for_qos_sync`.
3. **Docs silent** → empirical median.
4. **>20% disagreement** → ask the user which to trust; in unattended/CI runs, default to the docs value and record the conflict.

**Read the subagent prompt fully** before dispatch:
- `.claude/skills/create-spec/references/agents/spec-builder.md` (observe `END-OF-SPEC-BUILDER-SENTINEL`)

**Dispatch ONE Agent subagent** with `subagent_type: general-purpose`, `model: "opus"` (the one correctness-critical role), no `isolation`. Pass: chain name + mainnet/testnet indices; the research-brief path (`/tmp/<chain_index_lower>_research_brief.md` from Phase 3); the `/tmp/<chain_index_lower>_methods.txt` + `_directives.txt` paths; the resolved `average_block_time` ms value; the archive decisions resolved in Phase 3 (include/omit mainnet, include/omit testnet, `rule.block`, pruning `expected_value`); the mainnet/testnet RPC URLs; and `chain_family` + `api_interface`.

```
Agent(description: "Synthesize + write spec for <chain>",
      subagent_type: "general-purpose",
      model: "opus",
      prompt: <spec-builder.md with placeholders substituted>)
```

When it returns, it gives a compact summary: the calc table, the pre-write counts, the omission ledger, the watch-list, the inheritance-disable ledger, the path, and `jq: valid`. **Print the calc table and the pre-write summary + omission ledger to the user** (audit surface). Read `<chain>.json` only with targeted `jq` if you need to verify a specific field — never slurp the whole file. If it returns `SPEC: BLOCKED`, surface the reason and STOP.

## Phase 5 — Inheritance audit (folded into spec-builder)

The inheritance audit — parent-vs-chain ghost diff, the positive-evidence disable rule, the justification ledger, and chain-specific additions — is performed by the `spec-builder` subagent as Step 5 of Phase 4. There is nothing to run here separately: confirm the returned `inheritance:` line (`no imports` / `disabled: …` / `all retained`) is consistent with the chain's `imports` array, and carry any watch-list methods into Phase 8 and the Phase 10 fix list.

**Disabled-API Justifications ledger (durable audit trail — a PR comment, not a file).** `spec-builder` returns its inheritance-disable rows to you (the orchestrator) — one positive-evidence row per `enabled: false` entry: `| name | evidence-type (docs-explicit / client-source) | source URL | one-line quote |`. Record these as a **PR comment titled "Disabled-API Justifications"** (create it, or update it if one already exists this run). Do **NOT** write them to a file under `docs/`: `docs/` is gitignored ("transient run outputs, never committed"), so a file there never persists to the branch and a later fresh-runner review would spuriously re-flag every disable as a missing justification — recording the ledger as a PR comment is what makes it durable. In an interactive run (no PR yet), print the ledger to the user instead — it is an audit surface that feeds the PR body when the PR is opened. The Phase-10 fixer appends any new disables to the same ledger, and Phase 11 verifies every `enabled: false` API against it.

## Phase 6 — Static validation gates (parallel dispatch + single-pass fixer)

This phase runs 9 deterministic static-check gates in parallel and, on any failure, dispatches a single fixer subagent to apply edits before proceeding to Phase 7. Phase 9's parallel reviewers + Phase 11's final reviewer catch any residual issues from the fixer.

### Pre-flight checklist (informational; the gates below are authoritative)

Walk this checklist to confirm the orchestrator's working state. The first four bullets surface as gate failures below; the last two are NOT covered by any validator and must be hand-checked here:

- `index` is uppercase, unique, matches the chain
- `name`, `enabled`, `min_stake_provider`, `shares` present at top level of each spec entry
- `chain-id` `expected_value` obtained from a **live curl** against the mainnet RPC (not converted from a docs decimal)
- Testnet entry's `chain-id` `expected_value` obtained from a live curl against the testnet RPC
- Every API with `category.hanging_api: true` has an explicit `timeout_ms` (no validator covers this — confirm by running `jq -r '.proposal.specs[].api_collections[].apis[] | select(.category.hanging_api == true and (.timeout_ms // null) == null) | .name' <chain>.json` and confirming the output is empty)
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
CAND=<chain>.json
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
- `<spec_path>` — `<chain>.json`
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

**Dispatch all 9 in a single message, each with `subagent_type: general-purpose`, in the foreground (do NOT set `run_in_background`), NO `isolation`.** Validators run on `haiku` by default (deterministic-leaning, several jq-backed); the three semantic gates — `cu-semantic`, `parse-directive`, `methods-coverage` — are marked `sonnet` because they involve judgment. Downgrade those three to `haiku` for max savings, or upgrade the rest to `sonnet` if Phase 6 lets defects through:

```
Agent(description: "Gate: methods coverage", subagent_type: "general-purpose", model: "sonnet", prompt: <methods-coverage-validator.md with placeholders substituted>)
Agent(description: "Gate: parse directives", subagent_type: "general-purpose", model: "sonnet", prompt: <parse-directive-validator.md with placeholders substituted>)
Agent(description: "Gate: chain metadata", subagent_type: "general-purpose", model: "haiku", prompt: <chain-metadata-validator.md with placeholders substituted>)
Agent(description: "Gate: verifications", subagent_type: "general-purpose", model: "haiku", prompt: <verifications-validator.md with placeholders substituted>)
Agent(description: "Gate: extensions", subagent_type: "general-purpose", model: "haiku", prompt: <extensions-validator.md with placeholders substituted>)
Agent(description: "Gate: cu semantic", subagent_type: "general-purpose", model: "sonnet", prompt: <cu-semantic-validator.md with placeholders substituted>)
Agent(description: "Gate: pruning", subagent_type: "general-purpose", model: "haiku", prompt: <pruning-validator.md with placeholders substituted>)
Agent(description: "Gate: enabled", subagent_type: "general-purpose", model: "haiku", prompt: <enabled-validator.md with placeholders substituted>)
Agent(description: "Gate: method schema", subagent_type: "general-purpose", model: "haiku", prompt: <method-schema-validator.md with placeholders substituted>)
```

### Aggregate + single-pass fixer

Wait for all 9 subagents to return. Parse each one's last `RESULT: PASS | FAIL` line.

**Severity routing.** Three of the nine gates emit ADVISORY findings in addition to their `RESULT` line:
- `cu-semantic` — its Layer-1 ADVISORY rows (out-of-band CU). These DO feed the fixer as suggested CU adjustments.
- `enabled` — its WATCH-LIST rows. These do NOT feed the fixer (never auto-disable — free-tier caveat). Print them to the user and carry them into Phase 8 as a probe watch-list.
- `pruning` — when it prints `INFO: retention unknown`, treat as PASS (no fix); print the INFO to the user.

A gate's `RESULT: FAIL` (cu-semantic Layer-0 subscription-CU violation, pruning >3× off, or any existing hard gate) routes to the fixer as a must-fix. The `enabled` gate's `RESULT` is always PASS.

**If all 9 RESULTS are PASS**: print a single-line summary to the user (`Phase 6: all 9 gates PASS`) and proceed to Phase 7 (still printing any advisory cu-semantic / enabled-watch-list rows).

**If any RESULT is FAIL**:

1. Print to the user the aggregated report — one section per failed gate, with the `=== GATE: <name> ===` block from that subagent's response.
2. Dispatch one `general-purpose` fixer subagent (`model: "sonnet"`) with the deduplicated FAIL list. Prompt:

   > You are fixing a Lava blockchain spec. Read `<chain>.json` and the deduplicated FAIL list below from Phase 6's parallel-gate run. Apply EVERY listed fix in one pass. Do not touch any field not mentioned in the FAIL list. Do not refactor, reformat, or improve adjacent fields.
   >
   > [paste deduplicated FAIL list with the per-gate sections from the parallel-gate reports]
   >
   > In addition to the FAIL list, the following are ADVISORY CU suggestions from the cu-semantic gate — apply them ONLY if they are clearly correct (a method's CU obviously outside its semantic band); skip any you are unsure about:
   > [paste cu-semantic Layer-1 ADVISORY rows, or "none"]
   >
   > Return a markdown summary of every change in the format:
   > `- <gate>:<row> — <one-sentence description of fix>`

3. After the fixer returns, validate JSON again:

   ```bash
   jq . <chain>.json > /dev/null
   echo "jq exit: $?"
   ```

   If exit non-zero, present the snapshot path, the `jq` error, and the fixer's diff to the user. STOP.

4. Do NOT re-run the validators — Phase 9's parallel reviewers and Phase 11's final reviewer catch any residual issues. Proceed to Phase 7.

## Phase 7 — Final jq gate

`<chain>.json` was written and jq-validated by the `spec-builder` subagent (Phase 4), and re-validated by the Phase 6 fixer after any edits. This phase is a final gate before the probe — confirm the file on disk is still valid jq **without reading its body into your context**:

```bash
jq . <chain>.json > /dev/null
echo "jq exit: $?"
```

If exit is non-zero (a fixer edit broke it), capture the excerpt and dispatch the Phase 6 fixer subagent again with the `jq` error to repair it — do NOT open and edit the spec body yourself:

```bash
jq . <chain>.json 2>&1 | head -n 20
```

Do not proceed to Phase 7.5 until `jq` exits 0. The canonical file structure (matching `iota.json` — `proposal.title` + `description` + `specs[]` mainnet/testnet + `deposit: "10000000ulava"`) is produced and enforced inside spec-builder, not here.

## Phase 7.5 — Endpoint discovery (delegated subagent)

Now that the spec is resolved, discover and validate an upstream endpoint for **every** interface, subscription, and addon it declares — including ones inherited from imports (gRPC, ws subscriptions, addons) that were invisible at Phase 2/3. This is why discovery runs here, not in the Phase 3 research fan-out.

**Dispatch ONE Agent subagent** with `subagent_type: general-purpose`, no `isolation`. Pass: `<spec_path>`, `<chain_name>`, `<chain_family>`, `<mainnet_index>`, `<testnet_index>`. Before dispatching, read `.claude/skills/create-spec/references/agents/endpoint-discovery.md` end-to-end (observe `END-OF-AGENT-ENDPOINT-DISCOVERY-SENTINEL`) and pass the agent its file path.

When it returns, collect (a) the **keyed candidate list** — `{network, interface, kind, addon_name, url, transport, source_url, validation}` — which becomes the Phase 8 input, and (b) the **coverage matrix**. Write the coverage matrix into the PR body and the Phase 12 checklist. Carry every `NOT_TESTABLE` row forward verbatim (with its searched-sources evidence) — a requirement with no endpoint is a transparent gap, not a spec defect and not a STOP.

## Phase 8 — Smart-router boot + multi-node method probe (delegated subagent)

This phase boots the candidate spec inside a dockerized **smart-router** (`ghcr.io/magma-devs/smart-router:main`) and probes every method through it. There is NO local lava node, NO gov proposal, and NO provider/consumer `screen` sessions — the smart-router loads the spec graph statically (`--use-static-spec`) and relays to the chain's public RPC upstreams, so a boot is seconds-to-a-minute. It is delegated to a single `general-purpose` subagent so the orchestrator's context stays free of boot/probe output. You (the orchestrator) do NOT run docker, write the router config, or run probes yourself — you only dispatch and collect the result.

**Inputs to gather before dispatch** (from earlier phases — do NOT re-research). The per-interface endpoints come from the **Phase 7.5 keyed candidate list** (validated-OK entries), NOT from a flat URL list:
- `<chain>` — lowercased chain name (filename stem, e.g., `iota`)
- `<INDEX>` — spec index UPPERCASE (e.g., `IOTA`) — must match the spec's `proposal.specs[].index`
- `<INTERFACE>` — `jsonrpc` | `rest` | `grpc` | `tendermintrpc` (the spec's `api_collections[].collection_data.api_interface`)
- The validated endpoints for each interface from Phase 7.5, **with their transport** preserved (e.g. gRPC `grpcs://` vs `grpc://`+insecure). At least one usable upstream is required to boot.
- The validated **subscription (ws)** endpoint for any interface whose Phase-7.5 row is a subscription requirement. The smart-router excludes any provider that lacks a ws upstream for a subscription-enabled chain, and refuses to boot once all providers are excluded (`all static providers failed verification — cannot serve endpoint`).
- For multi-interface chains (Cosmos), pass one `(INTERFACE, validated-urls, transport)` block per interface from the candidate list.
- Any requirement Phase 7.5 marked `NOT_TESTABLE` is expected to come back `NOT_TESTABLE` from the probe too — carry its evidence into the report rather than treating the absence as a defect.
- `<TESTNET_INDEX>` + `<TESTNET_NODE_URL_1..2>` + `<TESTNET_WS_URL>` — testnet spec index and node URLs from Phase 2/3 research. Pass them whenever ANY testnet RPC URL is known, so the subagent runs its Step 7 testnet verification pass (boot + verifications against the TESTNET variant — the only place the testnet chain-id `expected_value` is ever live-executed) and its Step 8 testnet block-time measurement. If no testnet URL is known, the testnet pass comes back SKIPPED — note that in the PR body and Phase 12 checklist.

**Boot is mandatory whenever at least one node URL is available.** Boot and probe with however many URLs you have (1, 2, or 3) — the router's startup spec resolution + upstream verification catches spec-level defects (e.g. a result_parsing bug or a wrong chain-id `expected_value` that blocks startup) that the static gates cannot see, so a single URL is worth booting. The orchestrator must not invent URLs.

If ZERO node URLs are available, do NOT silently skip: **STOP and ask the user to supply at least one node URL** before proceeding. Only skip Phase 8 with explicit user consent; if the user consents to skipping, note it in the Phase 12 checklist.

**Docker + GHCR access:** the image is private. In CI, a `docker/login-action` step (`${{ github.actor }}` + `${{ secrets.GITHUB_TOKEN }}`) logs in before this phase. Locally, the runner must already be logged in to `ghcr.io` with a token carrying the `read:packages` scope (`gh auth token | docker login ghcr.io -u "$(gh api user -q .login)" --password-stdin`). The subagent auto-detects `docker` vs `sudo docker`. If the image pull fails on auth, the subagent returns `SMOKE: BOOT_FAILED` — surface it and STOP.

**Read the subagent prompt fully** before dispatch:
- `.claude/skills/create-spec/references/agents/smart-router-tester.md` (observe `END-OF-SMART-ROUTER-TESTER-SENTINEL`)

**Dispatch ONE Agent subagent** with `subagent_type: general-purpose` (no `isolation` parameter — the subagent operates on the live working tree, since the candidate spec is uncommitted). Pass the prompt with all placeholders substituted. The subagent runs in the foreground from your point of view (you wait for its single return).

```
Agent(description: "Boot smart-router + probe methods for <chain>",
      subagent_type: "general-purpose",
      model: "sonnet",
      prompt: <smart-router-tester.md with placeholders substituted>)
```

When the subagent returns, it reports a short summary (`PARSE:` and `VERIFY:` verdicts from the Step 3.5 runtime check, counts including `LOG_WARN`, FAIL/TIMEOUT method names, any methods downgraded to WARN by the probe-window log scan, teardown status) and the path to `docs/<chain>/METHOD_PROBE_REPORT.md`. Read the report from disk if you need detail — do not ask the subagent to echo it back. Carry the log-scan WARNs into the Phase 9 reviewers and the Phase 10 fix list, the same as FAIL methods.

**On `SMOKE: BOOT_FAILED` or an ambiguous probe failure, do NOT debug it yourself by reading smart-router routing/parser/validation source**. The subagent owns that troubleshooting in its disposable context. If its diagnosis is insufficient, re-dispatch the smart-router-tester subagent with the specific failing config/symptom and ask it to localize the cause and return a one-line diagnosis + the relevant log path — then act on that. Reading router source into your own context is a permanent leak and is the single most expensive mistake in this phase.

**Record the `PARSE:` and `VERIFY:` verdicts** — they go into the PR body (CI) and the Phase 12 checklist. A `PARSE: FAIL` or `VERIFY: FAIL` is a spec defect: carry the failing directive/verification (with the agent's diagnosis excerpt) into the Phase 9 reviewers and the Phase 10 fix list as a CRITICAL item — Phase 10b re-runs the same check and reports the post-fix verdict. `PARTIAL` verdicts are upstream-capability findings: record which upstream was excluded, but do not treat them as spec defects.

**Record the `ADDONS:` coverage summary and table** — every addon/extension the spec declares comes back classified `TESTED_OK`, `TESTED_FAIL`, or `NOT_TESTABLE` (no provided node supports it). `TESTED_FAIL` is a spec/routing defect: carry it into the Phase 9 reviewers and Phase 10 fix list like a FAIL method. `NOT_TESTABLE` is not a defect — surface it in the PR body and Phase 12 checklist with the per-upstream evidence so a reviewer can decide whether to re-test with a more capable node.

**Record the `TESTNET_VERIFY:` verdict and the `BLOCK_TIME:` measurements.** `TESTNET_VERIFY: FAIL` (e.g. a wrong testnet chain-id `expected_value`) is a spec defect — carry it into the Phase 9 reviewers and the Phase 10 fix list as CRITICAL, exactly like a mainnet `VERIFY: FAIL`. `TESTNET_VERIFY: SKIPPED` means the testnet entry shipped without any live verification — surface that prominently in the PR body and Phase 12 checklist. A `BLOCK_TIME_MISMATCH (testnet)` (>20% deviation between the testnet's empirical block time and its effective spec value) → add a Phase 10 fix item: set an explicit `average_block_time` override in the testnet spec entry and recompute its derived params (`allowed_block_lag_for_qos_sync`, finalization fields) per the Phase 4 formulas. A `BLOCK_TIME_MISMATCH (mainnet)` should not happen (Phase 4 already locked the value against empirical data) — if it appears, treat it as MEDIUM and re-check the Phase 4 inputs.

If the subagent reports `SMOKE: BOOT_FAILED` or otherwise indicates the router could not boot, present the error to the user and STOP. Do not proceed to Phase 9.

If the subagent reports clean teardown and a populated report, proceed to Phase 9.

## Phase 9 — Parallel reviewers (3 fresh subagents, immediate-rename for collision)

**Do NOT use `isolation: "worktree"`.** Worktrees are created via `git worktree add`, which checks out HEAD — the last committed state. Since this skill never commits, the new candidate spec written by Phase 7 is uncommitted and would NOT be visible inside a worktree. A reviewer in a worktree would review the previously-committed (stale) spec, not the candidate. This produces phantom CRITICAL findings with line references outside the real file. Anchoring isolation is achieved by fresh-subagent-context alone, not by filesystem separation.

**Before dispatching:** clear any prior parallel-review report files so the reviewers start clean:

```bash
mkdir -p docs/<chain>
rm -f docs/<chain>/SPEC_REVIEW_GAPS.md
rm -f docs/<chain>/SPEC_REVIEW_GAPS_parallel_*.md
```

Dispatch THREE Agent subagents in parallel via a SINGLE message, each with `subagent_type: general-purpose`, `model: "sonnet"` (bump to `opus` if reviews miss issues on hard chains), and NO `isolation` parameter. Each subagent receives an `N` value (1, 2, or 3) so it knows which numbered output file to write. The prompt for reviewer N:

> You are reviewing a Lava blockchain spec. Your reviewer index is **N** (used in the output filename below).
>
> Run the `/review-spec` skill on `<chain>.json`. Pass through `$ARGUMENTS[1]` (API docs path, may be empty) and `$ARGUMENTS[2]` (credentials path, may be empty).
>
> Before running `/review-spec`, read `docs/<chain>/METHOD_PROBE_REPORT.md` if it exists and incorporate the probe findings into your review (especially any FAIL or WARN classifications).
>
> The following are settled, skill-mandated decisions — do NOT report them as findings: (a) `deposit` is `"10000000ulava"`; (b) `blocks_in_finalization_proof` is finality-typed — `3` probabilistic (PoW/slow PoS), `1` fast/instant finality (BFT, Tendermint/Cosmos, instant-settlement L2s), fallback `max(ceil(1000 / average_block_time), 3)` only when the finality model is unclear; (c) a method/addon/collection must NOT be flagged for disabling because a probe returned `-32601`/errors on the provided nodes — free-tier limitation; disabling requires positive evidence (docs explicitly state unsupported/removed, or the chain's node-client implementation lacks it, with URL).
>
> `/review-spec` writes its report to the hard-coded path `docs/<chain>/SPEC_REVIEW_GAPS.md`. **As the LAST step of your work — immediately after `/review-spec` returns** — rename that file to a unique numbered path so the other parallel reviewers do not clobber it:
>
> ```bash
> mv -n docs/<chain>/SPEC_REVIEW_GAPS.md docs/<chain>/SPEC_REVIEW_GAPS_parallel_N.md
> ```
>
> Use `mv -n` (no clobber) — if the destination already exists, the move fails rather than overwriting another reviewer's work. After the `mv`, verify it succeeded:
>
> ```bash
> test -f docs/<chain>/SPEC_REVIEW_GAPS_parallel_N.md && echo "RENAMED_OK" || echo "RENAMED_FAIL"
> ```
>
> If the rename failed (destination already existed OR source didn't exist because another reviewer's parallel write clobbered yours), retry your `/review-spec` invocation once. Then attempt the rename again.
>
> Return ONLY (do NOT paste the report body — it is on disk at the path below, and pasting it into your response defeats the Phase 10 consolidation by loading all three reports into the orchestrator's context):
> 1. The single line `REPORT: docs/<chain>/SPEC_REVIEW_GAPS_parallel_N.md`.
> 2. On the LAST line of your response, print exactly: `TALLY: CRITICAL=<X> MEDIUM=<Y> MINOR=<Z>` with integer counts.
>
> Do not paste findings, do not summarize them, and do not print anything after the TALLY line. The Phase 10 consolidation subagent reads the file from disk.

After all three subagents return, in the primary working tree:

1. Parse each subagent's TALLY line. If any TALLY is missing or unparseable, abort and report which reviewer.
2. Verify all three files exist:
   ```bash
   ls -la docs/<chain>/SPEC_REVIEW_GAPS_parallel_{1,2,3}.md
   ```
   If any are missing, the race-condition rename failed for that reviewer. Re-dispatch JUST the missing reviewer index and wait for it to complete (sequential at this point — collision risk is gone because only one reviewer is running).
3. The reports are now on disk at their numbered paths; no further extraction needed.

**Sanity check after collection:** if any reviewer reports CRITICAL findings whose `evidence_line_number` exceeds the actual line count of `<chain>.json`, that reviewer reviewed stale state — likely because the candidate file was modified after the reviewer started. Note the discrepancy to the user and either re-dispatch that one reviewer, or treat its findings as advisory rather than authoritative. Verify with:

```bash
wc -l <chain>.json
```

## Phase 10 — Synthesize gaps + single fix pass

**Consolidate the reviews in a subagent — do not read the three full reports into your own context.** Dispatch one `general-purpose` subagent (`model: "sonnet"`) with the three numbered review-report paths + the Phase 8 probe-report path. Its job: read all of them from disk, build a **deduplicated** list of CRITICAL + MEDIUM gaps keyed by `(gap_title, evidence_line_number)`, drop MINOR gaps, apply the disable-suggestion filter below, and **write the result to `docs/<chain>/FIX_LIST.md`** — returning only a one-line count (`N critical, M medium; K disable-suggestions stripped`) + that path. You then read `FIX_LIST.md` (a short file), never the three raw reports. This keeps the probe→review→fix loop state small even across re-runs.

The consolidation subagent applies this rule when building the list:

**Disable-suggestion filter (enforced).** Before dispatching the fixer, STRIP from the gap list every suggestion to set `enabled: false` on (or remove) a method, addon, or collection whose only justification is probe results (JSON-RPC `-32601`/`-32600`, HTTP `501`/`404`/`405`/`429`/`5xx`, connection errors, or timeouts on the provided nodes) — these are free-tier/gateway artifacts, never sufficient evidence (Phase 5 disable rule). An HTTP `501` from a public upstream is NOT proof the node lacks the method. Keep such a suggestion ONLY if it cites positive evidence of absence (official docs explicitly say unsupported/removed, or the chain's node client does not implement it — with a URL); when keeping one, the fixer must also **return** the evidence row so you (the orchestrator) can add it to the **Disabled-API Justifications** PR comment (the durable ledger defined in Phase 5) — never a `docs/` file. Stripped suggestions go to the PR-body watch-list instead, with a note that they need a paid/dedicated node to re-test.

Snapshot the spec before fixing:

```bash
cp <chain>.json /tmp/spec_<chain>_pre_fix.json
```

Dispatch one `general-purpose` Agent subagent (`model: "sonnet"`, no worktree needed — main filesystem) with this prompt:

> You are fixing a Lava blockchain spec. Read `<chain>.json` and the deduplicated gap list at `docs/<chain>/FIX_LIST.md`. Apply EVERY listed CRITICAL and MEDIUM fix in one pass. Do not touch any field not mentioned in the gap list. Do not refactor, reformat, or improve adjacent fields.
>
> You MUST NOT set `enabled: false` on any method, addon, or collection unless the gap entry cites positive documentation/client-source evidence with a URL — probe errors alone (`-32601`, HTTP `501`/`4xx`/`5xx`, timeouts) never justify disabling. When you do disable one, include its positive-evidence row — `| name | evidence-type | source URL | one-line quote |` — in your returned summary under a `DISABLED-API JUSTIFICATIONS:` heading so the orchestrator can post it to the PR's Disabled-API Justifications comment; do NOT write a file under `docs/` (it is gitignored and never persists).
>
> Return a markdown summary of every change in the format:
> `- <file>:<line> — <one-sentence description> (gap: <severity>, "<gap title>")`

After the fixer returns, validate JSON again:

```bash
jq . <chain>.json > /dev/null
echo "jq exit: $?"
```

If exit non-zero: outcome = `BROKEN_AFTER_FIX`. Present the snapshot path (`/tmp/spec_<chain>_pre_fix.json`), the `jq` error, and the fixer's diff to the user. STOP. Do not proceed to Phase 10b.

## Phase 10b — Smoke regression test (delegated subagent)

Same delegation pattern as Phase 8 — a single `general-purpose` subagent re-boots the dockerized smart-router against the FIXED spec on disk and re-probes a deterministic minimal set to detect regressions. The orchestrator does NOT run docker or compare classifications inline.

Skip this phase entirely only if Phase 8 was skipped (i.e. the user explicitly consented to skipping when zero node URLs were available).

**Read the subagent prompt fully** before dispatch:
- `.claude/skills/create-spec/references/agents/smart-router-smoke-tester.md` (observe `END-OF-SMART-ROUTER-SMOKE-TESTER-SENTINEL`)

**Dispatch ONE Agent subagent** with `subagent_type: general-purpose` and no `isolation`. Substitute the same `<chain>` / `<INDEX>` / `<INTERFACE>` / node URLs used in Phase 8, and pass the Phase 8 report path (`docs/<chain>/METHOD_PROBE_REPORT.md`) plus the deduplicated Phase 10 fix list (so the smoke tester can suggest a plausible culprit on regression). If any Phase 10 fix touched the TESTNET spec entry (e.g. a chain-id `expected_value` or an `average_block_time` override), also pass the testnet inputs and append to the prompt: "After the mainnet smoke pass, repeat the Step 7 testnet verification pass from smart-router-tester.md against the fixed spec and report its `TESTNET_VERIFY:` verdict."

```
Agent(description: "Smoke re-test fixed spec for <chain>",
      subagent_type: "general-purpose",
      model: "sonnet",
      prompt: <smart-router-smoke-tester.md with placeholders substituted>)
```

When the subagent returns, expect one of:
- `SMOKE: OK` → record the post-fix `PARSE:`/`VERIFY:`/`ADDONS:` verdicts from its summary (for the PR body and Phase 12 checklist), then proceed to Phase 11.
- `SMOKE: REGRESSION` → present the 7-row probe table and the suspected-culprit note to the user. STOP. Do NOT proceed to Phase 11.
- `SMOKE: BOOT_FAILED` → present the log excerpt. STOP. Do NOT proceed to Phase 11.

## Phase 11 — Final reviewer (clean context)

**Do NOT use `isolation: "worktree"`** — same reason as Phase 9. The candidate spec is uncommitted, so a worktree reviewer would see stale HEAD state. Fresh-subagent-context alone provides the anchoring isolation we need.

Before invoking the final reviewer, archive prior reports so the reviewer's `/review-spec` skill (Phase 1 of which scans `docs/<CHAIN_NAME>/`) does not pick them up as anchoring. Also remove any stale `SPEC_REVIEW_GAPS.md` (without the `_parallel_N` suffix) that might be lingering:

```bash
mkdir -p docs/<chain>/_archive
mv docs/<chain>/SPEC_REVIEW_GAPS_parallel_*.md docs/<chain>/_archive/ 2>/dev/null || true
mv docs/<chain>/SPEC_REVIEW_FIXES_*.md docs/<chain>/_archive/ 2>/dev/null || true
rm -f docs/<chain>/SPEC_REVIEW_GAPS.md
```

**Assemble the Disabled-API Justifications ledger** to hand the reviewer: in a CI run, read it from the PR's `Disabled-API Justifications` comment (`gh pr view "$PR_NUMBER" --json comments`), falling back to the disabled-API ledger carried in the PR body if that comment has not been posted yet (the original create_spec run emits the ledger into the PR body before any PR comment exists); in an interactive run, use the rows `spec-builder` (Phase 5) and the Phase-10 fixer produced this run. Substitute it for `[LEDGER]` in the prompt below (use `(none — no disabled APIs)` if nothing is disabled).

Dispatch ONE Agent subagent with `subagent_type: general-purpose`, `model: "sonnet"` (bump to `opus` if the final pass misses issues), and no `isolation` parameter. The prompt:

> You are reviewing a Lava blockchain spec — final pass after fixes were applied.
>
> Run the `/review-spec` skill on `<chain>.json`. Pass through `$ARGUMENTS[1]` and `$ARGUMENTS[2]`.
>
> Before running `/review-spec`, read `docs/<chain>/METHOD_PROBE_REPORT.md` if it exists.
>
> The following are settled, skill-mandated decisions — do NOT report them as findings: (a) `deposit` is `"10000000ulava"`; (b) `blocks_in_finalization_proof` is finality-typed — `3` probabilistic, `1` fast/instant finality, fallback `max(ceil(1000 / average_block_time), 3)` only when the finality model is unclear; (c) probe errors on the provided nodes never justify disabling a method/addon/collection.
>
> Additionally verify disable justifications: list every `enabled: false` api/collection in `<chain>.json` (`jq`) and check each has a positive-evidence row (docs-explicit or client-source, with URL) in the **Disabled-API Justifications ledger** reproduced below. Any disabled entry without one is a CRITICAL finding.
>
> Disabled-API Justifications ledger:
>
> [LEDGER]
>
> `/review-spec` writes its report to `docs/<chain>/SPEC_REVIEW_GAPS.md`. After it returns, rename to a final-pass-specific path:
>
> ```bash
> mv docs/<chain>/SPEC_REVIEW_GAPS.md docs/<chain>/SPEC_REVIEW_GAPS_final.md
> ```
>
> Return:
> 1. The FULL contents of `docs/<chain>/SPEC_REVIEW_GAPS_final.md` as the body of your response.
> 2. On the LAST line of your response, print exactly: `TALLY: CRITICAL=<X> MEDIUM=<Y> MINOR=<Z>` with integer counts.

**Sanity check (same as Phase 9):** if the reviewer reports CRITICAL findings whose `evidence_line_number` exceeds the actual line count of `<chain>.json`, the reviewer reviewed stale state. Re-dispatch once.

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
- ~ All APIs tested and working                          (Phase 8 probe — see docs/<chain>/METHOD_PROBE_REPORT.md; stateful methods skipped)
- ~ Block parsing validated for each API                 (Phase 8 existence-tested; full per-API parse validation requires production traffic)
- ✓ Parse directives executed by live router             (Phase 8 Step 3.5: PARSE=<verdict>, VERIFY=<verdict>; Phase 10b re-check: <verdict or n/a>)
- ~ Addons & extensions tested                            (Phase 8 Step 1c: <n> tested-ok / <n> failed / <n> not-testable — not-testable items need a supporting node to verify)
- ✓ Verifications pass on live nodes                     (Phase 6 chain-id curl + Phase 8 boot-window verification scan + multi-node probe)
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
- ☐ Deposit amount confirmed                             (default "10000000ulava" written; user confirms)
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

- Writing anywhere other than the single `<chain>.json` at the repo root — do not create subdirectories for specs
- Creating `docs/<chain>/` documentation files beyond the probe and review reports the skill emits during its own run — in particular, disabled-API justifications go to the **Disabled-API Justifications** PR comment (Phase 5), never a `docs/` file (which is gitignored and never committed)
- Creating governance proposal JSONs or `PROPOSAL_DESCRIPTION.md`
- Any git operations: `git add`, `git commit`, `git push`, `git checkout`, `glab mr create`. User handles all git manually.

If the user asks for any of these, surface the limitation and confirm scope before continuing.
