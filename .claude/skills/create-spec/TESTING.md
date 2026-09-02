# create-spec — Testing & Verification Reference

Every check the `create-spec` pipeline performs, what it inspects, how it decides, and what a failure does to the run.

> **Derived doc.** Written by reading the skill sources — nothing here was executed to produce it. The authoritative sources are:
> - `.claude/skills/create-spec/SKILL.md` (phase orchestration, stop conditions)
> - `.claude/skills/create-spec/references/agents/*.md` (per-gate and per-probe logic)
> - `.claude/skills/create-spec/scripts/check_*.sh`, `compare_*.sh` (deterministic checks)
> - `.claude/skills/review-spec/SKILL.md` (the Phase 9 / 11 reviewer workflow)
>
> **Derived from `main` at `119f1bb`.** One exception postdates that pin: the portability fixes to `compare_spec_methods.sh` and `test_run_stats.sh` recorded in Appendix B, described as they now stand. If the skill has moved on further, re-derive rather than trusting this file — its predecessor, `references/phase4-testing-and-validation.md`, went stale exactly this way.
>
> **Looking for the QA-facing version?** [`QA_GUIDE.md`](../../../QA_GUIDE.md) at the repo root covers where to find a given spec's test evidence, how to read the verdicts, and what to test by hand. This file is the mechanics underneath it.

---

## At a glance

The pipeline is 12 phases; six of them verify. Ordered cheapest-first, so a docker boot is only paid for once the static gates are clean.

| Phase | What it is | Runs | Failure consequence |
|---|---|---|---|
| **6** | 9 static gates (offline / jq-backed) + inline pre-flight | 9 parallel subagents | Any `RESULT: FAIL` → **one** fixer pass, then straight to Phase 7. Validators are **not** re-run. Triplet mismatch in pre-flight → **STOP** |
| **7** | Final `jq` + removed-field gate | orchestrator, inline | Either fails → dispatch the fixer; **do not proceed** until `jq` exits 0 **and** the guard passes |
| **7.5** | Endpoint discovery + validation | 1 subagent | `NOT_TESTABLE` rows are a transparent gap, **never a STOP** — they propagate into Phase 8 |
| **8** | Smart-router boot + live method probe | 1 subagent | `BOOT_FAILED` → **STOP**, no Phase 9. `PARSE`/`VERIFY`/`TESTNET_VERIFY: FAIL` → run continues, carried into 9 + 10 as CRITICAL |
| **9** | 3 parallel `/review-spec` reviewers | 3 subagents | Missing/unparseable `TALLY` → abort, name the reviewer |
| **10** | Consolidate gaps + single fix pass | 2 subagents | `jq` broken after fix → `BROKEN_AFTER_FIX`, **STOP**, no Phase 10b |
| **10b** | Smoke regression re-boot | 1 subagent | `REGRESSION` or `BOOT_FAILED` → **STOP**, no Phase 11 |
| **11** | Final reviewer, clean context | 1 subagent | Any CRITICAL or MEDIUM → **CHANGES REQUESTED**, STOP, **no retry loop**, Phase 12 skipped |
| **12** | Coverage checklist + run stats | orchestrator | Reporting only; no gate |

Phases 1–5 (pre-flight, input gathering, research fan-out, synthesis, inheritance audit) produce the spec; they contain no verification gates. The refuse-to-write gate lives inside the `spec-builder` subagent and can return `SPEC: BLOCKED`, which stops the run before any test executes.

**Phase 1A — add-testnet mode** is the exception. When Phase 1 resolves to "append a testnet to an existing spec", Phases 2–7 are skipped entirely and the run jumps to Phase 7.5 → 8, scoped to the new testnet only. Its single gate is **A4**, where both CI guards below must pass; the mainnet is byte-for-byte unchanged and is not re-probed. This mode exists because regenerating an existing file is what silently drifted the mainnet on PR #80.

### CI-level guards (outside the 12 phases)

Two guards run as `spec_pipeline.yml` steps rather than skill phases. Both **fail closed** — if `gh pr view` cannot list the PR's files, the step errors rather than reporting a clean pass.

