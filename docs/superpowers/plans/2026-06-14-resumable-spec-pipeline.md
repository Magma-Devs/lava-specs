# Resumable Spec Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the monolithic `create_spec.yml` so a Phase 8+ failure is resumable with amended input (node URLs, docs, hints) via a PR-comment command, instead of re-running the ~1.5h pipeline from Phase 1.

**Architecture:** `create_spec.yml` runs Phases 1-7 and opens the PR with a consolidated PAT (`GHCR_PAT`). A new `spec_pipeline.yml` runs Phases 8→11→summary as one `claude-code-action` job, triggered by `pull_request: opened` (auto) and `issue_comment: created` (human `/rerun-*` command). The PR is the state store: the spec is on the branch, each phase posts its report as a PR comment, and a resumed phase reconstructs context by reading the committed spec + prior comments. Two small bash scripts (a comment-command parser and an endpoint resolver) carry the deterministic logic and are unit-tested in isolation.

**Tech Stack:** GitHub Actions YAML, `anthropics/claude-code-action@v1`, Bash, `gh` CLI, the `create-spec` Claude skill (markdown), Docker + GHCR smart-router image.

**Spec:** `docs/superpowers/specs/2026-06-14-resumable-spec-pipeline-design.md`

---

## File Structure

| File | Responsibility |
|---|---|
| `.github/scripts/parse_rerun_command.sh` | **Create.** Parse a PR comment body → `START_PHASE`, resolved `MAINNET_URLS`/`TESTNET_URLS`, `HINTS`, `IS_COMMAND`. Resolves `use=SECRET` against an env allow-list. |
| `.github/scripts/resolve_endpoints.sh` | **Create.** Pick the endpoint set Phase 8 boots against: comment override → `pr_body.md` ENDPOINTS block → self-research. |
| `.github/scripts/tests/test_parse_rerun_command.sh` | **Create.** Plain-bash unit tests for the parser. |
| `.github/scripts/tests/test_resolve_endpoints.sh` | **Create.** Plain-bash unit tests for the resolver. |
| `.claude/skills/create-spec/references/phase-entrypoints.md` | **Create.** Re-entry contract per resumable phase (8/9/10/11): what to read from the branch + PR comments, http+ws probing, post-comment-per-phase. Ends with a sentinel. |
| `.claude/skills/create-spec/SKILL.md` | **Modify.** Add a "Resumable entry points" section, relaxed sentinel-gating rule, note that CI's create run stops at Phase 7. |
| `.github/workflows/create_spec.yml` | **Modify.** Open PR with `GHCR_PAT`; trim the agent prompt to Phases 1-7; emit a machine-parseable ENDPOINTS block in `pr_body.md`; drop the docker/GHCR/probe-tools steps (moved to the pipeline). |
| `.github/workflows/spec_pipeline.yml` | **Create.** The Phases 8→11→summary workflow: triggers, command parse, endpoint resolve, checkout PR branch, GHCR login, probe tools, `claude-code-action`, failure comment. |

No test framework is assumed. Bash scripts are tested with plain-bash assertion files (run with `bash <file>`, exit non-zero on failure). YAML is validated with `python3 -c 'import yaml…'` + structural `grep`. Skill markdown is validated by sentinel + heading `grep` assertions.

---

## Task 1: Comment-command parser script

**Files:**
- Create: `.github/scripts/parse_rerun_command.sh`
- Test: `.github/scripts/tests/test_parse_rerun_command.sh`

- [ ] **Step 1: Write the failing test**

Create `.github/scripts/tests/test_parse_rerun_command.sh`:

