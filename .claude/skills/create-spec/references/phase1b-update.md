# Phase 1B — Update mode (amend an existing spec)

Read this file end-to-end before running update mode. It is the contract for
the one mode that writes into a spec other people already depend on.

Update mode answers: *"this chain is already onboarded — what has its API grown
since, and what did we get wrong?"* It re-researches the chain from scratch,
diffs the findings against the committed spec, **adds** everything missing, and
**corrects** values that research proves wrong. It never removes anything.

## Where it sits

Phase 1 resolves `<SPEC_FILE>` by the mainnet index it CONTAINS and offers four
modes. Update mode is the right choice when the chain exists and the ask is
"add the methods it is missing" / "bring the spec up to date". Contrast:

| Mode | Touches | Use when |
|---|---|---|
| add-testnet (1A) | appends ONE testnet entry, nothing else | "add chain X's testnet Y" |
| **update (1B)** | **adds + corrects inside existing entries** | **"X is missing methods", "refresh X"** |
| base / adapt | regenerates everything | the spec is structurally wrong |
| scratch | overwrites | starting over |

Update mode runs **B1–B7 below, then hands off to Phase 7 → 12**. It does NOT
re-run Phase 4's `spec-builder` (that agent re-emits the whole file, which is
exactly how PR #80 drifted a mainnet) — synthesis is done by `spec-updater`,
which only ever performs surgical writes.

## The one invariant

> Every semantic difference between the base file and what you ship must be
> declared, in advance, in the change plan — and every declared change must land.

`scripts/check_update_diff.sh` enforces it mechanically at B6, and it is what
makes "we also fix drift" safe. Deletion is never declarable: a removed spec,
collection, api, directive, verification, extension or even a single removed
FIELD fails the guard unconditionally.

---

## B1 — Resolve the target and snapshot the base

```bash
# <SPEC_FILE> came from the Phase 1 lookup (by index content, not filename).
jq -r '.proposal.specs[] | "\(.index)\t\(.name)\t\([.api_collections[].collection_data.api_interface] | unique | join(","))"' <SPEC_FILE>

# The base is what the guard compares against. Prefer origin/main; fall back to
# the local HEAD when the run has no remote (interactive work on a fresh clone).
git show origin/main:<SPEC_FILE> > /tmp/<chain>_base.json 2>/dev/null \
  || git show HEAD:<SPEC_FILE> > /tmp/<chain>_base.json
jq empty /tmp/<chain>_base.json
```

If the working tree already has uncommitted edits to `<SPEC_FILE>`, STOP and say
so — update mode's guard measures against the committed file, so pre-existing
local edits would be reported as undeclared changes and block the run.

Record which spec entries are in scope. **Default: the mainnet entry only.** A
lean testnet that imports it inherits every addition automatically and must stay
lean; touch a testnet entry only for a value it genuinely overrides (its own
`chain-id`, or its own block time).

## B2 — Re-research the chain, blind to the current spec

Run **Phase 3 exactly as written** — the same five agents, same prompts, same
foreground dispatch. Do NOT pass the existing spec, its method list, or "we
already have N methods" into any research prompt.

This is the whole point of the mode. A researcher told what the spec already
contains reports back a confirmation of it; a researcher that enumerates the
chain's API from its docs finds what nobody added. The diff is mechanical and
happens afterwards, at B3 — anchoring the research destroys it.

The one exception is `upstream-spec-scout`, which must be told the spec's
current `imports` so it can report whether the parent still fits and whether the
parent has itself gained methods since.

Output is the same as a new-chain run: `/tmp/<chain>_research_brief.md`,
`/tmp/<chain>_methods.txt`, `/tmp/<chain>_directives.txt`, plus the
archive-researcher report printed verbatim.

## B3 — Mechanical diff

### Methods

```bash
bash .claude/skills/create-spec/scripts/compare_spec_methods.sh \
  <SPEC_FILE> /tmp/<chain>_methods.txt > /tmp/<chain>_method_diff.txt
```

