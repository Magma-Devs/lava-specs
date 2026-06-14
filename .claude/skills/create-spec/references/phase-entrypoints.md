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