```bash
#!/usr/bin/env bash
# Unit tests for parse_rerun_command.sh. Exit non-zero on any failure.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/parse_rerun_command.sh"
fail=0
check() { # $1=label  $2=expected substring  $3=actual
  if printf '%s' "$3" | grep -qF -- "$2"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"; echo "    want substring: $2"; echo "    got: $3"; fail=1
  fi
}
expect_exit() { # $1=label $2=want-code $3=actual-code
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 (want exit $2 got $3)"; fail=1; fi
}

# 1. /rerun-probe with a raw https url
out="$(ALLOWED_SECRETS="" bash "$SCRIPT" "/rerun-probe mainnet=https://a.example/rpc")"
check "probe -> phase 8"      "START_PHASE=8"                 "$out"
check "probe -> is command"   "IS_COMMAND=true"              "$out"
check "probe -> mainnet url"  "MAINNET_URLS=https://a.example/rpc" "$out"

# 2. comma list + testnet + trailing hint text
out="$(ALLOWED_SECRETS="" bash "$SCRIPT" "/rerun-probe mainnet=https://a,https://b testnet=https://t archive node please")"
check "two mainnet urls" "MAINNET_URLS=https://a,https://b" "$out"
check "testnet url"      "TESTNET_URLS=https://t"           "$out"
check "hints captured"   "HINTS=archive node please"        "$out"

# 3. use=SECRET resolves from env when allow-listed
out="$(ALLOWED_SECRETS="PAID_RPC_1" PAID_RPC_1="https://paid/v3/KEY" bash "$SCRIPT" "/rerun-probe mainnet=use=PAID_RPC_1")"
check "secret resolved" "MAINNET_URLS=https://paid/v3/KEY" "$out"

# 4. use=SECRET not in allow-list -> exit 2
ALLOWED_SECRETS="" PAID_RPC_1="x" bash "$SCRIPT" "/rerun-probe mainnet=use=PAID_RPC_1" >/dev/null 2>&1
expect_exit "secret not allow-listed -> exit 2" 2 "$?"

# 5. non-command body -> IS_COMMAND=false, exit 0
out="$(bash "$SCRIPT" "thanks, looks good")"; code=$?
check "non-command -> false" "IS_COMMAND=false" "$out"
expect_exit "non-command -> exit 0" 0 "$code"

# 6. command aliases map to phases
for pair in "rerun-review 9" "rerun-fix 10" "rerun-final 11"; do
  set -- $pair
  out="$(bash "$SCRIPT" "/$1")"
  check "/$1 -> phase $2" "START_PHASE=$2" "$out"
done

# 7. /rerun-from with explicit phase, and a bad phase
out="$(bash "$SCRIPT" "/rerun-from 10")"; check "rerun-from 10" "START_PHASE=10" "$out"
bash "$SCRIPT" "/rerun-from 99" >/dev/null 2>&1; expect_exit "rerun-from 99 -> exit 2" 2 "$?"

exit $fail
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash .github/scripts/tests/test_parse_rerun_command.sh`
Expected: FAIL — script does not exist (`No such file or directory`), non-zero exit.

- [ ] **Step 3: Write the parser**

Create `.github/scripts/parse_rerun_command.sh`:

```bash
#!/usr/bin/env bash
# Parse a PR comment body for a /rerun-* command.
# Usage: parse_rerun_command.sh "<comment body>"   (or body on stdin)
# Emits KEY=VALUE lines on stdout. Resolves `use=SECRET` tokens against the
# space-separated allow-list in $ALLOWED_SECRETS, reading the value from the
# same-named environment variable. Exit 2 on a malformed command/secret.
set -uo pipefail

body="${1:-$(cat)}"
body_flat="$(printf '%s' "$body" | tr '\n' ' ')"
first_line="$(printf '%s\n' "$body" | head -n1)"
cmd="$(printf '%s' "$first_line" | awk '{print $1}')"

emit() { printf '%s=%s\n' "$1" "$2"; }

case "$cmd" in
  /rerun-probe)  start=8 ;;
  /rerun-review) start=9 ;;
  /rerun-fix)    start=10 ;;
  /rerun-final)  start=11 ;;
  /rerun-from)
    start="$(printf '%s' "$first_line" | awk '{print $2}')"
    case "$start" in
      8|9|10|11) ;;
      *) echo "ERROR: /rerun-from needs a phase in {8,9,10,11}, got '$start'" >&2; exit 2 ;;
    esac ;;
  *)
    emit IS_COMMAND false
    exit 0 ;;
esac

emit IS_COMMAND true
emit START_PHASE "$start"

resolve_token() { # echo resolved URL for one token (raw url | use=NAME)
  local tok="$1" name val
  case "$tok" in
    use=*)
      name="${tok#use=}"
      printf '%s' "$name" | grep -qE '^[A-Z0-9_]+$' || { echo "ERROR: bad secret name '$name'" >&2; exit 2; }
      case " ${ALLOWED_SECRETS:-} " in
        *" $name "*) ;;
        *) echo "ERROR: secret '$name' not in ALLOWED_SECRETS" >&2; exit 2 ;;
      esac
      val="$(eval "printf '%s' \"\${$name:-}\"")"
      [ -n "$val" ] || { echo "ERROR: secret '$name' is empty/unset" >&2; exit 2; }
      printf '%s' "$val" ;;
    http://*|https://*|ws://*|wss://*) printf '%s' "$tok" ;;
    *) echo "ERROR: token '$tok' is neither a url nor use=SECRET" >&2; exit 2 ;;
  esac
}

collect() { # $1 = key (mainnet|testnet) -> comma-joined resolved urls
  local key="$1" out="" t v
  for t in $body_flat; do
    case "$t" in
      ${key}=*)
        v="$(resolve_token "${t#${key}=}")" || exit 2
        out="${out:+$out,}$v" ;;
    esac
  done
  printf '%s' "$out"
}

emit MAINNET_URLS "$(collect mainnet)"
emit TESTNET_URLS "$(collect testnet)"

hints="$(printf '%s' "$body_flat" \
  | sed -E 's#/rerun-(probe|review|fix|final)##; s#/rerun-from[[:space:]]+[0-9]+##' \
  | sed -E 's#(mainnet|testnet)=[^[:space:]]+##g' \
  | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
emit HINTS "$hints"
```