Three sections, each carrying the source index:

- **MISSING** — research found it, the spec and its parents do not have it.
  These are the ADD candidates. This is the list the user asked for.
- **PRESENT** — already served. Note the `source-index` column: a method served
  by a PARENT is inherited, and adding it to the child is duplication, not a fix.
- **EXTRA IN SPEC** — the spec serves it, research did not list it. Rows sourced
  from a **parent** index are normal inheritance — ignore them. Rows sourced from
  the chain's **own** index mean the docs no longer list a method this spec
  declares: **report it, never remove it.** Removal is out of scope for update
  mode (an old method that still works is harmless; a removed one breaks users).

### Structure

Methods are not the only thing that goes missing. Scan for the rest:

```bash
CAND=<SPEC_FILE>
# the archive / pruning / GET_EARLIEST_BLOCK triplet, per spec entry
jq '.proposal.specs[] | {index,
  archive_ext:        ([.api_collections[].extensions[]?.name] | contains(["archive"])),
  pruning_ver:        ([.api_collections[].verifications[]?.name] | contains(["pruning"])),
  earliest_directive: ([.api_collections[].parse_directives[]?.function_tag] | contains(["GET_EARLIEST_BLOCK"]))}' "$CAND"

# collections the spec declares, to compare against the interfaces research found
jq -r '.proposal.specs[] | .index as $i | .api_collections[] |
  "\($i)\t\(.collection_data.api_interface)\t\(.collection_data.internal_path)\t\(.collection_data.add_on)"' "$CAND"

# hanging apis with no explicit timeout
jq -r '.proposal.specs[].api_collections[].apis[] |
  select(.category.hanging_api == true and (.timeout_ms // null) == null) | .name' "$CAND"

# what is already disabled — each one needs a justification row before you ship
jq -r '.proposal.specs[].api_collections[].apis[] | select(.enabled == false) | .name' "$CAND"
```

Gaps to look for: an interface research documents that has no collection; a new
`internal_path` surface (a chain that added `/v3` alongside `/v2`); an addon the
plugin-researcher found with no matching `add_on` collection or extension; a
missing triplet member; subscription methods with no `FUNCTION_TAG_SUBSCRIBE`
directive.

## B4 — Triage into the change plan

Every intended change becomes one row of `/tmp/update_plan.tsv`. That exact path
is a contract: `create_spec.yml` re-runs the guard against it after the agent
finishes, and fails the run — no PR — if it is missing or does not match the
file. One run, one plan.

```
ACTION <TAB> TARGET <TAB> FIELD <TAB> NOTE <TAB> EVIDENCE
```

`TARGET` is an identity key in the form `scripts/spec_leaves.jq` prints:

```
S:<INDEX>
S:<INDEX>|C:<iface>~<internal_path>~<type>~<add_on>
S:<INDEX>|C:<iface>~~POST~|A:<method name>
S:<INDEX>|C:<iface>~~POST~|E:<extension>     P:<function_tag>   V:<verification>
```

Declaring `ADD` for a target covers everything inside it — one row for a new
collection authorizes all of its apis.

### What may be ADDed

Anything missing, with a source: methods, collections, addon collections,
extensions, parse_directives, verifications, headers, inheritance_apis. ADD rows
should still carry the docs URL in EVIDENCE — it is what the PR reviewer reads.

### What may be MODIFIED

Only this list. The guard refuses every other field, declared or not, because
changing it is a delete-and-re-add wearing a MODIFY costume.

