# Resumable Spec Pipeline — Design

**Date:** 2026-06-14
**Status:** Approved design, pending implementation plan
**Topic:** Split the monolithic `create_spec.yml` run so a Phase 8+ failure can be
resumed with amended input (e.g. a paid/archive node URL) instead of restarting
the ~1.5h pipeline from Phase 1.

## Problem

Today `create_spec.yml` runs all 12 phases of the `create-spec` skill inside a
single `anthropics/claude-code-action` step (~1.5h, ~20 subagents). The only
phase that depends on **external infrastructure** — Phase 8 (dockerized
smart-router boot + multi-node method probe) and its Phase 10b re-probe — is also
the dominant flaky-failure source: public RPC nodes rate-limit, lack archive
depth, or lack a `wss` endpoint for subscription chains. When Phase 8 fails, ~1h
of completed research and synthesis is thrown away, and there is no way to feed in
a better node URL (or corrected docs/hints) without a full rerun, because GitHub's
"Re-run failed jobs" replays the *same* inputs.

## Goals

- A Phase 8+ failure is recoverable **without** re-running Phases 1-7.
- Recovery can carry **new free-text input**: node URLs, docs links, hints, index
  corrections — not just a node URL.
- Each phase's output is **visible and reviewable in the PR**, not buried in a
  ~1.5MB transcript artifact.
- The happy path stays **fully unattended** (matches today's behavior).

## Non-goals

- Per-phase resumability for Phases 1-7 (research). Those rarely fail on external
  causes and re-running them is token cost, not correctness risk. Coarse
  checkpointing only: the resumable boundary is "draft spec exists" (post-Phase 7).
- Auto-merging an APPROVED PR. A human keeps the final approve/merge action.

## Architecture

The **PR is the shared state store**:
- The draft spec lives on the per-chain branch (committed after Phase 7).
- Every phase's output lives as a **PR comment** (probe reports, reviews,
  fix logs, final verdict, summary).
- No `.checkpoint/` directory and no cross-run artifact lookup is needed — a
  resumed phase reconstructs context by reading the committed spec + prior PR
  comments.

Two workflows:

### 1. `create_spec.yml` — Phases 1-7 (mostly unchanged)
Manual dispatch → parallel research → network params → synthesis → jq validation →
commit draft spec → **open PR**. Then it stops. `pr_body.md` already records the
probed `RPC nodes:` URLs, which Phase 8 reads as its default endpoint set.

**Change:** the PR is opened with a **PAT** instead of `GITHUB_TOKEN`. Rationale:
GitHub deliberately does **not** fire `pull_request` events for a PR opened by
`GITHUB_TOKEN` (recursion guard — the current workflow header documents this). A
PAT-opened PR fires `pull_request: opened` naturally, so the pipeline can trigger
on the PR event with no explicit `gh workflow run` plumbing, and future PR-event
automation (reviewers, gating checks) is unlocked. PR author becomes the PAT's
user rather than `github-actions[bot]`.

**Single consolidated PAT (`BOT_PAT`).** Rather than a second secret, **one** PAT
does every privileged job: open the PR, drive the `gh` API, pull the private GHCR
image, and authenticate the agent. A **classic** PAT with scopes `repo` +
`workflow` + `read:packages` covers all of it (classic is preferred over
fine-grained, which is fussy for GHCR org packages). It is named `BOT_PAT` — a
role-neutral name, since it is no longer registry-specific (the older `GHCR_PAT`
name was misleading once the PAT also opens PRs and posts comments). **Consequence:**
the PAT is *required in every setup*, not just personal forks — the old arrangement
where a GHCR-only PAT was optional and same-org runs fell back to `GITHUB_TOKEN` no
longer applies, because every run needs the PAT-opened PR so `pull_request` events
fire. The GHCR login keeps a `${{ secrets.BOT_PAT || secrets.GITHUB_TOKEN }}`
fallback for resilience.

### 2. `spec_pipeline.yml` — Phases 8 → 9 → 10 → 11 → summary
**Triggers:**
- `pull_request: [opened]` — auto-start the full 8→11→summary sequence, unattended.
- `issue_comment: [created]` — a human `rerun-*` command re-runs a phase.

**Explicitly NOT `pull_request: [synchronize]`.** Phase 10 commits its fix to the
branch, which fires `synchronize`; reacting to that would loop the pipeline. Only
`opened` + human comments trigger runs. Bot-posted phase comments do not
re-trigger (the author is the bot/PAT, and we gate on command prefix anyway).

