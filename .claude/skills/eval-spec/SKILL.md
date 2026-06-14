---
name: eval-spec
description: "Eval/tune loop for the create-spec skill. Generates batches of specs against ground-truth chains, scores them with an LLM-judged rubric, and autonomously tunes create-spec's agent prompts and synthesis rules until scores converge. Use when the user says \"eval the create-spec skill\", \"tune create-spec\", \"run the autoresearch loop on create-spec\", or wants to measure create-spec output quality across a batch of chains."
---

# Eval/Tune Loop for `/create-spec`

This skill implements an autoresearch-style eval/tune loop that continuously improves the `/create-spec` skill. Each iteration generates a batch of specs using the current skill, scores them against upstream ground truth from the public Magma-Devs `lava-specs` repository, identifies weaknesses, and dispatches a tuner agent to make one targeted improvement. The loop runs autonomously for up to 30 iterations (or 2 hours), converging when the last 3 consecutive batch averages all exceed 85.

## Pattern Reference

Inspired by [karpathy/autoresearch](https://github.com/karpathy/autoresearch) — an autonomous AI research loop where an agent modifies code, runs an experiment, measures a metric, and keeps or discards changes.

| autoresearch | eval-spec | Notes |
|-------------|-----------|-------|
| `train.py` (one file to modify) | `create-spec/` skill files | Tuner edits one file per iteration |
| `uv run train.py` (run experiment) | Generate 7 specs via `/create-spec` (phases 3–7 only) | Batch generation replaces single run |
| `val_bpb` (objective metric) | Weighted rubric score (0–100) | Our metric is LLM-evaluated — see Limitations |
| Keep/discard based on metric | Tuner makes one targeted edit | Always keeps edits (no revert on regression) |
| `LOOP FOREVER` | Min 8, max 30 iterations or 2h | Convergence check: 3 consecutive batches > 85 |

### Limitations vs autoresearch

In autoresearch, the eval is **objective** — run the code, measure the output. Our eval requires **LLM judgment** because scoring categories like method coverage need understanding of whether "extra" methods are legitimate official APIs or hallucinations. This means:

- Evaluation costs tokens (haiku/sonnet evaluator agents per spec)
- Scores have variance between runs (LLM non-determinism), but only on the deep tier — see below

The category arithmetic itself is **not** left to the LLM: `scripts/compare_spec.sh` deterministically computes all five category scores (set-diff, recall/precision/F1, exact-match, weighted total) from the two spec files, and the evaluator agent runs it as its authoritative baseline (`spec-evaluator.md` Step 2.6). So the **fast tier is fully deterministic**. LLM judgment enters only on the **deep tier**, and only for the two calls the script cannot make from static files: "is an extra method real or hallucinated?" and "is the upstream value stale?" — each backed by a live RPC probe. A structural pre-gate (the rubric's gate checks) provides an objective pass/fail layer on top.

---

## Repositories

| Repository | URL | Role |
|------------|-----|------|
| Public lava-specs | https://github.com/Magma-Devs/lava-specs | Ground truth for evaluation |

Locate the local clone by git remote scan. The skill checks a few common parent directories and honors `$LAVA_SPECS_REPO` if set:

```bash
PUBLIC_REPO="${LAVA_SPECS_REPO:-}"
if [ -z "$PUBLIC_REPO" ]; then
  PUBLIC_REPO=$(find ~/projects ~/Documents/git ~/code ~/src -maxdepth 5 -name .git \
    -exec sh -c 'git -C "$(dirname "{}")" remote -v 2>/dev/null | grep -q "Magma-Devs/lava-specs" && dirname "{}"' \; \
    2>/dev/null | head -n1)
fi
[ -n "$PUBLIC_REPO" ] || { echo "ERROR: lava-specs clone not found; set LAVA_SPECS_REPO=<path>"; exit 1; }
```

Store the result as `PUBLIC_REPO`.

---

## Reference Files

| File | When to read |
|------|--------------|
| `references/eval-rubric.md` | Step 3 — pass full contents to evaluator agents |
| `references/chain-families.md` | Step 1 — batch selection by family |
| `references/agents/spec-evaluator.md` | Step 3 — evaluator agent prompt template |
| `references/agents/skill-tuner.md` | Step 5 — tuner agent prompt template |

All paths relative to `.claude/skills/eval-spec/` in the repo root.

---

## Skill Under Test

| Artifact | Path |
|----------|------|
| Main skill | `.claude/skills/create-spec/SKILL.md` |
| Phase reference files | `.claude/skills/create-spec/references/phase*.md` |
| Appendix / pitfalls | `.claude/skills/create-spec/references/appendix-reference-tables.md`, `common-pitfalls.md` |
| Agent prompts | `.claude/skills/create-spec/references/agents/*.md` |

All paths relative to the repo root (`git rev-parse --show-toplevel`).

The tuner edits files under `.claude/skills/create-spec/` directly. The list of editable files is documented in `references/agents/skill-tuner.md` (the file the tuner agent reads at Step 5).

---

## Loop Workflow

### Step 0: Setup

1. Record start time:
   ```bash
   START_TIME=$(date +%s)
   ```

2. Backup the current skill:
   ```bash
   REPO_ROOT=$(git rev-parse --show-toplevel)
   BACKUP_DIR="$REPO_ROOT/.claude/skills/create-spec.backup-$(date +%Y%m%d-%H%M)"
   cp -r "$REPO_ROOT/.claude/skills/create-spec" "$BACKUP_DIR"
   echo "Backup at: $BACKUP_DIR"
   ```

3. Locate the public lava-specs repo via the bash block under "Repositories" above. Store as `PUBLIC_REPO`.

4. Pull latest ground truth:
   ```bash
   git -C "$PUBLIC_REPO" pull origin main
   ```

5. Create the output directory:
   ```bash
   mkdir -p /tmp/eval-spec
   ```

6. Initialize loop state:
   - `iteration = 0`
   - `score_history = []`
   - `tested_chains = []`
   - `changes_log = []`

---

### Step 1: Batch Selection

Read `references/chain-families.md`. Select **7 chains** for this iteration:
- 1 EVM chain
- 1 UTXO chain
- 1 Cosmos chain
- 4 chains from any family

Prefer chains not yet in `tested_chains`. No duplicates within the batch.

For each selected chain, extract BOTH the mainnet and testnet spec indices from the public repo (`/create-spec` requires both):

```bash
jq -r '.proposal.specs | map({index, name})' "$PUBLIC_REPO/<chain>.json"
```

Identify which entry is mainnet (typically `.proposal.specs[0]`) and which is testnet (typically `.proposal.specs[1]`, or any entry whose `index` ends in `T` / `S` or whose `name` contains "testnet"). Record both indices per chain.

If a ground-truth file has only one entry (mainnet-only chain in the public repo), skip that chain and pick another from the same family — `/create-spec` requires a testnet index in Phase 2.

The generator agents receive **only** `chain_name`, `mainnet_index`, and `testnet_index` — no other metadata. Researcher agents inside `/create-spec` discover everything else.

---

### Step 2: Parallel Spec Generation (7 agents, 15-min timeout)

Create the iteration output directory:

```bash
mkdir -p /tmp/eval-spec/$iteration
```

Dispatch **7 agents simultaneously**:
- **Model:** sonnet
- **subagent_type:** general-purpose
- **Timeout:** 900000 ms (15 minutes — `/create-spec`'s research + synthesis phases take longer than the eval-lava-spec equivalent because of the union-enforced method discovery and Phase 5 inheritance probe)
- **run_in_background:** true

Prompt template (fill `{chain_name}`, `{mainnet_index}`, `{testnet_index}`, `{iteration}` per agent):

```
You are generating a Lava spec for: {chain_name}
Mainnet spec index:  {mainnet_index}
Testnet spec index:  {testnet_index}

Read the orchestrator and reference files for the create-spec skill (paths relative to repo root):

- .claude/skills/create-spec/SKILL.md
- .claude/skills/create-spec/references/phase1-research.md
- .claude/skills/create-spec/references/phase2-network-params.md
- .claude/skills/create-spec/references/phase3.1-inheritance.md
- .claude/skills/create-spec/references/phase3.2-api-methods-configuration.md
- .claude/skills/create-spec/references/phase3.3-api-collections.md
- .claude/skills/create-spec/references/phase3.4-parse-directives-and-extensions.md
- .claude/skills/create-spec/references/appendix-reference-tables.md
- .claude/skills/create-spec/references/common-pitfalls.md
- .claude/skills/create-spec/references/agents/api-docs-researcher.md
- .claude/skills/create-spec/references/agents/chain-metadata-researcher.md
- .claude/skills/create-spec/references/agents/upstream-spec-scout.md
- .claude/skills/create-spec/references/agents/plugin-researcher.md

Honor the skill's full-read sentinel enforcement (read each reference file to its END-OF-*-SENTINEL).

Follow the workflow with these overrides for autonomous eval mode:
- Phase 1 (Pre-flight): SKIP — chain inputs are provided above
- Phase 2 (Gather inputs): SKIP — inputs already known
- Phase 3 (Parallel research): EXECUTE — dispatch the 4 research agents in parallel
- Phase 4 (Synthesis): EXECUTE — emit the calculations table, then apply all synthesis rules (A–G) and the refuse-to-write pre-write gate
- Phase 5 (Inheritance audit): EXECUTE conditionally — only if mainnet draft's `imports` array is non-empty
- Phase 6 (Completeness checklist): EXECUTE
- Phase 7 (Write & jq validation): EXECUTE BUT override the output path (see below)
- Phase 8 (Smart-router boot + probe): SKIP entirely — not part of eval scoring
- Phase 9 (Parallel reviewers): SKIP
- Phase 10 (Synthesize gaps + fix pass): SKIP
- Phase 10b (Smoke regression): SKIP
- Phase 11 (Final reviewer): SKIP
- Phase 12 (Summary checklist): SKIP

OUTPUT PATH OVERRIDE: write the final spec JSON to
  /tmp/eval-spec/{iteration}/{chain_name}.json
instead of the repo-root `<chain>.json`.

Treat all "ask the user" / "STOP for user review" / "wait for user to challenge the table" instructions as no-ops — print the requested artifact (e.g. the calculations table, pre-write summary) to your own output for the audit trail, then proceed without waiting.

After writing, run `jq . /tmp/eval-spec/{iteration}/{chain_name}.json > /dev/null` to confirm valid JSON. If it fails, fix and re-write until exit 0.

Do NOT invoke /review-spec, /review-and-fix-spec, or any other skill. Do NOT touch git. Do NOT write a spec to the repo root or anywhere outside /tmp/eval-spec/.
```

For any agent that times out, write an empty placeholder so Step 3 can still process all 7:
```bash
echo '{}' > /tmp/eval-spec/$iteration/<chain>.json
```

Append all 7 chain names to `tested_chains`.

---

### Step 3: Parallel Evaluation (7 agents)

Read the full contents of:
- `references/eval-rubric.md`
- `references/agents/spec-evaluator.md`

**Tier cadence (decide `deep_probe` for this iteration before dispatching):**

The two tiers trade speed for precision (see `spec-evaluator.md` Step 2.5). Run the **fast tier every iteration** (cheap, stable — it drives tuning) and the **deep tier periodically** (evaluator discovers free public RPCs itself and live-probes — audits that the metric isn't merely conforming to a stale upstream spec):

```
deep_probe = (iteration % 5 == 0) OR (previous batch average > 85)
```

- The `% 5` cadence is a periodic live audit; the `> 85` clause forces a deep pass **before accepting convergence**. **Never declare convergence on a batch that ran fast-tier only** — if a fast-tier batch crosses the threshold, re-run it with `deep_probe = true` and use the deep scores for the convergence check.
- Deep-tier iterations are slower (web discovery + concurrent probes) and require stronger reasoning, so they use a larger model (below).

Dispatch **7 evaluator agents simultaneously**:
- **Model:** `sonnet` when `deep_probe` is true (RPC discovery + judgment), else `haiku`
- **subagent_type:** general-purpose
- **run_in_background:** true

Prompt template (fill `{chain_name}`, `{iteration}`, `{PUBLIC_REPO}`, `{deep_probe}` per agent; inline rubric and instructions):

```
You are evaluating a generated Lava spec against ground truth.

Chain: {chain_name}
Generated spec: /tmp/eval-spec/{iteration}/{chain_name}.json
Upstream spec: {PUBLIC_REPO}/{chain_name}.json
deep_probe: {deep_probe}   # true → run Step 2.5 live probe (discover your own free RPCs); false/absent → fast tier

## Rubric
{contents of eval-rubric.md}

## Instructions
{contents of spec-evaluator.md}

Return ONLY a JSON object with the score report. No other text.
```

Collect all 7 results and parse each as JSON. A result that fails JSON parsing is treated as a gate failure (score = 0).

---

### Step 4: Aggregate & Report

Compute metrics across the 7 score reports:

- **batch_avg** — mean of `weighted_total` scores; gate failures count as 0
- **gate_pass_count** — number of specs that passed all hard gates
- **per_category_avg** — mean per rubric category: `parse_directives`, `method_coverage`, `chain_metadata`, `verifications`, `plugins_extensions`
- **tier** — `"deep"` if this iteration ran `deep_probe = true` (and at least one evaluator actually probed), else `"fast"`. Record it on the `score_history` entry — the Step 6 convergence check requires the last 3 batches to be `deep`.

Log format (print to user and append to `score_history`):

```
Iteration {N} [{tier}]: batch_avg={score} | gate_pass={X}/7 | parse={X} method={X} meta={X} verify={X} plugin={X}
  FAIL: {chain} ({reason})
  LOW:  {chain} ({category}: {score} — {detail})
  BEST: {chain} ({score})
```

---

### Step 5: Autonomous Tuning

Read `references/agents/skill-tuner.md`. Dispatch a single tuner agent:
- **Model:** opus
- **subagent_type:** general-purpose

Prompt includes:
- Full `score_history` JSON
- All 7 score reports from the current iteration
- Full contents of `references/agents/skill-tuner.md`
- Instruction: analyze the failures and low scores, then make **ONE targeted edit** to a file under `.claude/skills/create-spec/` (see the editable-files table in the tuner prompt)

The tuner agent reads and edits files under `.claude/skills/create-spec/` (relative to repo root) directly.

After the tuner completes, log its change report to `changes_log`:

```json
{ "iteration": N, "file": "<path>", "what": "<description>", "expected_impact": "<hypothesis>" }
```

---

### Step 6: Check Stopping Criteria

```
if iteration < 8:
    continue → Step 1

elif (len(score_history) >= 3
      and all(s.batch_avg > 85 for s in score_history[-3:])
      and all(s.tier == "deep" for s in score_history[-3:])):   # convergence must be confirmed on deep-tier scores, not fast-tier-only
    stop → reason = "success"

elif iteration >= 30:
    stop → reason = "max_iterations"

elif (time.now() - START_TIME) > 7200:
    stop → reason = "time_budget"

else:
    continue → Step 1
```

Increment `iteration`. Loop back to Step 1.

---

### Step 7: Final Report

Generate a summary and print it to the user. Then save it to `/tmp/eval-spec/final-report.md`.

**Report sections:**

**Header**
- Status: `success` | `max_iterations` | `time_budget`
- Iterations run
- Duration (seconds)
- Backup path

**Score Trajectory**

| Iteration | batch_avg | gate_pass | parse | method | meta | verify | plugin |
|-----------|-----------|-----------|-------|--------|------|--------|--------|
| 0         | ...       | ...       | ...   | ...    | ...  | ...    | ...    |
| ...       |           |           |       |        |      |        |        |

**Per-Family Trends**

| Family | First Score | Last Score | Trend |
|--------|-------------|------------|-------|
| EVM    | ...         | ...        | ↑/↓/→ |
| UTXO   | ...         | ...        | ...   |
| Cosmos | ...         | ...        | ...   |

**Changes Log**

| Iteration | File | What Changed | Expected Impact |
|-----------|------|--------------|-----------------|
| ...       | ...  | ...          | ...             |

**Remaining Weaknesses**

Bullet list of categories or chain families still scoring below 80.

**Recommendation**

One of:
- `keep tuned` — scores consistently above 85, changes stable
- `rollback` — scores degraded after tuning; restore from backup path
- `manual intervention` — loop converged but specific weakness requires human review

---

## Out of scope

- Editing `eval-lava-spec/` or any skill other than `create-spec/`
- Running `/create-spec`'s Phase 8 smart-router boot during eval (not part of scoring)
- Any git operations (`git add`, `git commit`, `git push`) — user handles git manually
- Writing a spec to the repo root or anywhere outside `/tmp/eval-spec/` during generation

If the user asks for any of these, surface the limitation and confirm scope before continuing.