| Field | Fix when | Evidence that satisfies the guard |
|---|---|---|
| `compute_units` | outside its semantic band | cu-semantic gate row + the comparable method it is banded against |
| `block_parsing.*` | wrong arg/func for the method | docs URL, or `probe:` a Phase-8 `PARSE: FAIL` line |
| `parsers[*]` | wrong parse_path / parse_type | docs URL, or a probe line |
| `category.*` | wrong `deterministic` / `stateful` / `hanging_api` | docs URL |
| `timeout_ms` | a hanging api has none | the `category.hanging_api` row itself |
| `average_block_time` + `block_distance_for_finalized_data` + `blocks_in_finalization_proof` + `allowed_block_lag_for_qos_sync` | empirical disagrees by >20% | the measurement (chain-metadata researcher, or Phase 8 `BLOCK_TIME:`) |
| `values[*].expected_value` | a verification value is wrong | the live curl output |
| `cu_multiplier`, `rule.block` | archive extension mis-tuned | archive-researcher report |
| `function_template`, `api_name`, `result_parsing.*` | a directive is wrong | docs URL, or a Phase-8 `PARSE:`/`VERIFY: FAIL` |
| `enabled` false → true | docs now document the method | docs URL |
| `enabled` true → false | **positive evidence of absence only** | docs-explicit or client-source URL. The guard **rejects** `probe:` evidence here |

Correcting a block time means correcting all four values together — the derived
three are computed from it by the Phase-4 formulas in
`references/phase2-network-params.md`. Ship them as four MODIFY rows.

### What is report-only

Never written; goes to the PR body so a human decides:

- own-index EXTRA methods (docs dropped a method the spec still serves)
- a parent that no longer fits (`imports` is not modifiable here — that is a
  base/adapt regeneration, not an update)
- any rename, any removal, any `collection_data` change
- a method research flagged unsupported on evidence you could not verify

### Seeding the plan

Write the plan from your triage — it is the *intent*, authored before the file
changes. After `spec-updater` returns you may cross-check it against what
actually landed:

```bash
bash .claude/skills/create-spec/scripts/check_update_diff.sh --emit \
  /tmp/<chain>_base.json <SPEC_FILE>
```

`--emit` prints the actual diff in plan format. Use it to *find* an undeclared
edit, never to replace your plan wholesale — a plan generated from the result
can never disagree with the result, which throws away the entire guarantee.

## B5 — Dispatch `spec-updater`

One `general-purpose` subagent, `model: "opus"`, no isolation. It reads
`references/agents/spec-updater.md` (observe `END-OF-SPEC-UPDATER-SENTINEL`) and
receives: `<SPEC_FILE>`, the base snapshot path, the plan path, the method-diff
path, the research brief path, and the directives file.

It performs surgical `jq` writes only, one plan row at a time, and returns a
compact summary plus the per-row applied/skipped ledger. Do NOT read the spec
body into your own context; hold the path.

If it reports a row it could not apply, decide: fix the row, or drop it from the
plan. Both halves must agree before B6 can pass.

## B6 — Static gates

Run **Phase 6's nine parallel validator gates** against the updated file, exactly
as Phase 6 documents them. They are what catches a badly-shaped addition: a CU
outside its semantic band, a method with no parse directive, a broken schema, an
extension without its triplet.

Two update-mode rules on top:

- The Phase 6 fixer edits pre-existing entries like anything else. **Every fix it
  applies must be appended to the plan**, with the gate row as its EVIDENCE
  (`cu-semantic:<row>` is a legitimate source; `probe:` still is not, for a
  disable). A fix you cannot justify in a plan row is a fix you revert.
- Gates will also flag entries this run never touched — the spec has been on
  `main` for a while. That is not a failure of this PR. Fix them under a plan row
  if the fix is obvious and evidenced, otherwise list them under "Reported, not
  changed" and move on. Do not let a pre-existing finding block the update.

## B6b — The declared-diff guard

All four must pass. Run them in this order; the first failure stops the run.

```bash
jq empty <SPEC_FILE>

bash .claude/skills/create-spec/scripts/check_unused_fields.sh <SPEC_FILE>

bash .claude/skills/create-spec/scripts/check_update_diff.sh \
  /tmp/<chain>_base.json <SPEC_FILE> /tmp/update_plan.tsv

# only when the spec sets internal_path anywhere
bash .claude/skills/create-spec/scripts/check_internal_paths.sh <SPEC_FILE>
```