| Guard | Script | What it catches |
|---|---|---|
| **Reject removed spec fields** | `check_unused_fields.sh` | Any of the 15 fields deleted from the smart-router model (smart-router#218): the nine governance fields, `proposal.title`/`description`, top-level `deposit`, `extra_compute_units`, `category.local`, `category.subscription`. Strict by default (exit 1, printing each offender's exact JSON path); `--warn` reports but exits 0, for deliberately exercising a legacy fixture. Fails closed on unparseable JSON, so a corrupt spec cannot read as clean |
| **Preservation** (add-testnet PRs) | `check_preservation.sh` | Semantic drift in any *pre-existing* spec entry. Compares `jq -S` canonical form, so it is immune to whitespace and key order but catches every value change, field add/remove, and array reorder |

The second exists because the first is not enough: `check_unused_fields.sh` only sees removed field *names*. PR #80 regenerated a mainnet whose `average_block_time` drifted 200 → 35 and whose parser arg changed `block_height` → `block_hash` — both passed the removed-field guard cleanly.

⚠️ **The preservation guard self-skips.** If `check_preservation.sh` is not on the PR branch, the step logs `::notice:: … skipping` and exits 0. In a CI log a skip is easy to mistake for a pass.

---

## Two cross-cutting invariants

These are enforced in more than one phase. Documented once here rather than repeated below.

### 1. The free-tier / positive-evidence disable rule

`create-spec` probes **free-tier public RPC nodes only**. A method absent there may work on a paid or on-prem node. Therefore a probe error — JSON-RPC `-32601`/`-32600`, HTTP `501`/`404`/`405`/`429`/`5xx`, a connection error, or a timeout — is **never** sufficient evidence to set `enabled: false`.

`enabled: false` is legal only with **positive evidence of absence**: official docs explicitly stating unsupported/removed, or the chain's node-client implementation lacking the method — recorded with a URL in the **Disabled-API Justifications PR comment**.

> That ledger is a PR comment, **not** a file. It was previously written to `docs/<chain>/DISABLED_JUSTIFICATIONS.md`, but `docs/` is gitignored, so the file never reached the branch and a later fresh-runner review re-flagged every disable as unjustified. In an interactive run with no PR yet, the ledger is printed to the user instead.

Enforced at three points:

| Where | How |
|---|---|
| Phase 6 `enabled` gate | Advisory watch-list only. Never FAILs, never recommends disabling (`enabled-validator.md:3,10-17`) |
| Phase 10 consolidation | Strips every probe-justified disable suggestion from the fix list before the fixer sees it; stripped rows go to the PR watch-list instead (`SKILL.md:516`) |
| Phase 11 final review | Audits every `enabled: false` entry for a justification row. Missing row → **CRITICAL** (`SKILL.md:590`) |

### 2. The archive ↔ pruning ↔ `GET_EARLIEST_BLOCK` triplet

Per spec entry, these three are indivisible — all present or all absent:

- an `archive` extension on a collection
- a `pruning` verification
- a `GET_EARLIEST_BLOCK` parse directive

Checked inline at the top of Phase 6 with a single `jq` producing three booleans per entry. **Any mixed row → STOP** and fix by hand from `references/phase3.4-parse-directives-and-extensions.md` (`SKILL.md:277-291`).

`GET_EARLIEST_BLOCK` is exercised at runtime *only* via the `pruning` verification at Phase 8 boot — the chain tracker never calls it (`smart-router-tester.md:243`).

---

## Phase 6 — Static validation gates

### Inline pre-flight (orchestrator, before dispatching the gates)

Four of these surface again as gate failures. **The last two are covered by no validator at all** and are the pipeline's known static blind spots:

| Check | Mechanism | Covered by a gate? |
|---|---|---|
| `index` uppercase, unique, matches the chain | manual | partly (chain-metadata) |
| `name` and `enabled` present at spec-entry level | manual | partly (chain-metadata) |
| Mainnet `chain-id` `expected_value` from a **live curl**, not a docs decimal | `curl` the mainnet RPC, capture the hex verbatim | value correctness only at Phase 8 |
| Testnet `chain-id` `expected_value` from a live curl | `curl` the testnet RPC | value correctness only at Phase 8 Step 7 |
| **Every `hanging_api: true` has an explicit `timeout_ms`** | `jq` selecting `hanging_api == true and timeout_ms == null`; output must be empty | **NO — hand-check only** (`SKILL.md:263`) |
| **`category.stateful` set only on broadcast / state-modifying methods** | spot-check against chain docs; read methods must be `stateful: 0` or unset | **NO — no validator enforces direction** (`SKILL.md:264`) |

Note on the two chain-id rows: Phase 6 *obtains* the values by curling each network directly. Phase 8 is where the resulting spec verification is *executed through the router* — Step 3.5(c) for mainnet, Step 7 for testnet. Different operations, easily conflated.

Then the archive triplet check (above), then the gates.

### The 9 gates

Dispatched in a single message, all foreground, no isolation. "9 gates" is a count of subagents, not of checks — parse-directive runs 3 layers, pruning runs 2 scripts, method-schema runs 3 scripts, cu-semantic runs 2 layers.

| # | Gate | Model | Backing check | Verdict |
|---|---|---|---|---|
| 1 | `methods-coverage` | sonnet | `compare_spec_methods.sh` | PASS / FAIL |
| 2 | `parse-directive` | sonnet | 3 layers (static matrix → scout diff → live RPC) | PASS / FAIL |
| 3 | `chain-metadata` | haiku | `check_network_params.sh` | PASS / FAIL |
| 4 | `verifications` | haiku | `check_verifications.sh` | PASS / FAIL |
| 5 | `extensions` | haiku | `check_extensions.sh` | PASS / FAIL |
| 6 | `cu-semantic` | sonnet | Layer 0 mechanical + Layer 1 advisory | PASS / FAIL (Layer 0 only) |
| 7 | `pruning` | haiku | `check_pruning.sh` + `check_archive_value.sh` | PASS / FAIL |
| 8 | `enabled` | haiku | watch-list diff | **always PASS** |
| 9 | `method-schema` | haiku | `check_method_schema.sh` + `check_hanging_api.sh` + `check_stateful.sh` | PASS / FAIL + ADVISORY |

Every validator prompt ends with "Do NOT modify the candidate spec" — gates observe, the fixer edits.

---

#### 1. `methods-coverage`

Diffs the spec against the ground-truth method list `/tmp/<chain>_methods.txt` written by the Phase 3 `api-docs-researcher`.

`compare_spec_methods.sh` walks `.imports[]` **transitively**, resolving parents **by content, not filename** — it scans every `*.json` beside the candidate and matches each import to whichever file declares that index (ETH1 lives in `ethereum.json`, not `eth1.json`). It prints the resolved chain, then three sections:

- `PRESENT` — in both
- `MISSING` — in the ground truth, absent from the spec and all imports → **FAIL**, unless justified as `deprecated`, `admin-only`, `platform-specific`, or `empirically absent (-32601 against the chain's public RPC)`
- `EXTRA IN SPEC` — informational only; chains legitimately add methods beyond what research discovered

Missing or empty methods file → immediate FAIL ("api-docs-researcher did not produce ground truth").

#### 2. `parse-directive` — three layers

**Layer 1 — static matrix (offline).** Four sub-checks, the first three of which run for *every* chain family whether or not it appears in the matrix:

- **Boot-critical presence.** `check_directive_presence.sh` BFS-walks the candidate's `imports` graph and checks the *union* of the candidate plus all transitive parents. Inheritance-aware by necessity: EVM L2s inherit from ETH1 and Cosmos chains from COSMOSSDK/TENDERMINT, so their own `parse_directives` arrays are empty by design and a naive check false-FAILs every one of them. `GET_BLOCKNUM` is **hard-required** — with no head the tracker cannot start. `GET_BLOCK_BY_NUM` is **advisory**: absent, it prints an `INFO` line and passes, because smart-router PR #245 added head-only chain tracking (follow the head, keep no block hashes, no fork detection). That is the only correct modelling for a chain with no blocks — Canton being the first, where ordering is by sequencer timestamp with instant finality and no block exists to fetch or hash. For most chains its absence is still a defect, which is what the `INFO` line surfaces to review.
- **Numeric placeholder.** `GET_BLOCK_BY_NUM`'s `function_template` must contain `%d`, `%x`, or `0x%x` — without one the router cannot drive it by block number.
- **Echoed-slot.** `GET_BLOCK_BY_NUM`'s `parser_arg` must not end in a bare state-index field (`slot`, `height`, `number`, `blocknumber`, `block_number`). Such a directive extracts the echoed `%d` input, every provider then "agrees" trivially, and data-reliability is defeated. `GET_BLOCKNUM` is exempt — it legitimately returns the height itself. Aimed squarely at slot chains (Solana, Beacon), which are exactly the families that fall outside the matrix.
- **Canonical match**, when `(api_interface, chain_family)` *is* in the matrix — required `function_tag`s present with the canonical `api_name`; `function_template` structurally equal (placeholders `%d`/`%s`/`%x`/`0x%x` treated as wildcards, everything else exact); `parser_func` and `parser_arg` equal.

Matrix families covered: `(jsonrpc, evm)`, `(jsonrpc, solana)`, `(tendermintrpc, cosmos)`, `(rest, cosmos)`. Unknown family → template-matching portion records `SKIPPED`, the three checks above still run.

**Layer 2 — scout diff (offline, conditional).** If `/tmp/<chain>_directives.txt` exists, `compare_spec_directives.sh` diffs the candidate against it by `function_tag|api_name|sha256(function_template)`, emitting `PRESENT` / `MISSING` / `EXTRA IN SPEC` / `HASH-MISMATCH`. `MISSING` and `HASH-MISMATCH` are FAILs unless documented. No scout artifact → `SKIPPED`.

**Layer 3 — live RPC (conditional on an RPC URL).** Issues each directive's `function_template` against the real node, walks `parser_arg`, and type-checks the extracted value (`GET_BLOCKNUM` → positive int; `GET_BLOCK_BY_NUM` → string identifier; `GET_EARLIEST_BLOCK` → positive int ≤ blocknum; chain-id → matches `expected_value`; SUBSCRIBE/UNSUBSCRIBE → `STRUCTURAL_ONLY`, not a FAIL). Two checks here are worth spelling out:

- **Counter chaining.** `GET_BLOCK_BY_NUM` must be probed with the integer `GET_BLOCKNUM` *actually returned in the same run* — never an arbitrary "reasonable" number. An empty array / `null` / not-found means the two directives sit on different counters (e.g. daaScore vs blueScore) and the chain tracker will spin forever at boot → **FAIL**. If `GET_BLOCKNUM` itself failed, `GET_BLOCK_BY_NUM` is `BLOCKED`. *Blind spot:* a range endpoint (`blueScoreLt=%d`, "nearest below") returns a wrong-but-non-empty block on a counter mismatch and passes — for those, additionally assert the returned block's own height is within a small window of N, or record `PARTIAL` and let Phase 8 confirm.
- **Top-level-array rejection** (`rest` + `PARSE_CANONICAL` only). The response body must satisfy `jq -e 'type=="object"'`. The router's REST parser cannot index a top-level JSON array — `parser_arg ["0", …]` indexes the response *object* — so a top-level array is a **FAIL** even though `jq` alone walks it fine. The live router throws `blockContainer is not map[string]interface{}`.

Layer 3 deliberately models only the two router constraints that used to surface at Phase 8 boot. It does **not** model generic-parser fallback, `encoding` post-processing, or `DefaultValue` degradation — the authoritative runtime check remains Phase 8 Step 3.5 (`parse-directive-validator.md:169`).

#### 3. `chain-metadata` — `check_network_params.sh`

Per spec entry, recomputes the formula-derived params from `average_block_time` and compares:

| Field | Rule |
|---|---|
| `average_block_time` | present and non-zero |
| `block_distance_for_finalized_data` | present |
| `blocks_in_finalization_proof` | must be in the legal set `{1, 3, max(ceil(1000/abt), 3)}` |
| `allowed_block_lag_for_qos_sync` | exactly `ceil(10000 / abt)`, minimum 1 |

The `blocks_in_finalization_proof` rule is a set, not a formula, on purpose: the value is **finality-typed** (`1` fast/instant finality — BFT, Tendermint/Cosmos, instant-settlement L2s; `3` probabilistic — PoW/slow PoS; the `max(ceil(1000/abt), 3)` fallback only when the finality model is unclear), and the finality class is not stored in the spec, so the gate can only reject off-formula numbers like 0, 2, 5. Pinning the fallback as the sole expected value previously forced instant-finality chains (Akash, Algorand) to `3` and overrode correct synthesis — see the script's Lumia PR #10 comment at `check_network_params.sh:30-37`.

#### 4. `verifications` — `check_verifications.sh`

Per `verifications[]` entry: `name` present; `values[]` non-empty; `severity` (which lives on `values[]`, not on the verification) in `{Warning, Fail, Stop}` or absent → defaults to `Fail`.

Cross-reference: every verification's `parse_directive.function_tag` (other than the literal `VERIFICATION`) must exist in its own collection's `parse_directives[]`. Not found → **FAIL**.

`INFO` rows are not failures — a missing `expected_value` (latest-distance-only check) and a wildcard `"*"` are both INFO. **One exception, promoted to FAIL:** a `"*"` (or any non-base-10-integer) `expected_value` on a `GET_BLOCK_BY_NUM` path with no `latest_distance`. See gate 7.

#### 5. `extensions` — `check_extensions.sh`

- Every extension has a `name` and a non-null `cu_multiplier`
- An `archive` extension additionally requires `rule.block`
- Every collection with a non-empty `collection_data.add_on` must have at least one verification
- No duplicate extension names within a collection

#### 6. `cu-semantic` — two layers

**Layer 0 — mechanical, hard gate.** Exactly two exact-equality rules, both on subscription mechanics:

| Recognize by | Required CU |
|---|---|
| `category.subscription == true` AND name contains `ubscribe` but NOT `nsubscribe` | exactly `1000` |
| `category.subscription == true` AND name contains `nsubscribe` | exactly `10` |

**Layer 1 — advisory bands.** Each method bucketed by name + category + parser, then checked against a band: tx-submit 10–40 · simulate 40–60 · heavy (logs/traces/range scans) 60–200 · state-read 10–20. Out-of-band methods emit ADVISORY rows; the instruction is to bias toward silence when the bucket is uncertain.

Only Layer 0 can fail the gate. There is deliberately **no uniformity/anomaly check** — uniform CU across methods is not a defect; COSMOSSDK and LAVA ship 100% uniform CU, TENDERMINT 96%, IOTA 85%, and no threshold separates lazy flattening from legitimate uniformity (`cu-semantic-validator.md:5`). Layer 0 also deliberately does *not* pin `stateful` methods or read methods to fixed values.

#### 7. `pruning` — two scripts, gate FAILs if either does

**`check_pruning.sh <spec> <retention_blocks>`** — every `archive.rule.block` and `pruning.latest_distance` must be within a 3× band of the research-derived retention window (`RET/3` … `RET*3`). `retention_blocks: unknown` → prints `INFO: retention unknown` and PASSes; the orchestrator treats INFO as PASS and prints it. Never block on missing research data.

**`check_archive_value.sh <spec>`** — the archive-tier `pruning` `expected_value` must be a base-10 integer **specifically on the `GET_BLOCK_BY_NUM` path with no `latest_distance`**, because that is the one path where the router calls `strconv.ParseInt(value, 10, 64)` (`chain_fetcher.go:314-337`). A `"*"` there makes ParseInt fail and the router **excludes the archive provider at boot** — a CRITICAL spec defect. Every other path (`latest_distance` set, or `function_tag` none / `GET_EARLIEST_BLOCK` / `VERIFICATION`) is fine and is not flagged. Fix: use `"1"`, or set `latest_distance`.

Note the asymmetry with the EVM convention: non-EVM archive tiers use a base-10 integer (commonly `"1"` — archive from block 1), EVM uses `"0x0"`.

#### 8. `enabled` — advisory only, never fails

Lists methods that are still `enabled: true` despite research having *explicitly* documented them as unsupported/deprecated/`-32601` on this chain. Emits WATCH rows. Methods with no research verdict are silent.

`RESULT` is **always PASS**. Watch-list rows do **not** feed the fixer — they are printed to the user and carried into Phase 8 as a probe watch-list. See invariant 1.

#### 9. `method-schema` — `check_method_schema.sh` + `check_hanging_api.sh` + `check_stateful.sh`

**`check_method_schema.sh`** — per API: `enabled`, `compute_units`, `block_parsing`, `category` all present; when `block_parsing` exists, `parser_func` and `parser_arg` present and **every `parser_arg` element a string**. Plus: no duplicate API names within a collection.

**`check_hanging_api.sh`** — the three `category.hanging_api` rules. All three come from one function, `protocol/chainlib/common.go:575`:

```go
func GetRelayTimeout(chainMessage, averageBlockTime) time.Duration {
    if chainMessage.TimeoutOverride() != 0 { return chainMessage.TimeoutOverride() }
    extraRelayTimeout := 0
    if IsHangingApi(chainMessage) { extraRelayTimeout = averageBlockTime * 2 }
    relayTimeAddition := common.GetTimePerCu(GetComputeUnits(chainMessage))
    if chainMessage.GetApi().TimeoutMs > 0 {
        relayTimeAddition = time.Millisecond * time.Duration(chainMessage.GetApi().TimeoutMs)
    }
    return extraRelayTimeout + relayTimeAddition
}
```

1. **`hanging_api` on a `SUBSCRIBE`-tagged API → FAIL.** The router never reads it. `consumer_websocket_manager.go:298` branches on the SUBSCRIBE function tag straight into `StartSubscription`; all four `GetRelayTimeout` call sites are on the unary path and neither subscription manager references it. A subscription's lifetime is its socket's — the WS manager's only timeouts are two hardcoded 10s constants for *unsubscribe* teardown. So on a SUBSCRIBE-tagged API, `hanging_api`, `compute_units` and `timeout_ms` are all dead inputs. SUBSCRIBE names are collected **inheritance-aware** (candidate + transitive parents through `imports`), because an L2 importing ETH1 has an empty `parse_directives` array of its own.

2. **`hanging_api: true` with no `timeout_ms` → FAIL.** Automates the rule stated at `SKILL.md:263` and `agents/spec-builder.md:59`, which those docs previously flagged as having no validator coverage.

3. **`timeout_ms` below `max(1s, CU × 100ms)` → FAIL.** `timeout_ms` **replaces** the CU term rather than adding to it, so a value under the CU-implied floor *shortens* the relay budget relative to setting nothing at all — the opposite of why anyone sets the field. Caught live on Acala: at CU 1000 the implied base is 100 000 ms, and a reflexive `timeout_ms: 30000` would have cut the budget from 124s to 54s (MAG-3389).

Rule 1 short-circuits — a subscription is never judged on its timeout, since neither field is read.

**`check_stateful.sh`** — direction check for `category.stateful`. The flag is a routing instruction, not a label: it maps to `CONSISTENCY_SELECT_ALL_PROVIDERS`, and the router acts on it in four places (`rpcsmartrouter_server.go:3336`, `:3585`, `:3835`, `:4735`) — the call is fanned out to **every** provider and excluded from cross-validation (`cross_validation_policy.go:422`) and the recovery probe (`recovery_probe.go:112-133`). Both directions fail silently:

| Mistake | Consequence |
|---|---|
| `stateful: 0` on a write | the broadcast reaches one provider; no redundancy where it matters most |
| `stateful: 1` on a read | every call fanned out to all providers, billed accordingly, cross-validation lost |

Unlike `hanging_api` this cannot be settled from the router source — *"does this method change chain state"* is chain knowledge. Nor by vote: `author_submitAndWatchExtrinsic` splits **10 specs at `0` against 11 at `1`**, `kusama.json` and `polkadot.json` on opposite sides, so a majority rule yields no answer exactly where one is needed. Hence three layers of decreasing confidence:

1. **Curated write list → FAIL.** Methods that unambiguously broadcast. Curated rather than voted, so it still fires when the whole catalogue agrees and is wrong.
2. **Curated read list → FAIL.** Simulation and codec helpers that change nothing. `eth_fillTransaction` is on it by name — SPEC_GUIDE.md and phase3.2 both call it the classic trap, a `*_fill*`/`*_prepare*` helper whose argument shape looks like a transaction.
3. **Cross-spec consensus → INFO, never FAIL.** Fires when ≥ 90% of the *other* specs declaring a name disagree with the candidate, and at least 4 declare it. Advisory because 24 of 5,539 distinct method names in the catalogue genuinely disagree.

REST entries are keyed `"TYPE /path"` where the verb disambiguates: `GET /cosmos/tx/v1beta1/txs` is a query, `POST` to the same path is BroadcastTx. The verb resolves a name collision — it does **not** classify. Treating POST as "is a write" is precisely the bug that put four read endpoints on the write path in `cosmossdk.json`.

Calibration over the 140-spec catalogue: **29 FAIL rows in 16 specs, 11 INFO rows** — every FAIL a genuine defect (the 10 specs with the watch pair at `0`, `babylon`/`kava`/`sei` on `decode/amino`, `monad`/`optimism` on `eth_sendTransaction`, and `cosmossdk`'s four REST reads).

**Scope.** Candidate file only, which is how the pipeline uses it. 152 APIs across ~30 established specs (`ethereum`, `cosmossdk`, `tendermint`, `solana`, `kusama` …) predate rule 2 and would fail if it were run over the whole repo; that is a separate cleanup, tracked in MAG-3389, not this gate's job.

### Aggregation, severity routing, and the fixer

The orchestrator parses each subagent's last `RESULT:` line. Four gates emit ADVISORY output alongside it:

| Gate | Advisory output | Feeds the fixer? |
|---|---|---|
| `cu-semantic` | Layer 1 out-of-band CU rows | **Yes**, as suggestions — apply only if clearly correct |
| `enabled` | WATCH-LIST rows | **No** — never auto-disable |
| `pruning` | `INFO: retention unknown` | No — treated as PASS, printed to user |
| `method-schema` | `check_stateful.sh` consensus rows | No — treated as PASS, printed to user; verify against the chain's docs before acting |

**All 9 PASS** → one-line summary, proceed to Phase 7.

**Any FAIL** → print the aggregated `=== GATE: <name> ===` sections, dispatch **one** `sonnet` fixer with the deduplicated FAIL list ("Apply EVERY listed fix in one pass. Do not touch any field not mentioned"), then re-run `jq`. `jq` non-zero → present snapshot + error + diff, **STOP**.

**The validators are not re-run after the fixer** (`SKILL.md:371`). Residual issues are caught by the Phase 9 reviewers and the Phase 11 final reviewer instead.

---

## Phase 7 — Final `jq` + removed-field gate

Two hard gates, both run inline without reading the spec body into the orchestrator's context.

**1. Syntax.** `jq . <chain>.json > /dev/null` and check the exit code. Non-zero (a fixer edit broke the file) → capture `jq . <chain>.json 2>&1 | head -n 20` and re-dispatch the Phase 6 fixer with the error.

**2. Removed fields.** `check_unused_fields.sh <chain>.json` — the same guard CI runs, here as a static gate before the expensive phases. Clean specs exit 0 with `RESULT: PASS (no removed fields)`. A non-zero exit prints one `REMOVED_FIELD | <file> | <json-path>` line per offender; the Phase 6 fixer deletes each reported field, then **both** checks re-run.

Do not proceed to Phase 7.5 until `jq` exits 0 **and** the guard passes. The canonical envelope — exactly `{ "proposal": { "specs": [ … ] } }`, with no `title`/`description`/`deposit` — is produced and enforced inside `spec-builder`, not here.

---

## Phase 7.5 — Endpoint discovery

Not a spec test — a *testability* test. It runs after the spec is resolved so it can enumerate requirements from the full import closure, including interfaces, ws subscriptions, and addons that were invisible at Phase 2/3. It exists because it produces Phase 8's inputs, and because `NOT_TESTABLE` classifications originate here.

**Requirement set** is derived dynamically via `jq` over the spec + resolved imports: interfaces, subscriptions (per interface), addons/extensions — for both mainnet and testnet indices.

**Per requirement**, walk a ranked source ladder and validate each candidate with the requirement's *real* call, not a casual ping (restricted public nodes answer naive calls but fail router boot):

| Requirement | URL form | Validation call |
|---|---|---|
| `jsonrpc` | `https://` | `eth_chainId` / `eth_blockNumber` |
| `rest` | `https://` | a known GET, e.g. `/cosmos/base/tendermint/v1beta1/blocks/latest` |
| `tendermintrpc` | `https://` | `/status` |
| `grpc` | `grpcs://host:port` (TLS) or `grpc://host:port` plaintext | `grpcurl … Service/GetNodeInfo` **direct** — the router's gRPC listener has no server reflection |
| subscription | `wss://…` (EVM), `wss://…/websocket` (tendermintrpc) | ws handshake expecting `101 Switching Protocols`, then a subscribe round-trip |
| addon/extension | inherits its interface's transport | a representative *enabled* method from that addon's own collection (archive → deep historical block; debug → `debug_traceBlockByNumber`) |

Plaintext gRPC needs **both** `grpc-config.allow-insecure: true` on the node-url entry **and** `--allow-insecure-provider-dialing` on the router; neither alone suffices, and a bare `host:port` is rejected outright.

Outputs a **keyed candidate list** (`{network, interface, kind, addon_name, url, transport, source_url, validation}`) and a **coverage matrix**. `NOT_TESTABLE` is legal only with the named sources checked *and* an empty-or-all-failed candidate list. It is a transparent gap, **not a spec defect and not a STOP** — it propagates verbatim into Phase 8, the PR body, and the Phase 12 checklist.

---

## Phase 8 — Smart-router boot + multi-node method probe

The heart of the pipeline's live testing. Boots the candidate spec inside `ghcr.io/magma-devs/smart-router:main` with `--use-static-spec` and relays to the chain's public RPC upstreams. **No lava node, no gov proposal, no provider/consumer `screen` sessions** — a boot is seconds to a minute.

Delegated entirely to one subagent. The orchestrator does not run docker, write the config, or probe — and explicitly must not debug boot failures by reading smart-router source, which is called out as "the single most expensive mistake in this phase" (`SKILL.md:440`).

**Preconditions.** Boot is mandatory whenever ≥1 node URL exists — even a single URL is worth booting, because startup spec resolution and upstream verification catch defects the static gates cannot see. Zero node URLs → **STOP and ask the user**; skipping requires explicit consent and is recorded in the Phase 12 checklist. The image is private; auth is handled by a pre-flight `docker login` in CI, and the subagent is forbidden from running `env`/`printenv`, reading `event.json`, or calling `docker login` itself.

### Step 1c — Addon & extension capability matrix

Runs **before** boot, hitting each upstream **directly** (the router isn't up yet). Inventory every distinct addon (`collection_data.add_on`) and extension name from the candidate and its parents, then for each `(addon, upstream)` pair:

- **Gated by a verification** → issue that verification's `function_template` at the node, walk `result_parsing.parser_arg`, compare to `expected_value` (e.g. `archive` → earliest block must be `0x0`), or type-check when there is no `expected_value`
- **No verification** → call the first method of that addon's collection with the simplest valid params. `-32601` → unsupported; `result` or `-32602` → supported

Result per pair: `SUPPORTED` / `UNSUPPORTED (code)` / `INCONCLUSIVE (timeout)`.

Only *supported* addons are written into the upstream's `addons:` config list. Adding an unsupported one would make its startup verification (severity `Fail`) exclude that provider from serving **everything**. An addon supported by zero upstreams → `NOT_TESTABLE`, left out of the config, carried to the report with per-upstream evidence.

### Step 3 — Boot readiness *is* a spec test

The router verifies every upstream at startup before it serves. A bad `result_parsing`, a wrong `chain-id` `expected_value`, or an unresolvable `imports` chain surfaces here — the signal this phase exists for.

Poll the listener for 120s; fail fast on `panic|fatal|failed to (load|expand|resolve) spec|all static providers failed verification|cannot serve endpoint|no matching spec` → `SMOKE: BOOT_FAILED`.

Deliberately **not** fail-fast: per-provider `failed verification on provider startup` and `ATTENTION: some static providers failed verification and were excluded`. The router still serves when ≥1 provider passes; those are classified in Step 3.5(c) instead of aborting.

**The most common boot failure is a config problem, not a spec defect:** if the spec enables any subscription method, *every* `direct-rpc` block needs a `ws://`/`wss://` URL alongside the https one. A provider without one fails verification and is excluded; once all are excluded the router exits with `all static providers failed verification — cannot serve endpoint` (plus `websocket is not provided in 'supported' map`). If the spec has subscriptions and no ws URL was supplied, the subagent must refuse to boot a doomed config and return `BOOT_FAILED` saying so.

Readiness differs per interface: `jsonrpc` → an HTTP response on 3360; `rest`/`tendermintrpc` → any HTTP status on a known GET path; `grpc` → a bare TCP connect.

### Step 3.5 — Parse-directive & verification runtime check

The authoritative test of the parse directives — stronger than Phase 6's offline curl+jq approximation, because the router's chain tracker *executes* them continuously against real upstreams. Run before the first probe, so the log window is pure tracker traffic.

**(a) Directive classification — two sources, fail-precedence.** Check the FAIL condition first; a positive applies only when neither source shows failure, so a healthy metric can never mask a real parse defect.

| Directive | FAIL if | else OK if | else |
|---|---|---|---|
| `PARSE_BLOCKNUM` | the `*_latest_block` gauge is `0`/absent, **or** a `PARSE_SIG` line names the `GET_BLOCKNUM` path | gauge > 0 (metric) **or** a `Chain Tracker Updated block hashes` line (log) | `NOT_EXERCISED` |
| `PARSE_BLOCK_BY_NUM` | `fetch_block_fails > 0` with `success == 0`, **or** a `ParseBlockHashFromReplyAndDecode` / `expected parsed hashes length` line | `fetch_block_success > 0` (metric) **or** ≥1 tracker hash-read line (log) | `NOT_EXERCISED` |

The metric-OR-log design is deliberate: `fetch_block_*` is currently **never emitted** by the router (`RecordBlockFetch` is only ever called with `isLatest=true`), so `PARSE_BLOCK_BY_NUM: OK` comes from the log today and would simply gain a second source if the router later wires the metric.

Metric names are matched **prefix-agnostically** — smart-router v1.0.4 (PR #138) dropped the `lava_` prefix, renaming `lava_rpcsmartrouter_latest_block` → `smartrouter_latest_block` and `lava_rpc_endpoint_*` → `rpc_endpoint_*`. The grep's `(lava_)?` and `(rpcsmartrouter|smartrouter)` alternations match both so the check never silently falls through to the log-only path because of the rename.

A few `fetch_latest_fails` alongside a healthy `latest_block` is transient endpoint noise, not a defect.

**Slot-based chains (Solana, Beacon):** `GET_BLOCK_BY_NUM` returns 404/not-found whenever the tracker walks onto an empty slot (~1% of slots). With a *single* upstream, retries there can drive that provider below the routing threshold and produce "No pairings available" — a deployment artifact, **not** a directive defect. If the tracker read *any* by-number hash before the empty slot, `PARSE_BLOCK_BY_NUM` is **OK** and the degradation is reported as a `SINGLE_UPSTREAM` note. A genuine FAIL fires on non-empty slots too. Do **not** rewrite the `%d` template to `finalized`/`latest` — that breaks the per-slot walk.

**(b) Parse-signature log grep.** These come from `endpoint_chain_fetcher.go` / `parser.go` and are mostly **DEBUG level**, which is why the router is booted with `--log-level debug` — the Step 4.5 warn/error scan can never see them:

```
failed to parse response | failed formatResponseForParsing |
failed ParseBlockHashFromReplyAndDecode | failed CraftChainMessage |
Failed parsing default value | blockParsing -  | expected parsed hashes length |
tried decoding a hex response | failed to parse generic parser path |
failed to unmarshal result
```

Interpretation matters: `blockParsing - rpcInput is error` means the *upstream* returned an RPC error, not a directive defect. The metrics/log verdict in (a) is the gate; these lines are the diagnosis.

**(c) Verification scan.** Every spec verification executes per provider at startup. A verification that fails on *some* providers does **not** fail the boot — the router just excludes them and serves with the rest — so without this scan the defect passes silently.

| Outcome | Verdict | Is it a spec defect? |
|---|---|---|
| Succeeds on every provider | **OK** | — |
| Fails on **every** provider (router still boots via another collection/interface) | **FAIL** | Yes — wrong directive or `expected_value` |
| Fails on **some** providers | **PARTIAL** | No — upstream capability (e.g. a pruned node failing `pruning`'s `latest_distance`). Record which upstream was excluded; later probes only exercise the survivors |
| `Bad verification definition` | **FAIL** | Yes, always — the verification references a `function_tag` with no matching `parse_directives` entry |
| Appears in neither success nor failure lines | **NOT_EXERCISED** | Only legitimate when no upstream supports the gating addon — cross-check the Step 1c matrix |

`PARSE_BLOCKNUM: FAIL` is "a spec defect of the highest order" — the router cannot track the chain. The run still continues to Step 4 so the report is complete, but `PARSE: FAIL` must surface.

### Step 4 — Method-probe loop

Every API in every collection, sent **through the router** at `localhost:3360` — never directly to the upstream. In production all traffic flows through the router, so this is the only representative path; a direct-to-node call would hide spec-level parse and result-directive bugs.

| Category | Action |
|---|---|
| `category.stateful: 1` | **SKIP** — "would broadcast transaction" |
| `category.subscription: true` | WebSocket to the router, subscribe with sample params, **wait up to 30s for ≥1 message**, unsubscribe. PASS = ≥1 message; FAIL = timeout |
| everything else | simplest valid call from `block_parsing` + `parse_directive` hints, POSTed (jsonrpc/tendermintrpc) or GET (rest) |

**Extensions** get one representative call with the extension header, e.g. `-H "lava-extension: archive"` on a historical-block query. `no chain proxy supporting requested extensions` despite a supporting upstream → `TESTED_FAIL`.

**Response classification:**

| Response | Verdict |
|---|---|
| `result` field, any value including empty | **PASS** |
| `error.code == -32601` | **FAIL** — method absent / not routed |
| `error.code == -32602` (invalid params) | **PASS-existence** — method exists |
| any other `error.code` | **WARN** (record code + message) |
| no response in 10s | **TIMEOUT** |
| upstreams return materially different shapes | **WARN-DISAGREEMENT** — repeat the call a few times to surface it |

Two guards keep probe-setup artifacts out of the fix list:

- **Live-input resolution.** Resolve real values (latest block number + hash, current round/height, a recent tx hash, a well-known address) *before* the loop. **Never probe a method taking a block/round/height/hash/address with a hardcoded placeholder** like `1`, `0x1`, or a zero hash. An Algorand stateproof call fails at round 1 and passes at a valid recent round — that is a probe bug, not a missing method.
- **Re-probe-once gate.** Any FAIL/WARN/TIMEOUT on a method that takes *any* input argument must be re-probed once with freshly resolved live inputs. Only a failure that **survives** the re-probe is recorded. `-32601` is input-independent and exempt.

**gRPC caveat:** the router's gRPC listener exposes no server reflection, so `grpcurl`-through-the-router is impossible. Boot, verifications, and chain tracking go *through* the router and prove routing works; per-method gRPC probes hit the upstream directly and **must be labelled direct-upstream** in the report — they are not through-router method coverage.

### Step 4.5 — Probe-window log scan

Step 4 sees only the HTTP reply. The router can return a plausible-looking body while logging a spec-level error the classification misses. Slice the log from the pre-probe offset `P0`, keep `warn|error|fatal|panic`, and drop a benign allow-list:

`self signed certificate` · `x509` · `OTel` · `:4318` · `chain tracker` / `ChainTracker` / `UNKNOWN_BLOCK` / `DB Not Found` / `failed fetching data from the node` · `WebSocket SendRequest not implemented`

The chain-tracker entries are safe to allow-list *here* only because directive-level parse failures are caught separately by Step 3.5, which this filter cannot mask.

Surviving lines: method-associated → downgrade that method to at least **WARN** (but keep FAIL if Step 4 already classified it FAIL on the same `-32601` — don't double-count); router-wide → "Log-scan findings" section; `fatal`/`panic` after a successful boot → a runtime crash during probing, flag prominently, the run is unreliable.

### Step 7 — Testnet verification pass

Boot + Step 3.5 only — **no method probe**. Separate container on ports `3460:3360` / `7879:7779` with `chain-id: <TESTNET_INDEX>`.

This exists because the testnet entry thin-inherits mainnet, and its overrides — above all the testnet `chain-id` `expected_value`, often set by convention rather than live-verified — are exercised by **nothing else in the pipeline**. Skipped only when no testnet index or node URL was supplied, or when the spec has subscriptions and no testnet ws URL exists (don't boot a doomed config).

`TESTNET_VERIFY: FAIL` is a spec defect of the same severity as a mainnet `VERIFY: FAIL` → CRITICAL into Phases 9 and 10. `SKIPPED` means the testnet entry shipped with no live verification at all — surfaced prominently in the PR body and Phase 12 checklist.

### Step 8 — Empirical block time

Direct RPC, both networks. EVM recipe: 100-block timestamp delta ÷ 100. Other families adapt (cosmos → `/block` header timestamps; solana → `getBlockTime` deltas; substrate → `chain_getBlock`); no recipe → "skipped: no recipe for `<family>`".

Compared against each network's **effective** `average_block_time` — the testnet inherits mainnet's via `imports` unless it declares its own. Deviation > 20% → `BLOCK_TIME_MISMATCH (<network>)`.

- **Testnet mismatch** → Phase 10 fix item: set an explicit `average_block_time` override in the testnet entry and recompute its derived params (`allowed_block_lag_for_qos_sync`, finalization fields).
- **Mainnet mismatch** should not happen — Phase 4 already locked the value against empirical data. If it appears, MEDIUM severity and re-check the Phase 4 inputs.

The subagent does not edit the spec; the orchestrator decides the fix.

### What Phase 8 returns

`PARSE:` · `VERIFY:` · `ADDONS: <n> tested-ok / <n> failed / <n> not-testable` + table · `PASS/FAIL/SKIP/WARN/TIMEOUT/LOG_WARN` counts · FAIL/TIMEOUT method names · `TESTNET_VERIFY:` · `BLOCK_TIME:` · teardown status · path to `docs/<chain>/METHOD_PROBE_REPORT.md`. The full report is **not** echoed back — the orchestrator reads it from disk if it needs detail.

---

## Phase 9 — Parallel reviewers

Three fresh subagents, each running `/review-spec` on the candidate, `sonnet` by default.

**No worktree isolation.** `git worktree add` checks out HEAD, and this skill never commits — a reviewer in a worktree would review the previously-committed (stale) spec and emit phantom CRITICALs with line references outside the real file. Anchoring isolation comes from fresh subagent context alone.

Each reviewer first reads `docs/<chain>/METHOD_PROBE_REPORT.md` and folds the probe findings (especially FAIL and WARN) into its review, then runs the 9-phase `/review-spec` audit:

| # | `/review-spec` phase | Checks |
|---|---|---|
| 1 | Identify API provider | `api_interface`, imports, number of spec entries |
| 2 | Network parameters | the same formula table as Phase 6's `chain-metadata` gate |
| 3 | API completeness | diff spec paths vs supplied API docs; classify each missing endpoint as intentional or a gap |
| 4 | Method-by-method | **4a** `block_parsing` parser_func vs actual API behavior · **4b** category flags (`deterministic`, `local`, `subscription`, `stateful`, `hanging_api`) · **4c** compute units vs the CU table |
| 5 | Parse directives | `GET_BLOCKNUM`, `GET_BLOCK_BY_NUM` required; `GET_EARLIEST_BLOCK` if archive; SUBSCRIBE/UNSUBSCRIBE if ws. Template, `result_parsing`, and `api_name` existence |
| 6 | Verifications | `chain-id` `expected_value`; `pruning` present and referencing `GET_EARLIEST_BLOCK` |
| 7 | Collection inheritance | child-overrides-parent semantics; **empty `headers: []` / `verifications: []` / `extensions: []` in a child OVERRIDE the parent's values** — a common bug source |
| 8 | Headers | REST auth headers with `pass_send`; content-type overrides that don't break sibling endpoints |
| 9 | Live testing | only if a credentials path was passed |

Rules corpus: `.claude/skills/review-spec/SPEC_GUIDE.md` (2226 lines), which each reviewer full-reads to a sentinel before starting.

**Three settled decisions are excluded from findings** in both Phase 9 and Phase 11, so reviewers don't re-litigate skill policy:

1. `deposit` is `"10000000ulava"`
2. `blocks_in_finalization_proof` is finality-typed (see the Phase 6 note)
3. A probe returning `-32601`/errors never justifies disabling — see invariant 1

**Output handling.** `/review-spec` writes to a hard-coded path, so each reviewer immediately `mv -n`s it to `SPEC_REVIEW_GAPS_parallel_N.md` (no-clobber, verified, one retry on collision) and returns only that path plus `TALLY: CRITICAL=<X> MEDIUM=<Y> MINOR=<Z>` — never the report body, which would defeat the Phase 10 consolidation by pulling all three reports into the orchestrator's context.

**Two post-collection checks:** an unparseable TALLY aborts the phase naming the reviewer; a missing file means the rename raced, and just that reviewer is re-dispatched sequentially. If any CRITICAL cites an `evidence_line_number` beyond `wc -l <chain>.json`, that reviewer reviewed stale state — re-dispatch it, or downgrade its findings to advisory.

---

## Phase 10 — Consolidation + single fix pass

Not a test, but it decides what changes between the two probe runs, so it belongs in the chain of custody.

A consolidation subagent reads the three review reports plus the probe report from disk, deduplicates CRITICAL + MEDIUM gaps keyed by `(gap_title, evidence_line_number)`, drops MINOR, applies the **disable-suggestion filter** (invariant 1), and writes `docs/<chain>/FIX_LIST.md`, returning only `N critical, M medium; K disable-suggestions stripped`.

The spec is snapshotted to `/tmp/spec_<chain>_pre_fix.json` before a `sonnet` fixer applies every listed fix in one pass, touching nothing outside the gap list. Then `jq` again — non-zero → outcome `BROKEN_AFTER_FIX`, present the snapshot path, error, and diff, **STOP**.

---

## Phase 10b — Smoke regression test

Re-boots the router against the **fixed** spec and re-probes a deterministic minimal set. Skipped only if Phase 8 was skipped.

> **Different image tag.** Phase 10b boots `ghcr.io/magma-devs/smart-router:**latest**` (`smart-router-smoke-tester.md:26`), while Phase 8 boots `:**main**` (`smart-router-tester.md:45`). This is why both phases grep metrics prefix-agnostically — the two tags may emit different metric names. It also means 10b is not a strictly identical re-run of 8.

The prompt explicitly forbids reasoning about whether the Phase 10 change was "purely a CU update" or "small enough to skip re-booting" — **always re-boot and re-probe**.

**Step 1.5** repeats Phase 8 Step 3.5 in full (parse directives + verification scan) against the fixed spec.

**Step 2 — the fixed 7-item probe set**, in order:

1. `GET_BLOCKNUM` parse directive
2. `chain-id` verification, response matched against the spec's `expected_value`
3. **5 sampled read methods** — deterministically the first 5 non-stateful, non-subscription APIs alphabetically from the largest collection

Plus one probe per addon/extension that was `TESTED_OK` in Phase 8 (read from the Phase 8 report's coverage table). `NOT_TESTABLE` items stay unprobed and are carried forward unchanged. The Phase 8 config already carries the `addons:` entries — they must not be stripped when regenerating it.

**Step 3 — regression comparison** against the Phase 8 report:

| Phase 8 → Phase 10b | Result |
|---|---|
| PASS → FAIL or TIMEOUT | **REGRESSION** |
| `TESTED_OK` addon → probe FAIL | **REGRESSION** |
| `PARSE: OK` / `VERIFY: OK` → now FAIL | **REGRESSION** |
| PASS → non-benign router `error` mapped to that method, even with an acceptable response body | **REGRESSION** |
| `fatal`/`panic` after boot | **REGRESSION** |
| FAIL/WARN/TIMEOUT → PASS | improvement; recorded, no alert |

Returns `SMOKE: OK` (proceed to Phase 11) · `SMOKE: REGRESSION` (probe table + which probes regressed + the most plausible culprit from the Phase 10 fix list → **STOP**) · `SMOKE: BOOT_FAILED` (log excerpt → **STOP**). The subagent does not fix regressions; the orchestrator decides.

---

## Phase 11 — Final reviewer

One `sonnet` subagent in clean context, again with no worktree, for the same stale-HEAD reason as Phase 9.

Prior reports are archived to `docs/<chain>/_archive/` first, and any stale un-suffixed `SPEC_REVIEW_GAPS.md` is removed, so the reviewer's `/review-spec` (whose Phase 1 scans `docs/<CHAIN_NAME>/`) cannot anchor on them.

Same `/review-spec` audit and same three settled-decision exclusions as Phase 9, **plus one check unique to this phase**: enumerate every `enabled: false` api/collection with `jq` and confirm each has a positive-evidence row (docs-explicit or client-source, with URL) in the **Disabled-API Justifications PR comment** (read via `gh pr view --json comments`, falling back to the ledger carried in the PR body). **Any disabled entry without one is a CRITICAL finding.**

Unlike Phase 9, this reviewer returns the **full report body** plus its TALLY.

| TALLY | Outcome |
|---|---|
| `CRITICAL=0 MEDIUM=0` | **APPROVED** → Phase 12 |
| any CRITICAL or MEDIUM remaining | **CHANGES REQUESTED** → present the report, **STOP, do not loop**, skip Phase 12 |

The no-loop rule is deliberate — it avoids the `/review-and-fix-spec` "max-loops-exit-without-converging" failure mode.

The same stale-line sanity check as Phase 9 applies: an `evidence_line_number` beyond the file's line count means stale state; re-dispatch once.

---

## Phase 12 — Coverage ledger: what is and isn't verified

Phase 12 prints a checklist annotated `✓` verified / `~` partial / `☐` user-to-handle, downgrading items to `☐` for any skipped phase. The honest reading of it:

### Verified by the pipeline

| Item | Evidence |
|---|---|
| JSON syntax valid | Phase 7 `jq` |
| Required fields present, no duplicate API names | Phase 6 gates 3 and 9 |
| Network params match the formulas | Phase 6 gate 3 + Phase 4 calc table |
| Parse directives executed by a live router | Phase 8 Step 3.5; re-checked at Phase 10b |
| Verifications pass on live nodes | Phase 6 chain-id curl + Phase 8 boot-window scan |
| Chain IDs verified for mainnet **and** testnet | Phase 6 dual curl + Phase 8 Steps 3.5 and 7 |
| Mainnet + testnet entries complete, testnet inherits correctly | Phase 7 write + Phase 11 reviewer |

### Partially verified

| Item | What's missing |
|---|---|
| "All APIs tested and working" | **stateful methods are skipped entirely** — never probed |
| "Block parsing validated for each API" | existence-tested only; full per-API parse validation needs production traffic |
| Addons & extensions tested | `NOT_TESTABLE` items need a supporting node to verify at all |
| Both networks tested | testnet gets boot + verifications only (Step 7), **no method probe** |

### Not tested at all

| Gap | Why |
|---|---|
| **`hanging_api` → `timeout_ms`** | no validator covers it; Phase 6 hand-check only |
| **`category.stateful` direction** | no validator enforces it; Phase 6 hand-check only. *(Derived consequence, not stated in the sources: because Step 4 skips `stateful: 1` unconditionally, a read method wrongly marked stateful is also never probed — the two gaps compound.)* |
| **gRPC methods through the router** | the gRPC listener has no server reflection; probes are direct-upstream and labelled as such |
| **Compute units under load** | benchmarking is a manual `☐` item |
| **Economic parameters** | no longer part of the model (removed in smart-router#218); the removed-field guard now rejects them outright |
| **CU uniformity** | deliberately not a check — uniform CU is legitimate |
| Documentation and governance-proposal content | out of skill scope |

Phase 12 closes with `scripts/run_stats.sh <start_epoch>`, which parses real `usage` blocks from this session's transcript plus every subagent transcript — actual token consumption, not an estimate — scoped to the run window recorded in Phase 1.

---

## Appendix A — Stop conditions, collected

Every point where the pipeline halts rather than degrading:

| Phase | Condition | Behavior |
|---|---|---|
| 3 | archive-researcher `status: NEEDS_HUMAN_DECISION` | STOP, quote conflicts, ask the user for 4 explicit decisions |
| 4 | spec-builder returns `SPEC: BLOCKED` | STOP |
| 6 | archive/pruning/`GET_EARLIEST_BLOCK` triplet mixed | STOP |
| 6 | `jq` invalid after the fixer | STOP with snapshot + error + diff |
| 1A | A4 gate: removed-field **or** preservation guard fails | STOP; fix the testnet block. Do not proceed with a modified file |
| 7 | `jq` exit ≠ 0, **or** removed-field guard fails | Dispatch fixer; do not advance until both pass |
| 8 | Zero node URLs available | STOP and ask the user; skipping requires explicit consent |
| 8 | `SMOKE: BOOT_FAILED` | STOP, no Phase 9 |
| 8 | Spec has subscriptions but no ws/wss URL | Refuse to boot; return `BOOT_FAILED` naming the cause |
| 9 | TALLY missing or unparseable | Abort, name the reviewer |
| 10 | `jq` invalid after fix (`BROKEN_AFTER_FIX`) | STOP, no Phase 10b |
| 10b | `SMOKE: REGRESSION` or `BOOT_FAILED` | STOP, no Phase 11 |
| 11 | Any CRITICAL or MEDIUM remains | CHANGES REQUESTED, STOP, no loop, skip Phase 12 |

---

## Appendix B — Self-tests of the skill's own tooling

Distinct from everything above: these test the **check scripts themselves**, not any chain spec. They are not part of a spec-creation run and are executed manually.

Most `scripts/test_<name>.sh` drive their `check_<name>.sh` against fixtures in `scripts/fixtures/` and assert three things: the good fixture yields `RESULT: PASS` / exit 0; the bad fixture yields exit 1 *with the specific FAIL rows named*; and any edge case behaves as designed (e.g. `check_pruning.sh` with `unknown` retention must emit `INFO: retention unknown` and still PASS, because missing research data must never block). Each ends with `ALL TESTS PASSED`.

`test_run_stats.sh` is the exception — it has no fixture file. It synthesizes a temporary transcript directory of JSONL `usage` lines and asserts start-epoch window filtering, main-vs-subagent token summation, elapsed derivation, the per-model breakdown, and exit codes `2` (bad arg) and `1` (missing dir).

Run them all from the repo root:

```bash
for t in .claude/skills/create-spec/scripts/test_*.sh; do
  printf '%-40s ' "$(basename $t)"
  bash "$t" >/dev/null 2>&1 && echo PASS || echo FAIL
done
```

> **The suite requires bash ≥ 4.** Stock macOS `/bin/bash` is 3.2 and fails 7 of the 16 for reasons that have nothing to do with awk: `declare -A` in `compare_spec_methods.sh`, `compare_spec_directives.sh`, and `check_directive_presence.sh`, `check_hanging_api.sh`, and `check_stateful.sh`, and the empty-array `"${arr[@]}"`-under-`set -u` expansion in `check_extensions.sh` and `check_method_schema.sh`. Run under Homebrew bash (or any bash ≥ 4.4) before concluding anything is broken.

### Suite status

All 16 pass, verified 2026-09-02 on darwin under both BSD awk (`version 20200816`) and GNU Awk 5.4.0.

| Test | Covers |
|---|---|
| `test_check_network_params.sh` | `check_network_params.sh` |
| `test_check_verifications.sh` | `check_verifications.sh` |
| `test_check_extensions.sh` | `check_extensions.sh` |
| `test_check_method_schema.sh` | `check_method_schema.sh` |
| `test_check_hanging_api.sh` | `check_hanging_api.sh` |
| `test_check_stateful.sh` | `check_stateful.sh` |
| `test_check_pruning.sh` | `check_pruning.sh` |
| `test_check_archive_value.sh` | `check_archive_value.sh` |
| `test_check_directive_presence.sh` | `check_directive_presence.sh` |
| `test_check_unused_fields.sh` | `check_unused_fields.sh` |
| `test_check_preservation.sh` | `check_preservation.sh` |
| `test_compare_spec_methods.sh` | `compare_spec_methods.sh` |
| `test_compare_spec_directives.sh` | `compare_spec_directives.sh` |
| `test_run_stats.sh` | `run_stats.sh` |
| `test_check_disabled_count.sh` | `check_disabled_count.sh` |
| `test_check_internal_paths.sh` | `check_internal_paths.sh` |

### Fixed: two macOS portability defects (2026-08-04)

Both were found by running this suite on darwin; both were invisible on CI's Linux runner.

1. **`compare_spec_methods.sh` produced no diff at all under BSD awk** — and it backs Phase 6 gate 1 (`methods-coverage`), so that gate could not work on a macOS runner. The script passed the newline-separated method list through `awk -F'\t' -v wanted="$WANTED"`; BSD awk rejects a literal newline inside a `-v` assignment (`awk: newline in string … at source line 1`) while GNU awk accepts it, so it failed for any list longer than one line — i.e. always in real use.

   **Fix:** the list is written to a temp file (`mktemp`, removed by an `EXIT` trap) and awk reads it in `BEGIN` via `getline`. That is POSIX awk, so it behaves identically on BSD awk, gawk, and mawk, and it preserves list order — which the `PRESENT` and `MISSING` sections rely on. The now-unreachable `m == ""` guards went away with the `split()` they defended.

2. **`test_run_stats.sh` used GNU-only `date -d`**, which BSD `date` rejects. This was the *test* being non-portable; `run_stats.sh` itself contains no GNU-only constructs. **Fix:** the threshold is the literal epoch `1767227400`, matching the hardcoded fixture timestamps it is compared against.

`compare_spec_directives.sh` builds its comparison in bash associative arrays rather than awk and was never affected.