Make it executable: `chmod +x .github/scripts/parse_rerun_command.sh`

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash .github/scripts/tests/test_parse_rerun_command.sh`
Expected: every line `ok - …`, exit 0.

- [ ] **Step 5: Commit**

```bash
chmod +x .github/scripts/parse_rerun_command.sh
git add .github/scripts/parse_rerun_command.sh .github/scripts/tests/test_parse_rerun_command.sh
git commit -m "feat(ci): add /rerun-* PR-comment command parser"
```

---

## Task 2: Endpoint resolver script

**Files:**
- Create: `.github/scripts/resolve_endpoints.sh`
- Test: `.github/scripts/tests/test_resolve_endpoints.sh`

- [ ] **Step 1: Write the failing test**

Create `.github/scripts/tests/test_resolve_endpoints.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/resolve_endpoints.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
check() { if printf '%s' "$3" | grep -qF -- "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; echo "  want: $2"; echo "  got: $3"; fail=1; fi; }

# pr_body fixture with a machine-readable ENDPOINTS block
cat > "$TMP/pr_body.md" <<'EOF'
## New chain spec: Iota
<!-- ENDPOINTS
mainnet: https://body-main/rpc
testnet: https://body-test/rpc
-->
body text
EOF

# 1. comment override wins over pr_body
out="$(COMMENT_MAINNET="https://cli-main" COMMENT_TESTNET="" PR_BODY_FILE="$TMP/pr_body.md" bash "$SCRIPT")"
check "comment source"     "ENDPOINT_SOURCE=comment"          "$out"
check "comment mainnet"     "MAINNET_URLS=https://cli-main"    "$out"

# 2. no comment -> pr_body block used
out="$(COMMENT_MAINNET="" COMMENT_TESTNET="" PR_BODY_FILE="$TMP/pr_body.md" bash "$SCRIPT")"
check "pr_body source"      "ENDPOINT_SOURCE=pr_body"          "$out"
check "pr_body mainnet"     "MAINNET_URLS=https://body-main/rpc" "$out"
check "pr_body testnet"     "TESTNET_URLS=https://body-test/rpc" "$out"

# 3. no comment, no parseable block -> self_research
echo "no endpoints here" > "$TMP/empty.md"
out="$(COMMENT_MAINNET="" COMMENT_TESTNET="" PR_BODY_FILE="$TMP/empty.md" bash "$SCRIPT")"
check "self_research source" "ENDPOINT_SOURCE=self_research"   "$out"

exit $fail
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash .github/scripts/tests/test_resolve_endpoints.sh`
Expected: FAIL — script missing, non-zero exit.

- [ ] **Step 3: Write the resolver**

Create `.github/scripts/resolve_endpoints.sh`:

```bash
#!/usr/bin/env bash
# Resolve the endpoint set Phase 8 boots against.
# Precedence: comment override > pr_body ENDPOINTS block > self-research.
# Inputs (env): COMMENT_MAINNET, COMMENT_TESTNET (may be empty), PR_BODY_FILE.
# Emits ENDPOINT_SOURCE / MAINNET_URLS / TESTNET_URLS. ws is NOT a separate
# input: each URL is probed over http AND ws by the skill (see phase-entrypoints.md).
set -uo pipefail

mainnet="${COMMENT_MAINNET:-}"
testnet="${COMMENT_TESTNET:-}"
source_label="comment"

if [ -z "$mainnet" ] && [ -z "$testnet" ]; then
  source_label="pr_body"
  if [ -n "${PR_BODY_FILE:-}" ] && [ -f "$PR_BODY_FILE" ]; then
    block="$(awk '/<!-- ENDPOINTS/{f=1;next} /-->/{f=0} f' "$PR_BODY_FILE")"
    mainnet="$(printf '%s\n' "$block" | sed -nE 's/^mainnet:[[:space:]]*//p' | tr -d ' ')"
    testnet="$(printf '%s\n' "$block" | sed -nE 's/^testnet:[[:space:]]*//p' | tr -d ' ')"
  fi
fi

if [ -z "$mainnet" ] && [ -z "$testnet" ]; then
  source_label="self_research"
fi

printf 'ENDPOINT_SOURCE=%s\n' "$source_label"
printf 'MAINNET_URLS=%s\n' "$mainnet"
printf 'TESTNET_URLS=%s\n' "$testnet"
```

Make it executable: `chmod +x .github/scripts/resolve_endpoints.sh`

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash .github/scripts/tests/test_resolve_endpoints.sh`
Expected: all `ok - …`, exit 0.

- [ ] **Step 5: Commit**

```bash
chmod +x .github/scripts/resolve_endpoints.sh
git add .github/scripts/resolve_endpoints.sh .github/scripts/tests/test_resolve_endpoints.sh
git commit -m "feat(ci): add Phase 8 endpoint resolver (comment > pr_body > research)"
```

---

## Task 3: Skill re-entry contract reference file

**Files:**
- Create: `.claude/skills/create-spec/references/phase-entrypoints.md`

- [ ] **Step 1: Write the failing structural test**

Run this assertion (it fails until the file exists with the required anchors):

```bash
F=.claude/skills/create-spec/references/phase-entrypoints.md
grep -q "END-OF-PHASE-ENTRYPOINTS-SENTINEL" "$F" \
 && grep -q "## Entry: Phase 8" "$F" \
 && grep -q "## Entry: Phase 9" "$F" \
 && grep -q "## Entry: Phase 10" "$F" \
 && grep -q "## Entry: Phase 11" "$F" \
 && grep -q "gh pr comment" "$F" \
 && echo PASS || echo FAIL
```

Expected: `FAIL` (file absent).

- [ ] **Step 2: Write the reference file**

Create `.claude/skills/create-spec/references/phase-entrypoints.md`:

````markdown
# Resumable phase entry points (CI pipeline)

The `spec_pipeline.yml` workflow invokes this skill **mid-pipeline** so a failed
phase can be re-run with amended input instead of restarting from Phase 1. When
the orchestrator prompt says **"Start at Phase N"**, do NOT run Phases 1-7. Instead
reconstruct context from committed state and run Phase N → end.

## Inputs the workflow passes in the prompt

- `START_PHASE` — one of 8, 9, 10, 11.
- `PR_NUMBER` — the open PR for this chain; the spec is the committed `<chain>.json`
  on the checked-out branch.
- `MAINNET_URLS`, `TESTNET_URLS` — comma-separated endpoint lists already resolved
  by the workflow (comment override > PR body > empty). If both are empty, research
  public nodes yourself exactly as the normal Phase 3/8 flow would.
- `ADDITIONAL_DATA` — free-text hints (docs URLs, corrections) from the triggering
  comment; treat it like the Phase 2 `additional_data` input.

## Context reconstruction (do this first, every entry)

1. Read the committed spec: `cat <chain>.json` (filename = mainnet index lowercased).
   Derive `<chain>`, `<INDEX>`, `<INTERFACE>` from it — do NOT re-derive from research.
2. Pull prior phase outputs from the PR comments instead of regenerating them:
   ```bash
   gh pr view "$PR_NUMBER" --json comments --jq '.comments[].body'
   ```
   The probe report, reviews, and fix logs from earlier phases were each posted as a
   comment by a prior run. Use the most recent of each kind.

## Endpoint probing — http AND ws

Every resolved URL is probed over BOTH transports: request/response methods over
http(s), subscription methods over ws(s). There is no separate ws input. If a node
serves only one transport (e.g. a ws-only provider), keep whichever transport it
answers and rely on the other listed URLs for the rest. Only if the spec enables any
`category.subscription` method AND no provided URL answers ws: STOP and post a PR
comment requesting a ws-capable node — do not let the router die with the opaque
`all static providers failed verification`.

## Post each phase's result as a PR comment

After a phase completes, post its report so the PR thread is the running log:

```bash
gh pr comment "$PR_NUMBER" --body-file docs/<chain>/METHOD_PROBE_REPORT.md
```

Use a one-line bold header per comment so phases are scannable, e.g.
`**Phase 8 — smart-router probe**` then the report body. On a hard failure, post a
comment naming the failure and the exact `/rerun-*` command that would retry it.

## Entry: Phase 8 (smart-router boot + probe)

Reconstruct context, then run Phase 8 of `SKILL.md` against `MAINNET_URLS` /
`TESTNET_URLS` (probing http+ws). Post `docs/<chain>/METHOD_PROBE_REPORT.md` as a PR
comment. Then continue to Phase 9 → 10 → 10b → 11 → summary unless a phase hard-fails.

## Entry: Phase 9 (parallel reviewers)

Read `<chain>.json` and the latest Phase 8 probe-report comment. Run Phase 9 of
`SKILL.md`. Post a combined reviewers comment (the three TALLY lines + merged gaps).
Continue to Phase 10.

## Entry: Phase 10 (synthesize gaps + fix + 10b re-probe)

Read `<chain>.json`, the latest reviewers comment, and the latest probe-report
comment. Run Phase 10 + Phase 10b of `SKILL.md`. Post a fix-log comment and the
10b smoke-result comment. Continue to Phase 11.

## Entry: Phase 11 (final reviewer + summary)

Read `<chain>.json` and the latest fix-log comment. Run Phase 11. Post the verdict
(APPROVED / CHANGES REQUESTED with the TALLY) as a PR comment, then post the Phase 12
summary checklist as a final comment. Do NOT halt on CHANGES REQUESTED in CI — record
the verdict honestly and stop after the summary comment.

## Sentinel-gating under partial runs

The full-read enforcement in `SKILL.md` still applies to the reference files for the
phases you WILL execute (Phase N..end). You are NOT required to have observed the
sentinels for Phases 1..N-1, because you are not running them this invocation.

END-OF-PHASE-ENTRYPOINTS-SENTINEL
````

- [ ] **Step 3: Run the structural test to verify it passes**

Run the Step 1 command again.
Expected: `PASS`.

- [ ] **Step 4: Commit**

```bash
git add .claude/skills/create-spec/references/phase-entrypoints.md
git commit -m "feat(create-spec): add resumable phase entry-point contract"
```

---

## Task 4: SKILL.md — wire in the entry points

**Files:**
- Modify: `.claude/skills/create-spec/SKILL.md` (insert a section after the Phase 1 header block, near line 46)

- [ ] **Step 1: Add the entry-points section**

Insert this block immediately BEFORE the `## Phase 1 — Pre-flight` line (line 46):

```markdown
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

```

- [ ] **Step 2: Verify the insertion**

Run:
```bash
grep -n "## Resumable entry points" .claude/skills/create-spec/SKILL.md
grep -n "phase-entrypoints.md" .claude/skills/create-spec/SKILL.md
```
Expected: both print a line number; the "Resumable entry points" heading appears before `## Phase 1`.

- [ ] **Step 3: Commit**

```bash
git add .claude/skills/create-spec/SKILL.md
git commit -m "docs(create-spec): document resumable entry points in SKILL.md"
```

---

## Task 5: create_spec.yml — Phases 1-7 only, PAT, ENDPOINTS block

**Files:**
- Modify: `.github/workflows/create_spec.yml`

- [ ] **Step 1: Switch PR creation to the PAT**

In the `Open pull request` step (near line 343-345), change the token env from the
built-in token to the consolidated PAT so the `pull_request` event fires for the
pipeline:

Replace:
```yaml
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```
with:
```yaml
        env:
          # PAT (not GITHUB_TOKEN): a GITHUB_TOKEN-opened PR does NOT fire
          # pull_request events, which spec_pipeline.yml needs. One consolidated
          # classic PAT (repo + workflow + read:packages) is stored as GHCR_PAT.
          GH_TOKEN: ${{ secrets.GHCR_PAT }}
```

- [ ] **Step 2: Trim the agent prompt to Phases 1-7**

In the `Run create-spec` step prompt (near line 232-247), replace the
`Execution rules` bullet list's first bullet so the agent stops after Phase 7.

Replace:
```
            - Run the FULL 12-phase pipeline, INCLUDING the Phase 8 smart-router boot and the Phase 10b re-probe.
```
with:
```
            - Run ONLY Phases 1 through 7 (research → network params → synthesis →
              static validation → write <chain>.json → jq validation). STOP after
              Phase 7 produces a jq-valid <chain>.json. Do NOT run Phase 8 or later
              — the spec_pipeline.yml workflow runs the boot/probe/review phases
              after the PR opens. Skip the Phase 9/11 reviewer tables in pr_body.md.
```

- [ ] **Step 3: Add the machine-readable ENDPOINTS block to pr_body.md**

In the same prompt's `pr_body.md` template, in the `### Sources used` section
(near line 275-278), append an HTML-comment ENDPOINTS block the resolver parses.
After the `- **RPC nodes:** …` line, add:

```
            <!-- ENDPOINTS — machine-readable; spec_pipeline.yml resolve_endpoints.sh parses this. -->
            <!-- ENDPOINTS
            mainnet: <comma-separated mainnet RPC URLs you probed, no spaces inside a URL>
            testnet: <comma-separated testnet RPC URLs, or leave blank if none>
            -->
```

(The block is an HTML comment, so it is invisible in the rendered PR but parseable.)

- [ ] **Step 4: Remove the now-unused docker/GHCR/probe-tools steps**

Phases 1-7 do not touch Docker. Delete these three steps (they move to
`spec_pipeline.yml` in Task 6):
- `Install probe tools (for create-spec Phase 8/10b)` (near line 132-139)
- `Log into GHCR (for the smart-router image)` (near line 148-153)
- `Pull + probe smart-router image (pre-flight)` (near line 160-194)

Also drop `packages: read` from the job `permissions:` block (line 63) — the create
job no longer pulls images.

- [ ] **Step 5: Validate the YAML**

Run:
```bash
python3 -c 'import yaml,sys; yaml.safe_load(open(".github/workflows/create_spec.yml")); print("yaml ok")'
grep -c "smart-router image" .github/workflows/create_spec.yml   # expect 0
grep -q "GH_TOKEN: \${{ secrets.GHCR_PAT }}" .github/workflows/create_spec.yml && echo "pat ok"
grep -q "ENDPOINTS" .github/workflows/create_spec.yml && echo "endpoints-block ok"
```
Expected: `yaml ok`, the grep count is `0`, `pat ok`, `endpoints-block ok`.
(If `python3` lacks PyYAML: `pip install --quiet pyyaml` then re-run.)

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/create_spec.yml
git commit -m "feat(ci): create_spec runs Phases 1-7, opens PR with PAT + ENDPOINTS block"
```

---

## Task 6: spec_pipeline.yml — the resumable Phases 8-11 workflow

**Files:**
- Create: `.github/workflows/spec_pipeline.yml`

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/spec_pipeline.yml`:

```yaml
# Runs create-spec Phases 8 -> 11 -> summary against an OPEN PR, as one
# claude-code-action job. Two ways in:
#   - pull_request: opened  -> auto-start the full 8->summary sequence
#   - issue_comment: created with a body starting "/rerun-<phase>" -> re-run
#     that phase to the end, optionally with amended endpoints / hints.
# State lives in the PR: the spec is the committed <chain>.json on the branch;
# every phase posts its report as a PR comment; a resumed phase reconstructs
# context from those comments (see references/phase-entrypoints.md).
#
# Setup: one consolidated classic PAT in secret GHCR_PAT
# (repo + workflow + read:packages) — opens nothing here but authenticates the
# GHCR pull AND is the identity whose PR-open event triggers this workflow.
# Optional paid-node secrets PAID_RPC_1..3 / PAID_WS_1 are referenced from a
# comment as `use=PAID_RPC_1`; only names in ALLOWED_SECRETS below are honored.
name: "Spec Pipeline (Phases 8-11)"

on:
  pull_request:
    types: [opened]
  issue_comment:
    types: [created]

permissions:
  contents: write
  pull-requests: write
  packages: read

concurrency:
  group: spec-pipeline-${{ github.event.pull_request.number || github.event.issue.number }}
  cancel-in-progress: false

jobs:
  pipeline:
    runs-on: ubuntu-latest
    timeout-minutes: 120
    # Run only for: a PR opened by our automation, OR a /rerun-* comment on a PR.
    if: >
      (github.event_name == 'pull_request') ||
      (github.event_name == 'issue_comment' &&
       github.event.issue.pull_request != null &&
       startsWith(github.event.comment.body, '/rerun-'))
    steps:
      - name: Resolve PR ref
        id: pr
        env:
          GH_TOKEN: ${{ secrets.GHCR_PAT }}
        run: |
          set -euo pipefail
          if [ "${{ github.event_name }}" = "pull_request" ]; then
            echo "number=${{ github.event.pull_request.number }}" >> "$GITHUB_OUTPUT"
            echo "head=${{ github.event.pull_request.head.ref }}"   >> "$GITHUB_OUTPUT"
          else
            num="${{ github.event.issue.number }}"
            head="$(gh pr view "$num" --repo "${{ github.repository }}" --json headRefName --jq .headRefName)"
            echo "number=$num"  >> "$GITHUB_OUTPUT"
            echo "head=$head"    >> "$GITHUB_OUTPUT"
          fi

      - name: Checkout PR branch
        uses: actions/checkout@v4
        with:
          ref: ${{ steps.pr.outputs.head }}
          fetch-depth: 0

      - name: Parse rerun command
        id: cmd
        env:
          # Allow-list of secret names a comment may reference via use=NAME.
          ALLOWED_SECRETS: "PAID_RPC_1 PAID_RPC_2 PAID_RPC_3 PAID_WS_1"
          PAID_RPC_1: ${{ secrets.PAID_RPC_1 }}
          PAID_RPC_2: ${{ secrets.PAID_RPC_2 }}
          PAID_RPC_3: ${{ secrets.PAID_RPC_3 }}
          PAID_WS_1:  ${{ secrets.PAID_WS_1 }}
          COMMENT_BODY: ${{ github.event.comment.body }}
        run: |
          set -euo pipefail
          if [ "${{ github.event_name }}" = "pull_request" ]; then
            # Auto-start: no comment, default to Phase 8, no endpoint override.
            {
              echo "IS_COMMAND=true"; echo "START_PHASE=8"
              echo "MAINNET_URLS="; echo "TESTNET_URLS="; echo "HINTS="
            } > /tmp/cmd.env
          else
            bash .github/scripts/parse_rerun_command.sh "$COMMENT_BODY" > /tmp/cmd.env
          fi
          cat /tmp/cmd.env
          # Export each parsed key as a step output.
          while IFS='=' read -r k v; do echo "$k=$v" >> "$GITHUB_OUTPUT"; done < /tmp/cmd.env

      - name: Resolve endpoints
        id: endpoints
        if: steps.cmd.outputs.IS_COMMAND == 'true'
        env:
          COMMENT_MAINNET: ${{ steps.cmd.outputs.MAINNET_URLS }}
          COMMENT_TESTNET: ${{ steps.cmd.outputs.TESTNET_URLS }}
          PR_BODY_FILE: ""   # pr_body.md is a run artifact, not on the branch; see note
        run: |
          set -euo pipefail
          # The PR body lives on GitHub, not the branch. Fetch it so the ENDPOINTS
          # block (written by create_spec.yml) can be parsed as the fallback source.
          gh pr view "${{ steps.pr.outputs.number }}" --repo "${{ github.repository }}" \
            --json body --jq .body > /tmp/pr_body.md || true
          PR_BODY_FILE=/tmp/pr_body.md bash .github/scripts/resolve_endpoints.sh > /tmp/ep.env
          cat /tmp/ep.env
          while IFS='=' read -r k v; do echo "$k=$v" >> "$GITHUB_OUTPUT"; done < /tmp/ep.env
        # gh needs a token:
        # (set GH_TOKEN below via the env on the run shell)

      - name: Setup Node
        if: steps.cmd.outputs.IS_COMMAND == 'true'
        uses: actions/setup-node@v4
        with:
          node-version: "22"

      - name: Install probe tools
        if: steps.cmd.outputs.IS_COMMAND == 'true'
        run: |
          sudo apt-get update
          sudo apt-get install -y jq
          GRPCURL_VERSION=1.9.1
          curl -fsSL "https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION}_linux_x86_64.tar.gz" \
            | sudo tar -xz -C /usr/local/bin grpcurl
          grpcurl --version || true

      - name: Log into GHCR
        if: steps.cmd.outputs.IS_COMMAND == 'true'
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GHCR_PAT || secrets.GITHUB_TOKEN }}

      - name: Run pipeline phases
        id: run
        if: steps.cmd.outputs.IS_COMMAND == 'true'
        uses: anthropics/claude-code-action@v1
        with:
          claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
          github_token: ${{ secrets.GHCR_PAT }}
          show_full_output: false
          display_report: false
          claude_args: |
            --model opus
            --dangerously-skip-permissions
            --max-turns 1000
          prompt: |
            Run the /create-spec skill in RESUMABLE mode for an OPEN pull request.

            Start at Phase ${{ steps.cmd.outputs.START_PHASE }}. Do NOT run Phases
            1-7. Reconstruct context from the committed <chain>.json on this branch
            and the existing PR comments, exactly as
            references/phase-entrypoints.md specifies (read that file fully first).

            Context:
            - PR_NUMBER: ${{ steps.pr.outputs.number }}
            - Repo: ${{ github.repository }}
            - Endpoint source: ${{ steps.endpoints.outputs.ENDPOINT_SOURCE }}
            - MAINNET_URLS: ${{ steps.endpoints.outputs.MAINNET_URLS }}
            - TESTNET_URLS: ${{ steps.endpoints.outputs.TESTNET_URLS }}
            - ADDITIONAL_DATA (hints/docs/corrections): ${{ steps.cmd.outputs.HINTS }}

            Rules for this unattended run:
            - Probe every provided URL over BOTH http and ws (subscription methods
              need ws). If the spec has subscription methods and no URL answers ws,
              STOP and post a PR comment asking for a ws-capable node.
            - If MAINNET_URLS and TESTNET_URLS are both empty, research public nodes
              yourself (the normal Phase 3/8 fallback).
            - After EACH phase, post its report as a PR comment via
              `gh pr comment ${{ steps.pr.outputs.number }} --body-file <report>`,
              with a bold one-line header naming the phase.
            - At every STOP-and-ask gate, auto-decide with the conservative default
              and record it. Report the Phase 11 verdict HONESTLY (never upgrade
              CHANGES REQUESTED to APPROVED).
            - Do NOT perform any git commit/push for the spec content other than what
              the phases already do; the branch is already checked out.
            - End by posting the Phase 12 summary checklist as a final PR comment.

      - name: Report failure to PR
        if: failure() && steps.cmd.outputs.IS_COMMAND == 'true'
        env:
          GH_TOKEN: ${{ secrets.GHCR_PAT }}
        run: |
          set -euo pipefail
          gh pr comment "${{ steps.pr.outputs.number }}" --repo "${{ github.repository }}" --body "$(cat <<'EOF'
          **Spec pipeline failed** (Phase ${{ steps.cmd.outputs.START_PHASE }}). See the [run log](${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}).

          Retry with amended input by commenting, e.g.:
          `/rerun-probe mainnet=https://your-archive-node/rpc`
          or reference a stored secret node: `/rerun-probe mainnet=use=PAID_RPC_1`
          EOF
          )"
