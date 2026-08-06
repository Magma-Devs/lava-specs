# QA guide — every test a chain spec receives

For the QA engineer picking up a chain spec and asking: *what was actually tested, what wasn't, and what do I still need to check myself?*

The master table in §3 lists **every check the pipeline runs**, in order. Everything else in this document supports reading it.

Deeper mechanics: [`.claude/skills/create-spec/TESTING.md`](.claude/skills/create-spec/TESTING.md).

---

## 1. First: the evidence is in the PR, not the repo

The pipeline writes its reports to `docs/<chain>/`. **`docs/` is gitignored** (`.gitignore:3` — "transient run outputs, never committed"). Those files exist only on the machine that ran the pipeline. They are not in your checkout.

> **A spec's durable test record is the set of `magmadevs-bot` comments on the PR that introduced or changed it.**

The same applies to the disabled-API ledger — it is a **PR comment** titled "Disabled-API Justifications", not a file.

```bash
git log --oneline -5 -- sui.json                    # which PR touched this spec?
gh pr view 103 --json body,comments                 # the whole evidence trail

# just the headline verdicts
gh pr view 103 --json comments --jq '.comments[].body' \
  | grep -E 'PARSE:|VERIFY:|TESTNET_VERIFY:|ADDONS:|TALLY:|PASS=[0-9]'
```

The PR **body** is the *input* (human brief, endpoint routing, known gotchas) — not results. The **bot comments** are the results, one per phase.

---

## 2. How to read the Verdict column

| Verdict | Meaning |
|---|---|
| `PASS` | Returned a `result` field |
| `PASS-existence` | `-32602 invalid params` — method exists, probe lacked valid args. **Counts as a pass** |
| `FAIL` | `-32601 method not found` — absent or not routed |
| `WARN` | Some other error code |
| `TIMEOUT` | No response in 10s |
| `SKIP` | `stateful: 1` — would broadcast a transaction, never probed |
| `PARTIAL` | Failed on *some* providers — that upstream lacks the capability |
| `NOT_TESTABLE` | No supplied node supports it at all |
| `NOT_EXERCISED` | Never ran |
| `TESTED_OK` / `TESTED_FAIL` | Addon verified / addon failed despite a supporting upstream |
| `SINGLE_UPSTREAM` | Degraded because only one node was supplied |
| `WARN-DISAGREEMENT` | Upstreams returned materially different shapes |

**Severity markers used in the table:**

🛑 pipeline stops · ❗ spec defect, must fix · ⚠️ investigate · ℹ️ not a defect · 🔍 **no automated coverage — your job**

---

## 3. Every test, in order

> Wide table — scroll horizontally. "Phase" tells you which bot comment carries the result.

