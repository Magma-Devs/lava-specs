# Resumable phase entry points (CI pipeline)

The `spec_pipeline.yml` workflow invokes this skill **mid-pipeline** so a failed
phase can be re-run with amended input instead of restarting from Phase 1. When
the orchestrator prompt says **"Start at Phase N"**, do NOT run Phases 1-7. Instead
reconstruct context from committed state and run Phase N → end.

## Inputs the workflow passes in the prompt

- `START_PHASE` / `END_PHASE` — the run span (inclusive), within 8–11. Run Phase
  `START_PHASE` through `END_PHASE` and then STOP — do NOT run any phase past
  `END_PHASE`. A single-phase command has `START_PHASE == END_PHASE` (run exactly
  that one phase); `/rerun-from N` and the PR-open auto-start have `END_PHASE = 11`
  (run to the end). Phase 11 also emits the closing Phase-12 summary checklist —
  there is no separate Phase 12 in the span.
- `PR_NUMBER` — the open PR for this chain; the spec is the committed `<chain>.json`
  on the checked-out branch.
- `MAINNET_URLS`, `TESTNET_URLS` — comma-separated endpoint lists already resolved
  by the workflow (comment override > PR body > empty). If both are empty, research
  public nodes yourself exactly as the normal Phase 3/8 flow would.
- `ADDITIONAL_DATA` — free-text hints (docs URLs, corrections) from the triggering
  comment; treat it like the Phase 2 `additional_data` input.

## Context reconstruction (do this first, every entry)

0. Stamp the run-start epoch so the Phase 12 run-stats scope to THIS pipeline run —
   Phase 1, which normally writes it, did not run:
   ```bash
   date +%s > /tmp/create_spec_run_start.epoch
   ```
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
comment naming the failure and the exact retry command from the grammar below.

## Retry command grammar (use these EXACT commands — never invent others)

Whenever you tell a human how to retry, you MUST use a command the pipeline parser
recognises. Inventing one (e.g. `/rerun-phase8`) silently no-ops — the job runs,
the parser returns `IS_COMMAND=false`, and every downstream step skips.

The **named** commands re-run EXACTLY their one phase (`START==END`). Only
`/rerun-from N` runs from phase N through the end of the span (`END=11`).

| Command | Runs | Optional args |
|---|---|---|
| `/rerun-probe` | Phase 8 only (boot + probe) | `mainnet=<url\|use=SECRET>[,…] testnet=<url\|use=SECRET>[,…]` + free-text hints |
| `/rerun-review` | Phase 9 only (reviewers) | — |
| `/rerun-fix` | Phase 10 only (fix + 10b) | — |
| `/rerun-final` | Phase 11 only (final review + summary) | — |
| `/rerun-from <8\|9\|10\|11>` | that phase → Phase 11 (to the end) | as for the matching command |

So `/rerun-probe` re-runs ONLY Phase 8 and posts only its comment; to also re-run
the reviews/fix/verdict on top of a new probe, use `/rerun-from 8`. To retry a
failed Phase-8 boot the command is **`/rerun-probe`** (optionally
`/rerun-probe mainnet=https://your-node/rpc`) — NOT `/rerun-phase8` or any invented
form. When you suggest a retry in a comment, pick the command whose span matches
what actually needs redoing.

**Advancing through the span.** After finishing a phase, advance to the next only
while you have NOT yet reached `END_PHASE`; once the current phase equals
`END_PHASE`, STOP (do not run any later phase). A hard failure also stops the run.

## Entry: Phase 8 (smart-router boot + probe)

Reconstruct context, then run Phase 8 of `SKILL.md` against `MAINNET_URLS` /
`TESTNET_URLS` (probing http+ws). Post `docs/<chain>/METHOD_PROBE_REPORT.md` as a PR
comment. If `END_PHASE` is 8, STOP here. Otherwise continue to Phase 9.

## Entry: Phase 9 (parallel reviewers)

Read `<chain>.json` and the latest Phase 8 probe-report comment. Run Phase 9 of
`SKILL.md`. Post a combined reviewers comment (the three TALLY lines + merged gaps).
If `END_PHASE` is 9, STOP here. Otherwise continue to Phase 10.

## Entry: Phase 10 (synthesize gaps + fix + 10b re-probe)

Read `<chain>.json`, the latest reviewers comment, and the latest probe-report
comment. Run Phase 10 + Phase 10b of `SKILL.md`. Post a fix-log comment and the
10b smoke-result comment. If `END_PHASE` is 10, STOP here. Otherwise continue to
Phase 11.

## Entry: Phase 11 (final reviewer + summary)

Read `<chain>.json` and the latest fix-log comment. Run Phase 11. Post the verdict
(APPROVED / CHANGES REQUESTED with the TALLY) as a PR comment. Do NOT halt on
CHANGES REQUESTED in CI — record the verdict honestly. Phase 11 is always the end of
the span (11 is the maximum `END_PHASE`), so after the verdict also run Phase 12 and
post the closing summary checklist as a final comment, then STOP.

**Run-stats scope (do not misreport totals).** The closing summary (and its
run-stats report) only runs when the span reaches Phase 11. This is a *resumable*
run covering only Phases `START_PHASE`–11, in a separate workflow run from the
create_spec job that ran Phases 1–7. Label the time/tokens explicitly as
**"this pipeline run (Phases `START_PHASE`–11)"** — do NOT present them as a 1–11
grand total. The Phases 1–7 time/tokens live in the create_spec run and its PR body;
the true total is the two runs added together (state that, rather than printing a
number that looks complete but only covers one part). Any retry hint must use the
exact command from the grammar above whose span matches what needs redoing.

## Sentinel-gating under partial runs

The full-read enforcement in `SKILL.md` still applies to the reference files for the
phases you WILL execute (Phase N..end). You are NOT required to have observed the
sentinels for Phases 1..N-1, because you are not running them this invocation.

END-OF-PHASE-ENTRYPOINTS-SENTINEL