```

> **Note on the `Resolve endpoints` step:** the `gh pr view` call needs a token —
> add `GH_TOKEN: ${{ secrets.GHCR_PAT }}` to that step's `env:` (it is shown
> separately here only for readability). Make sure it is present before validating.

- [ ] **Step 2: Add the missing GH_TOKEN to the resolve step**

Edit the `Resolve endpoints` step's `env:` to include the token (the resolver's
`gh pr view` needs it). Final `env:` block for that step:

```yaml
        env:
          GH_TOKEN: ${{ secrets.GHCR_PAT }}
          COMMENT_MAINNET: ${{ steps.cmd.outputs.MAINNET_URLS }}
          COMMENT_TESTNET: ${{ steps.cmd.outputs.TESTNET_URLS }}
```

- [ ] **Step 3: Validate the YAML and triggers**

Run:
```bash
python3 -c 'import yaml,sys; d=yaml.safe_load(open(".github/workflows/spec_pipeline.yml")); print("yaml ok")'
grep -q "issue_comment" .github/workflows/spec_pipeline.yml && echo "comment trigger ok"
grep -q "types: \[opened\]" .github/workflows/spec_pipeline.yml && echo "opened trigger ok"
grep -q "parse_rerun_command.sh" .github/workflows/spec_pipeline.yml && echo "parser wired ok"
grep -q "resolve_endpoints.sh" .github/workflows/spec_pipeline.yml && echo "resolver wired ok"
```
Expected: `yaml ok`, `comment trigger ok`, `opened trigger ok`, `parser wired ok`, `resolver wired ok`.
Note: PyYAML loads `on:` as the boolean key `True` — that is a known cosmetic quirk and does not indicate a problem; the grep checks confirm the trigger keys textually.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/spec_pipeline.yml
git commit -m "feat(ci): add resumable spec_pipeline workflow (Phases 8-11 via PR)"
```

