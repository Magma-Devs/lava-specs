# What `create-spec` tests

Every check the agent runs against a chain spec, in the order it runs them. Self-contained: everything
needed to read a pipeline result is on this page.

The pipeline runs 12 phases; the ones below are the ones that verify. They run cheapest-first, so a docker
boot is only paid for once the offline gates are clean.

**Not every spec has this trail.** Only spec files onboarded or reworked *through* the pipeline carry the
evidence described here; most of those at the repo root predate it entirely. CI can also be
started mid-pipeline (`Start at Phase N`, N ∈ {8,9,10,11}), skipping 1–7 and reconstructing from the
committed file, and a mechanical-only PR — a field rename across five specs, say — may legitimately have no
Phase 8 at all. A merged spec has not necessarily passed everything here. To tell: find the PR that
introduced the spec (`git log --oneline -5 -- <chain>.json`) and look for `magmadevs-bot` comments. None
means no recorded testing.

---

## The order it runs in

| Phase | What runs | What it proves | If it fails |
|---|---|---|---|
| **6 pre-flight** | Orchestrator, inline | Live chain-id curl (mainnet **and** testnet); index/`name`/`enabled` sanity; archive ↔ pruning ↔ `GET_EARLIEST_BLOCK` triplet all-present-or-all-absent | Mixed triplet → **STOP** |
| **6 gates** | 9 static gates, parallel subagents | The file is internally consistent and matches research (see below) | Any `FAIL` → **one** fixer pass, then straight on. Gates are **not** re-run — Phases 9/11 are the backstop |
| **7** | `jq` + removed-field guard | Valid JSON; none of the 15 fields deleted from the smart-router model (nine governance fields, `title`/`description`, `deposit`, `extra_compute_units`, `category.local`, `category.subscription`) | Either fails → fixer; **no progress** until both pass |
| **7.5** | Endpoint discovery | A real validated upstream exists for every interface, subscription and addon the spec declares — *including inherited ones* | `NOT_TESTABLE` is a transparent gap, never a stop |
| **8** | Dockerized smart-router boot + live probe (`smart-router:main`, `--use-static-spec`) | The spec actually works against real nodes | `BOOT_FAILED` → **STOP**. `PARSE`/`VERIFY`/`TESTNET_VERIFY: FAIL` → carried into 9/10 as CRITICAL |
| **9** | 3 parallel reviewers | Three independent audits, each having read the probe report | Missing `TALLY` → abort |
| **10** | Consolidate gaps → **one** fix pass | Dedup, drop MINOR, strip probe-only disable suggestions | `jq` broken after fix → **STOP** |
| **10b** | Smoke re-boot (`smart-router:latest`) + 7-item re-probe | The fix broke nothing | `REGRESSION`/`BOOT_FAILED` → **STOP** |
| **11** | Final reviewer, clean context, prior reports archived | A fourth pass re-derived from the file alone | Any CRITICAL or MEDIUM → **CHANGES REQUESTED**, no retry loop |
| **12** | Coverage checklist + run stats | Reporting only | No gate |

Phases 1–5 build the spec. Their only stop is the builder's refuse-to-write gate (`SPEC: BLOCKED`), which
fires before any test runs.

---

## The 9 static gates (Phase 6)