Reading `check_update_diff.sh` failures:

| Row | Means | Do |
|---|---|---|
| `undeclared-add` | the updater added something the plan does not list | add the row (with evidence) or revert the addition |
| `undeclared-modify` | **a silent value change — the PR #80 failure mode** | revert it unless you can justify it; then declare it |
| `no-evidence` | declared, but the EVIDENCE column is empty | supply a URL or drop the change |
| `forbidden-field` | an identity/structure field changed | revert; it is out of scope for update mode |
| `removed-target` / `removed-field` | something was deleted | revert — always |
| `probe-only-disable` | a disable justified by probe errors | free-tier artifact, not evidence. Revert and put it on the watch-list |
| `not-applied` | the plan declares a change the file does not have | apply it or drop the row |
| `duplicate-identity` | two apis share a name in one collection | a real spec defect; rename or merge |

Then re-count what ships disabled, for the PR body marker:

```bash
bash .claude/skills/create-spec/scripts/check_disabled_count.sh <SPEC_FILE>
```

## B7 — Hand off

Continue at **Phase 7.5 → 8 → 9 → 10 → 10b → 11 → 12** unchanged, with two
scoping rules:

- **Phase 8 probe:** probe the ADDED methods and every method touched by a
  MODIFY row first; they are what this PR is accountable for. Probe the rest of
  the spec as budget allows — a pre-existing method that fails was already
  failing on main and is a finding, not a regression this PR introduced. Say
  which is which in the report.
- **Phase 10 fixer:** any fix it applies is itself a change to a pre-existing
  entry, so it must be **appended to the plan** with its evidence before B6b's
  guard is re-run. Re-run the guard after Phase 10 — that is the run's last word
  on what actually changed.

Phase 12's checklist gets two extra lines for update mode:

```text
#### Update scope
- ✓ Additions declared and applied                       (B6b check_update_diff: <n> added)
- ✓ Corrections declared with evidence                   (B6b: <n> modified, all with sources)
- ✓ Nothing removed                                      (guard refuses deletion unconditionally)
- ☐ Own-index EXTRA methods reviewed                     (<n> methods the docs no longer list — human call)
```

## The PR

Update mode's PR amends a file others depend on, so the body leads with the
change table, not with prose. Write `pr_body.md` at the repo root:

```markdown
## Update spec: <Chain> (<INDEX>)

> Re-researched from the chain's current docs and diffed against the committed
> spec. Additions and corrections only — nothing was removed.

| | Count |
|---|---|
| Methods added | <n> |
| Collections / extensions / directives added | <n> |
| Values corrected | <n> |
| Reported, not changed | <n> |

<!-- disabled-count: <distinct methods shipping enabled:false> -->

### Added
| Target | Source |
|---|---|
<one row per ADD row in the plan>

### Corrected
| Target | Field | Old → New | Evidence |
|---|---|---|---|
<one row per MODIFY row in the plan>

### Reported, not changed
<own-index EXTRA methods, refused disables, parent-fit findings — each with why>

### Guard output
<the RESULT line from check_update_diff.sh>

<!-- ENDPOINTS
mainnet: <comma-separated mainnet RPC URLs probed>
testnet: <comma-separated testnet RPC URLs, or blank>
-->
```

In a **CI run** (`create_spec.yml` with `mode: update`) stop here: the workflow
commits, pushes and opens the PR, and `spec_pipeline.yml` runs Phases 8–11
against it automatically.

In an **interactive run** the skill still performs no git operations. Print the
commands for the user to run, with the branch name filled in:

```bash
git checkout -b update/<chain>-spec
git add <SPEC_FILE>
git commit -m "feat(spec): add missing <Chain> methods and correct drift"
git push -u origin update/<chain>-spec
gh pr create --base main --title "feat(spec): update <Chain> spec" --body-file pr_body.md
```

Tell the user the last command starts the billed spec pipeline on the PR.

END-OF-PHASE1B-UPDATE-SENTINEL
