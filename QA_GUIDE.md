# QA guide — what testing every chain spec receives

For the QA engineer picking up a chain spec and asking: *what was actually tested here, what wasn't, and what do I still need to check myself?*

This is the practical guide. For the mechanics of each individual check, see [`.claude/skills/create-spec/TESTING.md`](.claude/skills/create-spec/TESTING.md).

---

## 1. Start here: the evidence is in the PR, not the repo

This is the single most important thing to know, and it surprises everyone.

The pipeline writes its reports to `docs/<chain>/` — `METHOD_PROBE_REPORT.md`, `SPEC_REVIEW_GAPS_*.md`, `FIX_LIST.md`. **`docs/` is gitignored** (`.gitignore:3` — "transient run outputs, never committed"). Those files exist only on whichever machine ran the pipeline. They are never committed, never pushed, and are not in your checkout.

So:

> **The durable test record for a spec is the set of bot comments on the pull request that introduced or changed it.**

If someone points you at `docs/sui/METHOD_PROBE_REPORT.md`, that path is real but the file isn't there. Go to the PR.

The same applies to the disabled-API ledger. It used to be a `docs/<chain>/DISABLED_JUSTIFICATIONS.md` file; it is now posted as a **PR comment titled "Disabled-API Justifications"**, precisely because a gitignored file never persisted and every fresh review re-flagged the same disables.

---

## 2. Finding the evidence for a given spec

```bash
# 1. Which PR last touched this spec?
git log --oneline -5 -- sui.json

# 2. Find the PR (by commit, or search by filename)
gh pr list --state all --search "sui.json" --json number,title,mergedAt

# 3. Read the whole evidence trail
gh pr view 103 --json body,comments
```

The PR **body** is the *input* — the human brief, endpoint routing, known gotchas. It is not test results. Read it first anyway: it often contains the per-interface endpoint routing rules that explain why a probe hit one host and not another.

The **comments from `magmadevs-bot`** are the results. They arrive in this order:

| Comment | What it proves | Read it for |
|---|---|---|
| 🤖 *Spec pipeline started* | — | The **link to the Actions run** — full logs if a comment is truncated |
| **Phase 8 — smart-router boot + multi-node method probe** | The spec actually loads in a real router and every method routes | The inline Method Probe Report: per-method PASS/FAIL table, parse-directive verdicts, verification verdicts, addon coverage, testnet pass, empirical block time |
| **Phase 9 — parallel reviewers** | Three independent reviews agreed/disagreed | Per-reviewer tallies and the **merged CRITICAL/MEDIUM gap list**. Disagreement between reviewers is signal — look at what only one of them caught |
| **Phase 10 — consolidation + fix pass** | Which gaps were fixed, which were argued down | Gaps "resolved *against* the reviewers" — these are judgement calls someone made, and they're the most likely place for a mistake |
| **Disabled-API Justifications** | Every `enabled: false` has documented cause | One row per disabled API with evidence type + source URL |
| **Phase 11 — final reviewer verdict** | The go/no-go | `✅ APPROVED` requires `CRITICAL=0 MEDIUM=0`. Anything else is **CHANGES REQUESTED** |
| **Phase 12 — closing checklist** | Honest coverage summary | The `~` and `☐` rows — that's your worklist |
| 📦 *Committed pipeline fixes* | The branch matches what was verified | The commit SHA that Phase 10b/11 actually tested |

Human reviewer comments may follow. PR #103 has a good worked example from `avitenzer`: an independent local smart-router run that confirmed the pipeline's findings and *found one additional defect the pipeline missed*. That is the standard for a manual verification comment.

---

## 3. What the pipeline actually does

Twelve phases; six of them verify. Cheapest checks first, so an expensive router boot only happens once the static gates are clean.