Each phase runs the skill's corresponding **entry point**, posts its result as a
PR comment, and halts the run on failure. A `rerun-*` command runs the named phase
**and everything after it** to completion (run-to-end), so fixing Phase 8 flows
back through 9→11 with no further clicks.

## Comment command grammar

Parsed by `spec_pipeline.yml`; a comment is ignored unless its body starts with a
known `rerun-` command. All commands run their phase to the end.

```
/rerun-probe   mainnet=<url|use=SECRET>[,url2…]   testnet=<url|use=SECRET>[,…]   [free-text hints]
/rerun-review                  # Phase 9 onward
/rerun-fix                     # Phase 10 onward
/rerun-final                   # Phase 11 onward
/rerun-from <phase>            # generic catch-all
```

- A raw `https://…` token is used verbatim. A `use=SECRET_NAME` token is resolved
  from repo secrets and **auto-masked** by GitHub in logs — this keeps keyed paid
  node URLs (e.g. `…/v3/<KEY>`) out of collaborator-visible comments and run logs.
  Both forms are accepted in the same command (keyless URLs inline, keyed by name).
- Free-text after the tokens flows to the skill as `additional_data` (docs, hints,
  corrections).

## Phase 8 endpoint resolution

The endpoint set the smart-router boots against is resolved in this precedence
(highest wins):

1. **Comment override** — `mainnet=/testnet=` tokens in the triggering `rerun-probe`.
2. **PR-description nodes** — the `RPC nodes:` URLs parsed from `pr_body.md`
   (already found and lightly probed by Phases 1-7). Default on the automatic run.
3. **Self-research** — the skill picks fresh public nodes (today's behavior) only
   if 1 and 2 yield nothing usable.

### WebSocket handling
Every resolved URL — regardless of source — is registered for probing over **both
transports**: request/response methods over http, subscription methods over ws.
There is **no `wss=` token**; a ws-capable node is the normal case. If a node
splits transports across hostnames (the publicnode case: ws-only, no
request/response `GET_BLOCKNUM`), list both URLs and the resolver keeps whichever
transport each one actually serves. Only if the spec enables any
`category.subscription` method **and** no resolved URL answers ws does Phase 8
hard-fail with a comment explicitly requesting a ws-capable node — rather than
dying with the opaque `all static providers failed verification — cannot serve
endpoint`.

## Skill changes — phase entry points (the main implementation cost)

Today `create-spec` is one agent invocation running Phases 1-12 linearly, with
sentinel-gated full-reads enforcing forward-only progress. To invoke a phase span
as a standalone run, the skill needs:

1. **A documented entry point per resumable phase (8, 9, 10, 11)** — a way to start
   there, skipping 1-7.
2. **Context reconstruction instead of regeneration.** A mid-pipeline entry reads
   committed state rather than rebuilding it: the spec JSON from the branch, the
   resolved endpoint set, and prior phase outputs **from the PR comments** (e.g.
   Phase 9 review reads the Phase 8 probe-report comment).
3. **Relaxed sentinel-gating for partial runs** — full-read enforcement must permit
   starting at phase N without having observed phases 1..N-1 in this process.

The seams already exist (per-phase reference files like `phase4-…md`, per-phase
agent defs), so this is mostly adding a re-entry contract and a "read state from
branch + PR comments" preamble to each entry point — not rewriting the phases. But
it is a change to the **skill**, not only the workflow YAML, and is the part most
likely to be fiddly.

## End state / approval

Phase 11 (final review) posts its verdict + a summary comment. A human reviews the
PR thread and approves/merges via normal GitHub review. No auto-merge.

## Carried-over constraints (from prior CI runs)

- **GHCR auth:** Phase 8/10b pull the private `ghcr.io/magma-devs/smart-router:main`.
  Now folded into the single consolidated PAT above (`BOT_PAT`, scopes `repo`
  + `workflow` + `read:packages`), which is required in all setups — the old
  "same-org falls back to `GITHUB_TOKEN`, optional GHCR-only PAT" arrangement no
  longer applies.
- **Subscriptions require a ws upstream** (see WebSocket handling above).
- **Concurrency:** keep the per-chain concurrency group so re-runs for the same
  chain serialize on the shared branch/PR.

## Open questions for the plan

- Exact mechanism to pass the resolved endpoint set + `additional_data` into the
  `claude-code-action` prompt for a partial run (prompt template per entry point).
- Whether `spec_pipeline.yml` runs all of 8→11 in one job (sequential steps) or one
  job per phase with `needs:` chaining — affects how a comment re-run picks the
  start phase.
- How the comment parser maps `use=SECRET_NAME` to actual repo secrets (allow-list
  of permitted secret names vs. dynamic lookup).