1. **methods-coverage** — every method research found is in the spec or its transitive imports. Unjustified `MISSING` → FAIL; `EXTRA IN SPEC` is informational.
2. **parse-directive** — three layers. **L1:** `GET_BLOCKNUM` present across the candidate *plus all parents* (hard-required; `GET_BLOCK_BY_NUM` absent is an `INFO` line and passes — that selects head-only tracking, correct for a chain with no blocks); `GET_BLOCK_BY_NUM` template carries `%d`/`%x`; it extracts a real block identifier, not the echoed slot number; template/`parser_func`/`parser_arg` match the canonical matrix for `(interface, family)`. **L2:** directives match the upstream template by `tag|api|sha256`. **L3:** each directive issued at a live RPC parses to the right type, `GET_BLOCK_BY_NUM` still resolves when fed the number `GET_BLOCKNUM` just returned (counter chaining), and a `rest` + `PARSE_CANONICAL` body is an object, not a top-level array.
3. **chain-metadata** — `average_block_time` non-zero, `block_distance_for_finalized_data` present, `blocks_in_finalization_proof` ∈ {1, 3, `max(ceil(1000/abt),3)`}, `allowed_block_lag_for_qos_sync` = `ceil(10000/abt)`.
4. **verifications** — each has a `name`, non-empty `values[]`, a valid `severity`; every `parse_directive.function_tag` resolves inside its own collection.
5. **extensions** — every extension has a `cu_multiplier`; `archive` has `rule.block`; every addon collection has ≥1 verification; no duplicate extension names.
6. **cu-semantic** — hard rule: subscribe = exactly `1000` CU, unsubscribe = exactly `10`. Everything else is an advisory band (tx-submit 10–40, simulate 40–60, heavy 60–200, state-read 10–20) and never fails the gate. Uniform CU across methods is **not** a defect.
7. **pruning** — `archive.rule.block` and `pruning.latest_distance` within 3× of researched retention (`unknown` → INFO + pass); archive-tier `expected_value` is a base-10 integer on the path the router `ParseInt`s (a `"*"` there excludes the archive provider at boot).
8. **enabled** — advisory watch-list of still-enabled methods research called unsupported. **Always PASS**; never auto-disables.
9. **method-schema** — per API: `enabled`, `compute_units`, `block_parsing`, `category` present; `parser_arg` all strings; no duplicate API names in a collection.

---

## The live tests (Phase 8 — the core)

- **Addon capability matrix** — each addon/extension probed **direct to each node** before boot, so only genuinely supported ones enter the router config.
- **Boot** — the spec loads, `imports` resolve, upstreams pass startup verification. A wrong `chain-id`, a broken `result_parsing`, an unresolvable import chain all surface here.
- **`PARSE_BLOCKNUM` / `PARSE_BLOCK_BY_NUM`** — the chain tracker *executes* the directives against real nodes; verdict from router metrics **or** tracker logs, with a failure from either winning. A `PARSE_BLOCKNUM` failure is the most severe defect possible: the router cannot track the chain.
- **Verification runtime scan** — every spec verification runs per provider at boot. This is the only place `GET_EARLIEST_BLOCK`/`pruning` ever executes. Failing on *every* provider is a spec defect; failing on *some* is an upstream capability issue.
- **Method probe loop** — every API relayed **through the router**, never direct. Inputs are resolved live (never a hardcoded `0x1`), and any first-attempt failure on a parameterized method is re-probed once before it counts. HTTP 429 is never a verdict — the method becomes `UNPROBED`, not `FAIL`.
- **Subscriptions** — WebSocket subscribe → ≥1 message within 30s → unsubscribe.
- **Extensions** — one `lava-extension: archive` call routed through the router.
- **Probe-window log scan** — catches router errors hidden behind a plausible-looking response body.
- **Testnet pass** — boot + verifications against the testnet entry, **no method probe**. The only place the testnet `chain-id` is ever live-checked.
- **Empirical block time** — measured on both networks; >20% off the spec's effective value → `BLOCK_TIME_MISMATCH`.

## The reviews (Phases 9 and 11)

Each reviewer runs a 9-part audit — provider identification, network params, API completeness,
method-by-method (block parsing / category flags / CU), parse directives, verifications, inheritance,
headers, live tests — after reading the probe report. Phase 9 runs three in parallel and feeds CRITICAL +
MEDIUM into the fix pass (MINOR is dropped). Phase 11 runs a fourth with prior reports archived so they
cannot anchor it, and additionally audits that **every `enabled: false` entry has a positive-evidence row
with a URL** in the Disabled-API Justifications PR comment. `CRITICAL=0 MEDIUM=0` = approved; anything else
stops the run.

## Add-testnet mode

Appending a testnet to an existing chain skips Phases 2–7 entirely and jumps to 7.5 → 8, scoped to the new
testnet. Its single gate is **A4**: valid JSON + the removed-field guard + the preservation guard, the last
of which fails unless the *only* change is the added testnet index and every pre-existing spec is
canonical-identical to `main`. The mainnet is byte-for-byte unchanged and is not re-probed. ⚠️ The
preservation guard **self-skips** if it isn't on the PR branch — CI logs a `::notice::` and exits 0, so a
skip reads as a pass.