| Phase | What it proves |
|---|---|
| **6** | 9 static gates in parallel — method coverage vs researched ground truth, parse-directive shape, network-param formulas, verification schema, extension schema, compute units, pruning sizing, and per-method schema |
| **7** | Valid JSON **and** no reintroduced removed model fields |
| **7.5** | A real, validated upstream endpoint exists for every interface, subscription and addon the spec declares |
| **8** | **The spec boots in a real smart-router and every method routes through it.** The core live test |
| **9** | Three independent `/review-spec` passes, each having read the probe report |
| **10** | Gaps consolidated and fixed in one pass |
| **10b** | Re-boot after the fix — did anything regress? |
| **11** | A fourth reviewer in clean context, plus a disabled-API audit |

Two things run **outside** the twelve phases, as CI steps, and both **fail closed** (if the check itself can't run, the job fails rather than passing):

- **Removed-field guard** — rejects any spec carrying one of the 15 fields deleted from the smart-router model (smart-router#218): the governance fields, `proposal.title`/`description`, top-level `deposit`, `extra_compute_units`, `category.local`, `category.subscription`.
- **Preservation guard** (add-testnet PRs) — canonical `jq -S` byte-comparison proving a testnet-only PR changed *nothing* about the existing mainnet. ⚠️ **This guard self-skips with a `::notice::` if `check_preservation.sh` isn't on the PR branch.** A skip looks like a pass in the log. On any add-testnet PR, confirm the guard actually ran.

### Why the preservation guard exists — check this on every add-testnet PR

PR #80 added a testnet and **silently regenerated the mainnet block**, drifting `average_block_time` from 200 to 35 and a parser arg from `block_height` to `block_hash`. The removed-field guard was blind to it — the field *names* were all fine, only the *values* had changed.

There is now an "add-testnet mode" that appends one testnet entry and is structurally incapable of touching the mainnet. But if you are reviewing a testnet-addition PR, spend thirty seconds on this regardless:

```bash
# Nothing but the new testnet entry should appear.
git diff origin/main -- <chain>.json
```

---

## 4. Reading the verdicts

The probe report uses a specific vocabulary. **Several verdicts that look like failures are not defects** — this is where most misreadings happen.

### Per-method results

| Verdict | Meaning | Defect? |
|---|---|---|
| `PASS` | Returned a `result` field | No |
| `PASS-existence` | Returned `-32602 invalid params` — the method exists, the probe just didn't have valid arguments | **No** |
| `FAIL` | `-32601 method not found` | **Yes** — method absent or not routed |
| `WARN` | Some other error code | Investigate |
| `TIMEOUT` | No response in 10s | Investigate |
| `SKIP` | `stateful: 1` — would broadcast a transaction | Never tested, by design |
| `WARN-DISAGREEMENT` | Different upstreams returned materially different shapes | Investigate |

### Parse directives and verifications

| Verdict | Meaning | Defect? |
|---|---|---|
| `PARSE: OK` | The router's chain tracker successfully executed `GET_BLOCKNUM` / `GET_BLOCK_BY_NUM` against live nodes | No |
| `PARSE: FAIL` | The router cannot track the chain | **Yes — the most severe defect there is** |
| `VERIFY: OK` | Every verification passed on every provider | No |
| `VERIFY: FAIL` | A verification failed on *every* provider | **Yes** — wrong directive or wrong `expected_value` |
| `VERIFY: PARTIAL` | Failed on *some* providers | **No** — that upstream lacks the capability (e.g. a pruned node failing `pruning`). Note which provider was excluded |
| `NOT_EXERCISED` | Never ran | Only OK if no upstream supports the gating addon |
| `SINGLE_UPSTREAM` | Availability degraded because only one node was supplied | **No** — a deployment artifact, not a spec issue |

### Addons and extensions

| Verdict | Meaning | Defect? |
|---|---|---|
| `TESTED_OK` | An upstream supports it, boot verification passed, probe passed | No |
| `TESTED_FAIL` | A supporting upstream exists but it failed | **Yes** |
| `NOT_TESTABLE` | No provided node supports it at all | **No** — a transparent coverage gap. Needs a better node to test, not a spec change |

### The rule that catches people out

**A probe error never justifies disabling a method.** The pipeline only tests free-tier public nodes. A `-32601`, a `501`, a `429`, a timeout — none of these prove the chain lacks the method; they may just prove the free tier does. Disabling an API requires *positive* evidence: official docs saying it's removed, or the node client not implementing it, **with a URL**, recorded in the Disabled-API Justifications comment.

If you see a suggestion to disable something because "the probe returned -32601", that suggestion should have been stripped. Flag it.

---

## 5. Red flags

Scan for these when reviewing a spec's evidence trail:

| Red flag | Why it matters |
|---|---|
| `TESTNET_VERIFY: SKIPPED` | The testnet entry shipped with **zero live verification**. Its chain-id was probably set by convention and never checked against a real node |
| `PARSE: FAIL` or `VERIFY: FAIL` still present at Phase 11 | A known defect made it through the fix pass |
| Phase 11 says **CHANGES REQUESTED** but the PR was merged | Someone overrode the gate. Find out why |
| An `enabled: false` API with no row in the Disabled-API Justifications comment | Phase 11 treats this as CRITICAL. If it merged, the audit didn't run |
| `ADDONS: … not-testable` with no follow-up | Nobody ever verified that addon. It needs a capable node |
| A `BLOCK_TIME_MISMATCH` on mainnet | Should be impossible — the value was locked against empirical data early. Means an input was wrong |
| Phase 10 "resolved *against* the reviewers" | A human judgement overrode a reviewer's CRITICAL. Worth a second opinion |
| No bot comments at all | The spec predates the pipeline — see §7 |

---

## 6. What is NOT tested — your worklist

The pipeline is honest about its gaps. These are the things it does **not** check, and they are where manual QA earns its keep:

| Gap | Why | What to do |
|---|---|---|
| **`hanging_api` → `timeout_ms`** | No validator covers it | `jq` every API with `category.hanging_api: true` and confirm each has an explicit `timeout_ms` |
| **`category.stateful` direction** | No validator enforces it | Spot-check that only broadcast/state-modifying methods are marked stateful. A read method wrongly marked stateful is *also silently skipped by the probe* — the two gaps compound |
| **Stateful methods generally** | Never probed — they'd broadcast transactions | Test on a testnet with funded keys if it matters |
| **gRPC methods through the router** | The router's gRPC listener has no server reflection, so probes go direct-to-upstream | Boot locally and relay gRPC through the router yourself |
| **Compute units under load** | Never benchmarked | Measure if CU accuracy matters for billing |
| **Economic params** (`min_stake_provider`, `shares`) | Presence checked, reasonableness not | Human judgement |
| **Per-API block parsing** | Existence-tested only; full validation needs production traffic | Sample a few APIs with historical blocks |
| **Testnet method coverage** | Testnet gets boot + verifications only, **no method probe** | If the testnet matters, probe it yourself |

Two quick checks you can run right now on any spec:

```bash
# hanging_api without timeout_ms — output must be empty
jq -r '.proposal.specs[].api_collections[].apis[]
       | select(.category.hanging_api == true and (.timeout_ms // null) == null) | .name' <chain>.json

# every stateful method — each should be a broadcast/submit call
jq -r '.proposal.specs[].api_collections[].apis[]
       | select(.category.stateful == 1) | .name' <chain>.json
```

---

## 7. Coverage boundary — not every spec has this trail

There are **128 spec files** at the repo root. Only those onboarded or reworked *through the pipeline* have the evidence described above. Older specs were added before it existed and have **no probe report, no reviewer tallies, no Phase 11 verdict**.

To tell which is which: find the PR that introduced the spec and look for `magmadevs-bot` comments. No bot comments → no pipeline evidence → the spec has had only whatever manual testing its author did.

If you're asked "what testing was done for spec X" and X predates the pipeline, the honest answer is "none that's recorded" — and that's a candidate for a manual verification run.

---

## 8. Verifying a spec yourself

There is a dedicated skill for this: **`testing-chain-specs-locally`**. It boots the spec in a real smart-router binary and is the accepted way to produce an independent verification comment on a PR. Invoke it with `/testing-chain-specs-locally`, or read `.claude/skills/testing-chain-specs-locally/SKILL.md`.

The shape of a manual run:

1. **Gather** — `gh pr view <n> --json body,comments`. Reuse the PR's endpoints and expected values; don't invent them. Sync the branch first: pipelines push fix commits after the PR opens, and a stale tree tests the wrong spec.
2. **Field-cleanup guard** — `bash .claude/skills/create-spec/scripts/check_unused_fields.sh <chain>.json` before booting.
3. **Config** — one `config/<chain>.yml` covering mainnet and testnet on separate ports.
4. **Boot** — the smart-router binary with `--use-static-spec`. Success signature: `ChainTracker initialization complete ... failed=0`, one per interface × network.
5. **Relay** — 2–3 requests per surface, every interface and addon, both networks.
6. **Health** — stop the router first, then `smartrouter health`. Compare per-leg results against the live boot.
7. **Comment** — post results in the skill's fixed format.

### The iron rule

> **All traffic goes THROUGH the router. Never curl a node directly** — not even to "prove a -32601 is a node gap."

The router's boot verifications and relay logs *are* the evidence: a `-32601` relayed through the router already came from the node. Direct pings also got the Phase-8 pipelines Cloudflare-429'd. (DNS lookups via `getent hosts` are fine and often useful.)

### Traps that produce wrong conclusions

The skill documents these at length. The ones most likely to make a QA report wrong:

- **A successful old-block relay does not prove archive works.** Extensions soft-fallback: `extensions=archive` fires, finds no supporting leg, resets, and a *base* leg serves it anyway if the pruned node still has the block. Grep the request GUID for the fallback sequence. Addons, by contrast, hard-fail.
- **Relay PASS counts don't prove the API catalog is bound.** An unmatched REST path silently degrades to the router's default container and still relays successfully. Only `curl localhost:7779/metrics | grep -oE 'function="[^"]*"'` proves binding — a `Default-` prefix means that path matched no spec API.
- **`No pairings available` is not a dead method.** It's provider demotion after upstream-failure bursts; it revalidates in ~3 minutes.
- **One timeout is not a classification.** Cold gateways take >15s on first hit of a new path. Retry before calling anything dead.
- **Everything failing at once right after a session is a rate limiter, not an outage.** Cool down 5 minutes.
- **Run WebSocket subscription tests last.** The router can crash on client ws disconnect.

---

## 9. Quick reference

```bash
# Full evidence trail for a spec's PR
gh pr view <n> --json body,comments --jq '.comments[].body'

# Just the pipeline verdicts
gh pr view <n> --json comments --jq '.comments[].body' | grep -E 'PARSE:|VERIFY:|TESTNET_VERIFY:|ADDONS:|TALLY:|BLOCK_TIME:'

# Removed-field guard
bash .claude/skills/create-spec/scripts/check_unused_fields.sh <chain>.json

# Add-testnet PR: prove the mainnet didn't drift
git diff origin/main -- <chain>.json

# What a spec declares (interfaces, addons, extensions)
jq -c '.proposal.specs[] | {index,
  ifaces: ([.api_collections[].collection_data.api_interface] | unique),
  addons: ([.api_collections[].collection_data.add_on] | unique - [""]),
  exts:   ([.api_collections[].extensions[]?.name] | unique)}' <chain>.json

# Run the tooling's own self-tests (12, all should pass)
for t in .claude/skills/create-spec/scripts/test_*.sh; do
  printf '%-40s ' "$(basename $t)"; bash "$t" >/dev/null 2>&1 && echo PASS || echo FAIL
done
```

---

## Where to go deeper

| Question | Document |
|---|---|
| What exactly does each gate check, and what happens when it fails? | [`.claude/skills/create-spec/TESTING.md`](.claude/skills/create-spec/TESTING.md) |
| How do I boot and test a spec locally? | `.claude/skills/testing-chain-specs-locally/SKILL.md` |
| What are the spec-authoring rules? | `.claude/skills/review-spec/SPEC_GUIDE.md` |
| How does the pipeline orchestrate all this? | `.claude/skills/create-spec/SKILL.md` |