---

## Task 7: Integration self-check + secret-setup docs

**Files:**
- Modify: `.github/workflows/spec_pipeline.yml` (header comment — add the required-secrets list)

- [ ] **Step 1: Run every script test together**

Run:
```bash
bash .github/scripts/tests/test_parse_rerun_command.sh
bash .github/scripts/tests/test_resolve_endpoints.sh
```
Expected: both end with all `ok - …` and exit 0.

- [ ] **Step 2: Validate all three workflow YAMLs parse**

Run:
```bash
for f in .github/workflows/create_spec.yml .github/workflows/spec_pipeline.yml; do
  python3 -c "import yaml; yaml.safe_load(open('$f')); print('ok: $f')"
done
```
Expected: `ok: …` for each.

- [ ] **Step 3: Confirm the create→pipeline contract end-to-end (static checks)**

Run:
```bash
# create writes the ENDPOINTS block the resolver reads
grep -q "ENDPOINTS" .github/workflows/create_spec.yml && echo "writer ok"
grep -q "ENDPOINTS" .github/scripts/resolve_endpoints.sh && echo "reader ok"
# pipeline tells the skill to start mid-pipeline and the skill knows how
grep -q "Start at Phase" .github/workflows/spec_pipeline.yml && echo "prompt ok"
grep -q "phase-entrypoints.md" .claude/skills/create-spec/SKILL.md && echo "skill link ok"
```
Expected: `writer ok`, `reader ok`, `prompt ok`, `skill link ok`.