---

## Reading the verdicts

| Verdict | Meaning |
|---|---|
| `PASS` | Returned a `result` field |
| `PASS-existence` | `-32602 invalid params` — method exists, the probe lacked valid args. **Counts as a pass** |
| `FAIL` | `-32601 method not found` — absent or not routed |
| `WARN` | Some other error code |
| `TIMEOUT` | No response in 10s |
| `SKIP` | `stateful: 1` — would broadcast a transaction, deliberately never probed |
| `UNPROBED` | Never probed (rate limit, budget). **Not** coverage — "we don't know" |
| `PARTIAL` | Failed on *some* providers — that upstream lacks the capability |
| `NOT_TESTABLE` | No supplied node supports it at all |
| `NOT_EXERCISED` | Never ran |
| `TESTED_OK` / `TESTED_FAIL` | Addon verified / addon failed despite a supporting upstream |
| `SINGLE_UPSTREAM` | Degraded because only one node was supplied |
| `WARN-DISAGREEMENT` | Upstreams returned materially different shapes for the same method |

---

## What is never tested

| Not covered | Why |
|---|---|
| Stateful / broadcast methods | Always `SKIP` — probing would move funds. Test on a funded testnet if it matters. |
| gRPC through the router | The router's gRPC listener has no server reflection, so those probes go **direct to upstream**. Rows are labelled as such — they are not through-router coverage. |
| Testnet method coverage | The testnet gets boot + verifications only. No method probe, ever. |
| Compute units under load | Never benchmarked. CU is assigned by semantic band, not measurement. |
| Per-API block parsing, fully | Existence-tested only; full validation needs production traffic. |

Two checks **no validator covers** — they are the reviewer's job:

```bash
# hanging_api without timeout_ms — output must be empty
jq -r '.proposal.specs[].api_collections[].apis[]
       | select(.category.hanging_api == true and (.timeout_ms // null) == null) | .name' <chain>.json

# every stateful method — each should be a broadcast/submit call
jq -r '.proposal.specs[].api_collections[].apis[]
       | select(.category.stateful == 1) | .name' <chain>.json
```

---

## The rule that catches people out

**A probe error never justifies disabling a method.** The pipeline probes free-tier public nodes only, so a
`-32601`, `501`, `429` or timeout may prove nothing more than that the free tier lacks it. `enabled: false`
is legal only with *positive* evidence — official docs saying unsupported/removed, or the node client not
implementing it, **with a URL** — recorded in the Disabled-API Justifications PR comment. Three separate
checks enforce this: the `enabled` gate, Phase 10's disable-suggestion filter, and Phase 11's ledger audit.

## Where the evidence lives

The pipeline writes its reports to `docs/<chain>/`, which is **gitignored** — those files exist only on the
machine that ran it. A spec's durable test record is the set of `magmadevs-bot` comments on the PR that
introduced it, and the disabled-API ledger is a PR comment, not a file. The PR *body* is the input (human
brief, endpoints, known gotchas); the bot *comments* are the results, one per phase.

```bash
gh pr view <N> --json comments --jq '.comments[].body' \
  | grep -E 'PARSE:|VERIFY:|TESTNET_VERIFY:|ADDONS:|TALLY:|PASS=[0-9]'
```

## Red flags

| Red flag | Why it matters |
|---|---|
| `TESTNET_VERIFY: SKIPPED` | The testnet entry shipped with **zero** live verification |
| `PARSE:` or `VERIFY: FAIL` still present at Phase 11 | A known defect survived the fix pass |
| Phase 11 said CHANGES REQUESTED but the PR merged | Someone overrode the gate — find out why |
| `enabled: false` with no ledger row | Phase 11's audit should have caught it as CRITICAL |
| `ADDONS: … not-testable` with no follow-up | Nobody ever verified that addon |
| `BLOCK_TIME_MISMATCH` on **mainnet** | Should be impossible — an input was wrong |
| A Phase 10 gap "resolved against the reviewers" | A human overrode a reviewer's CRITICAL |
| Add-testnet PR with no preservation-guard line in the log | The guard may have self-skipped |
| No bot comments at all | The spec predates the pipeline — there is no recorded testing |