| # | Test | Phase | What it proves | Verdict | If it fails |
|---|---|---|---|---|---|
| **CI guards — run outside the 12 phases, both fail closed** |
| 1 | Removed-field guard (`check_unused_fields.sh`) | CI + 7 | None of the 15 fields deleted from the smart-router model are present (governance fields, `title`/`description`, `deposit`, `extra_compute_units`, `category.local`, `category.subscription`) | `RESULT: PASS` / one `REMOVED_FIELD \| path` line per offender | ❗ fixer deletes each field, both checks re-run |
| 2 | Preservation guard (`check_preservation.sh`) | CI (add-testnet PRs) | A testnet-only PR changed **nothing** in any pre-existing spec — `jq -S` canonical compare, catches value drift, field add/remove, array reorder | pass / fail | 🛑 ⚠️ **self-skips with `::notice::` if not on the branch — a skip reads as a pass** |
| **Phase 6 — inline pre-flight (orchestrator, before the gates)** |
| 3 | Index sanity | 6 | `index` uppercase, unique, matches the chain | manual | ❗ |
| 4 | Required entry fields | 6 | `name`, `enabled` present per spec entry | manual | ❗ |
| 5 | Mainnet chain-id from a **live curl** | 6 | `expected_value` came from the real node, not converted from a docs decimal | hex value shown | ❗ |
| 6 | Testnet chain-id from a **live curl** | 6 | same, for the testnet entry | hex value shown | ❗ |
| 7 | **`hanging_api` → `timeout_ms`** | 6 | Every `hanging_api: true` has an explicit `timeout_ms` | `jq`, output must be empty | 🔍 **no validator covers this** |
| 8 | **`category.stateful` direction** | 6 | Only broadcast/state-modifying methods are marked stateful | spot-check vs docs | 🔍 **no validator enforces direction** |
| 9 | archive ↔ pruning ↔ `GET_EARLIEST_BLOCK` triplet | 6 | All three present or all three absent, per entry | 3 booleans per entry | 🛑 any mixed row |
| **Phase 6 — the 9 static gates (parallel subagents)** |
| 10 | **methods-coverage** (`compare_spec_methods.sh`) | 6 | Every method research found is in the spec or its transitive imports | `PRESENT` / `MISSING` / `EXTRA IN SPEC` | ❗ on unjustified `MISSING`. `EXTRA` is informational |
| 11 | parse-directive L1 — boot-critical presence (`check_directive_presence.sh`) | 6 | `GET_BLOCKNUM` **and** `GET_BLOCK_BY_NUM` exist across the candidate **plus all parents** (they're usually inherited) | `OK` / `FAIL missing:` | ❗ router cannot track the chain |
| 12 | parse-directive L1 — numeric placeholder | 6 | `GET_BLOCK_BY_NUM` template carries `%d`/`%x`/`0x%x` | OK / FAIL | ❗ can't be driven by block number |
| 13 | parse-directive L1 — echoed-slot | 6 | `GET_BLOCK_BY_NUM` extracts a real block **identifier**, not the slot number it was called with | OK / FAIL | ❗ every provider "agrees" trivially — defeats data reliability |
| 14 | parse-directive L1 — canonical matrix | 6 | Template, `parser_func`, `parser_arg` match the canonical for `(interface, family)` | OK / FAIL / SKIPPED | ❗ (SKIPPED when family unknown) |
| 15 | parse-directive L2 — scout diff (`compare_spec_directives.sh`) | 6 | Directives match the upstream template by `tag\|api\|sha256` | `PRESENT`/`MISSING`/`HASH-MISMATCH` | ❗ unless justified. SKIPPED if no scout artifact |
| 16 | parse-directive L3 — live type check | 6 | Each directive, issued at a real RPC, parses to the right type | `PASS`/`FAIL`/`BLOCKED`/`STRUCTURAL_ONLY` | ❗ SKIPPED with no RPC URL |
| 17 | parse-directive L3 — **counter chaining** | 6 | `GET_BLOCK_BY_NUM` fed the number `GET_BLOCKNUM` *just returned* still resolves | PASS / FAIL / PARTIAL | ❗ different counters → tracker spins forever at boot |
| 18 | parse-directive L3 — top-level-array rejection | 6 | A `rest` + `PARSE_CANONICAL` response body is an object, not an array | PASS / FAIL | ❗ router can't index a top-level array |
| 19 | **chain-metadata** (`check_network_params.sh`) | 6 | `average_block_time` present; `block_distance_for_finalized_data` present; `blocks_in_finalization_proof` ∈ {1, 3, `max(ceil(1000/abt),3)`}; `allowed_block_lag_for_qos_sync` = `ceil(10000/abt)` | `=== PASS ===` / `=== FAIL ===` rows | ❗ |
| 20 | **verifications** (`check_verifications.sh`) | 6 | Each verification has `name`, non-empty `values[]`, valid `severity`; every `parse_directive.function_tag` resolves in its own collection | PASS / FAIL / INFO | ❗ on FAIL. INFO rows aren't failures |
| 21 | **extensions** (`check_extensions.sh`) | 6 | Every extension has `cu_multiplier`; `archive` has `rule.block`; every addon collection has ≥1 verification; no duplicate extension names | PASS / FAIL | ❗ |
| 22 | **cu-semantic L0** — subscription CU | 6 | subscribe = exactly `1000` CU, unsubscribe = exactly `10` | PASS / FAIL | ❗ only layer that can fail this gate |
| 23 | cu-semantic L1 — advisory bands | 6 | CU within its bucket band (tx-submit 10–40, simulate 40–60, heavy 60–200, state-read 10–20) | ADVISORY rows | ℹ️ never fails the gate |
| 24 | **pruning** — retention sizing (`check_pruning.sh`) | 6 | `archive.rule.block` and `pruning.latest_distance` within 3× of researched retention | PASS / FAIL / `INFO: retention unknown` | ❗ INFO = unverifiable, treated as pass |
| 25 | **pruning** — archive value (`check_archive_value.sh`) | 6 | Archive-tier `expected_value` is a base-10 integer on the `GET_BLOCK_BY_NUM`-without-`latest_distance` path (the router `ParseInt`s it) | PASS / FAIL | ❗ a `"*"` here excludes the archive provider at boot |
| 26 | **enabled** — watch-list | 6 | Flags methods research called unsupported that are still enabled | WATCH rows | ℹ️ **always PASS by design** — never auto-disables |
| 27 | **method-schema** (`check_method_schema.sh`) | 6 | Per API: `enabled`, `compute_units`, `block_parsing`, `category` present; `parser_arg` all strings; no duplicate names in a collection | PASS / FAIL | ❗ |
| **Phase 7 — final static gate** |
| 28 | JSON syntax | 7 | `jq . <chain>.json` exits 0 | exit code | 🛑 until fixed |
| 29 | Removed-field guard (same as #1, as a hard gate) | 7 | — | `RESULT: PASS` | 🛑 until both #28 and #29 pass |
| **Phase 7.5 — testability** |
| 30 | Endpoint discovery + validation | 7.5 | A real, validated upstream exists for every interface, subscription and addon the spec declares — validated with the requirement's *real* call, not a ping | coverage matrix: `TESTED_OK` / `NOT_TESTABLE` | ℹ️ `NOT_TESTABLE` is a transparent gap, never a stop |
| **Phase 8 — live smart-router boot + probe** ← *the core test* |
| 31 | Addon capability matrix (Step 1c) | 8 | Which upstream supports which addon — probed **direct to each node**, before boot | `SUPPORTED`/`UNSUPPORTED`/`INCONCLUSIVE` | ℹ️ unsupported addons are simply left out of the router config |
| 32 | **Router boot / spec resolution** (Step 3) | 8 | The spec loads, imports resolve, upstreams pass startup verification | listener answers, or `SMOKE: BOOT_FAILED` | 🛑 **no Phase 9** |
| 33 | **`PARSE_BLOCKNUM`** (Step 3.5a) | 8 | The chain tracker executes `GET_BLOCKNUM` against real nodes | `PARSE: OK/FAIL/PARTIAL` | ❗ **most severe defect possible** — router can't track the chain |
| 34 | **`PARSE_BLOCK_BY_NUM`** (Step 3.5a) | 8 | Tracker reads block hashes by number | part of `PARSE:` | ❗ |
| 35 | Parse-signature log scan (Step 3.5b) | 8 | No `ParseBlockHashFromReplyAndDecode` / `expected parsed hashes length` failures (DEBUG-level, invisible elsewhere) | log excerpt | ❗ diagnosis for #33/#34 |
| 36 | **Verification runtime scan** (Step 3.5c) | 8 | Every spec verification executed per provider at boot — the only place `GET_EARLIEST_BLOCK`/`pruning` runs | `VERIFY: OK/FAIL/PARTIAL` | ❗ FAIL (all providers). ℹ️ PARTIAL = upstream capability |
| 37 | **Method probe loop** (Step 4) | 8 | Every API relayed **through the router**, with live-resolved inputs and a mandatory re-probe on first failure | per-method table + `PASS=n FAIL=n SKIP=n WARN=n TIMEOUT=n` | ❗ on FAIL |
| 38 | Subscription probe (Step 4) | 8 | WebSocket subscribe → ≥1 message within 30s → unsubscribe | PASS / FAIL | ❗ |
| 39 | Extension probe (Step 4) | 8 | A `lava-extension: archive` call routes to a supporting leg | `TESTED_OK`/`TESTED_FAIL`/`NOT_TESTABLE` | ❗ on `TESTED_FAIL` |
| 40 | Probe-window log scan (Step 4.5) | 8 | No non-benign router errors hidden behind a plausible-looking response body | `LOG_WARN=n` | ⚠️ downgrades the method to WARN |
| 41 | **Testnet verification pass** (Step 7) | 8 | Boot + verifications against the TESTNET entry — **the only place its chain-id is live-checked**. No method probe | `TESTNET_VERIFY: OK/FAIL/PARTIAL/SKIPPED` | ❗ FAIL. ⚠️ **SKIPPED = testnet shipped with zero live verification** |
| 42 | Empirical block time (Step 8) | 8 | Measured block time within 20% of the spec's effective `average_block_time`, both networks | `BLOCK_TIME:` / `BLOCK_TIME_MISMATCH` | ❗ testnet → add an override. Mainnet mismatch shouldn't happen |
| **Phase 9 — independent review** |
| 43 | 3 × `/review-spec` in parallel | 9 | Three fresh reviewers, each having read the probe report, run a 9-part audit: provider, network params, API completeness, per-method (block parsing / category flags / CU), parse directives, verifications, inheritance, headers, live tests | `TALLY: CRITICAL=x MEDIUM=y MINOR=z` ×3 | ⚠️ CRITICAL/MEDIUM feed the fix pass; MINOR dropped |
| **Phase 10 — fix pass** |
| 44 | Disable-suggestion filter | 10 | Strips every "disable this method" suggestion justified only by probe errors | `K disable-suggestions stripped` | ℹ️ stripped items → watch-list |
| 45 | Post-fix JSON validity | 10 | `jq` still parses after the fixer | exit code | 🛑 `BROKEN_AFTER_FIX`, no Phase 10b |
| **Phase 10b — regression check** |
| 46 | Re-boot against the fixed spec | 10b | The fix didn't break startup | `SMOKE: OK/REGRESSION/BOOT_FAILED` | 🛑 no Phase 11 |
| 47 | Parse/verify re-check | 10b | #33, #34, #36 still pass after the fix | `PARSE:` / `VERIFY:` | 🛑 regression |
| 48 | 7-item probe set + addon re-probe | 10b | `GET_BLOCKNUM`, chain-id verification, 5 sampled read methods, plus every Phase-8 `TESTED_OK` addon | PASS/FAIL per item | 🛑 any Phase-8 PASS now failing |
| **Phase 11 — final gate** |
| 49 | Final `/review-spec`, clean context | 11 | A fourth reviewer re-derives everything from the file, with prior reports archived so they can't anchor it | `TALLY: CRITICAL=0 MEDIUM=0` = **APPROVED** | 🛑 anything else = **CHANGES REQUESTED**, no retry loop |
| 50 | Disabled-API justification audit | 11 | Every `enabled: false` entry has a positive-evidence row (docs or client source, **with URL**) in the Disabled-API Justifications PR comment | pass / CRITICAL | ❗ a disabled entry with no row is CRITICAL |
| **Never tested by the pipeline** |
| 51 | Stateful / broadcast methods | — | — | always `SKIP` | 🔍 test on a funded testnet if it matters |
| 52 | gRPC methods through the router | — | The router's gRPC listener has no server reflection, so probes go **direct to upstream** | labelled direct-upstream | 🔍 boot locally and relay gRPC yourself |
| 53 | Compute units under load | — | — | — | 🔍 benchmark if CU accuracy matters for billing |
| 54 | Per-API block parsing, fully | — | Existence-tested only; full validation needs production traffic | — | 🔍 sample a few APIs against historical blocks |
| 55 | Testnet method coverage | — | Testnet gets boot + verifications only (#41), no method probe | — | 🔍 probe the testnet yourself if it matters |

---

## 4. The rule that catches people out

**A probe error never justifies disabling a method.** The pipeline only tests free-tier public nodes. A `-32601`, `501`, `429` or timeout may prove only that the free tier lacks it.

Disabling requires *positive* evidence — official docs saying removed, or the node client not implementing it, **with a URL**, recorded in the Disabled-API Justifications comment. Tests #26, #44 and #50 all enforce this. If you see something disabled because "the probe returned -32601", flag it.

---

## 5. Red flags

| Red flag | Why it matters |
|---|---|
| `TESTNET_VERIFY: SKIPPED` | Testnet entry shipped with **zero** live verification (#41) |
| `PARSE:` or `VERIFY: FAIL` still present at Phase 11 | A known defect survived the fix pass |
| Phase 11 says CHANGES REQUESTED but the PR merged | Someone overrode the gate — find out why |
| `enabled: false` with no ledger row | #50 should have caught it as CRITICAL |
| `ADDONS: … not-testable` with no follow-up | Nobody ever verified that addon |
| `BLOCK_TIME_MISMATCH` on **mainnet** | Should be impossible — an input was wrong |
| Phase 10 "resolved *against* the reviewers" | A human overrode a reviewer's CRITICAL |
| Add-testnet PR with no preservation-guard line in the log | #2 may have self-skipped |
| **No bot comments at all** | Spec predates the pipeline — see §6 |

Two checks you can run on any spec right now — these are tests #7 and #8, which nothing automates:

```bash
# hanging_api without timeout_ms — output must be empty
jq -r '.proposal.specs[].api_collections[].apis[]
       | select(.category.hanging_api == true and (.timeout_ms // null) == null) | .name' <chain>.json

# every stateful method — each should be a broadcast/submit call
jq -r '.proposal.specs[].api_collections[].apis[]
       | select(.category.stateful == 1) | .name' <chain>.json
```

---

## 6. Not every spec has this trail

There are **127 spec files** at the repo root. Only those onboarded or reworked *through the pipeline* have the evidence above. Older specs predate it and have no probe report, no tallies, no Phase 11 verdict.

Coverage also varies by PR type. Of six recent PRs I checked, five carried the full per-method table; **PR #100** (a mechanical strip of removed fields across 5 specs) had **no Phase 8 at all** — no behavioral change, so no probe. That is legitimate. When a table is missing, the question is whether Phase 8 was skipped deliberately or failed.

To tell: find the PR that introduced the spec and look for `magmadevs-bot` comments. None → no recorded testing.

---

## 7. Verifying a spec yourself

Use the **`testing-chain-specs-locally`** skill — it boots the spec in a real smart-router binary and is the accepted way to produce an independent verification comment. `/testing-chain-specs-locally`, or read `.claude/skills/testing-chain-specs-locally/SKILL.md`. PR #103's comment from `avitenzer` is the worked example: it confirmed the pipeline's findings *and found one defect the pipeline missed*.

Shape of a run: gather the PR (`gh pr view`) and sync the branch — pipelines push fix commits after opening, and a stale tree tests the wrong spec → run the field-cleanup guard → write one `config/<chain>.yml` covering both networks → boot with `--use-static-spec` (success = `ChainTracker initialization complete ... failed=0`, one per interface × network) → relay 2–3 requests per surface → stop the router, then `smartrouter health` → post the comment.

### The iron rule

> **All traffic goes THROUGH the router. Never curl a node directly** — not even to "prove a -32601 is a node gap."

The router's boot verifications and relay logs *are* the evidence. Direct pings also got the Phase-8 pipelines Cloudflare-429'd.

### Traps that produce confidently wrong QA reports

- **A successful old-block relay does not prove archive works.** Extensions soft-fall-back: `extensions=archive` fires, finds no supporting leg, resets, and a *base* leg serves it anyway if the pruned node still has the block. Grep the request GUID for that sequence. Addons, by contrast, hard-fail.
- **Relay PASS counts don't prove the API catalog is bound.** An unmatched REST path silently degrades to the router's default container and still relays. Only `curl localhost:7779/metrics | grep -oE 'function="[^"]*"'` proves binding — a `Default-` prefix means that path matched no spec API.
- **`No pairings available` is not a dead method** — provider demotion, revalidates in ~3 min.
- **One timeout is not a classification** — cold gateways take >15s on first hit.
- **Everything failing at once right after a session is a rate limiter**, not an outage. Cool down 5 minutes.
- **Run WebSocket tests last** — the router can crash on client ws disconnect.

---

## 8. Quick reference

```bash
# Full evidence trail
gh pr view <n> --json body,comments --jq '.comments[].body'

# Headline verdicts only
gh pr view <n> --json comments --jq '.comments[].body' \
  | grep -E 'PARSE:|VERIFY:|TESTNET_VERIFY:|ADDONS:|TALLY:|PASS=[0-9]'

# Tests #1 / #2 by hand
bash .claude/skills/create-spec/scripts/check_unused_fields.sh <chain>.json
git diff origin/main -- <chain>.json          # add-testnet PRs: nothing but the new entry

# What a spec declares
jq -c '.proposal.specs[] | {index,
  ifaces: ([.api_collections[].collection_data.api_interface] | unique),
  addons: ([.api_collections[].collection_data.add_on] | unique - [""]),
  exts:   ([.api_collections[].extensions[]?.name] | unique)}' <chain>.json

# The tooling's own self-tests (12, all should pass — needs bash ≥ 4; stock macOS bash 3.2 fails 5 of them)
for t in .claude/skills/create-spec/scripts/test_*.sh; do
  printf '%-40s ' "$(basename $t)"; bash "$t" >/dev/null 2>&1 && echo PASS || echo FAIL
done
```

| Question | Document |
|---|---|
| What exactly does each gate check, and what happens when it fails? | [`.claude/skills/create-spec/TESTING.md`](.claude/skills/create-spec/TESTING.md) |
| How do I boot and test a spec locally? | `.claude/skills/testing-chain-specs-locally/SKILL.md` |
| What are the spec-authoring rules? | `.claude/skills/review-spec/SPEC_GUIDE.md` |
| How does the pipeline orchestrate all this? | `.claude/skills/create-spec/SKILL.md` |