- [ ] **Step 4: Document required secrets in the pipeline header**

Append to the top comment block of `.github/workflows/spec_pipeline.yml`:

```yaml
# Required repo secrets:
#   CLAUDE_CODE_OAUTH_TOKEN - subscription auth (same as create_spec.yml).
#   GHCR_PAT - one classic PAT, scopes: repo + workflow + read:packages. Used to
#     pull the smart-router image AND as the github_token for gh pr comment. It is
#     also the identity that opens the PR in create_spec.yml, so pull_request
#     events fire (a GITHUB_TOKEN-opened PR would not trigger this workflow).
# Optional (referenced from a comment as use=NAME; only these names are honored):
#   PAID_RPC_1, PAID_RPC_2, PAID_RPC_3, PAID_WS_1 - keyed paid/archive node URLs,
#     auto-masked by Actions so the key never lands in a PR comment or log.
```

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/spec_pipeline.yml
git commit -m "docs(ci): document required secrets for spec_pipeline"
```

---

## Self-Review notes (for the implementer)

- **Spec coverage:** two-workflow split (Tasks 5,6), PR-as-state + per-phase comments (Task 3,6), PAT consolidation into `GHCR_PAT` (Tasks 5,6,7), `rerun-*` grammar (Task 1), endpoint precedence comment>pr_body>research (Task 2), http+ws probing (Tasks 2,3), `opened`-only trigger / no `synchronize` (Task 6 `on:`), `use=SECRET` allow-list (Tasks 1,6), skill entry points + relaxed gating (Tasks 3,4). All spec sections map to a task.
- **The three spec "open questions" are now resolved:** single-job + agent-posts-comments (Task 6); fixed secret allow-list `PAID_RPC_1..3`,`PAID_WS_1` (Tasks 1,6); endpoints passed into the prompt as resolved env (Task 6).
- **Manual verification (no CI dry-run here):** the GitHub-side behavior (event firing, comment triggers, claude-code-action) can only be fully exercised by opening a real PR. After merge, smoke-test by dispatching `create_spec.yml` for a simple EVM chain and watching `spec_pipeline.yml` auto-start, then post `/rerun-probe mainnet=<url>` to confirm the resume path.
```
