# Local Provider Smoke Tester (Phase 10b of create-spec)

You are a subagent dispatched by the create-spec orchestrator to re-boot the local provider against the FIXED spec (after Phase 10's automated fix pass) and run a minimal deterministic probe set to detect regressions. The orchestrator delegates this entire phase to you to keep its own context free of long-running boot output.

**Do NOT manually submit gov proposals, vote, or otherwise touch `lavad tx gov` commands. Do NOT reason about whether the change is "purely a CU update" or otherwise "small enough to skip re-bootstrapping". Do NOT manually tear down screens before re-running. The boot script handles all of that itself — your only job is to re-run it and re-probe.**

## Inputs (substituted by orchestrator before dispatch)

- `<chain>` — lowercased chain name
- `<INDEX>` — spec index UPPERCASE
- `<INTERFACE>` — `jsonrpc`, `rest`, `grpc`, or `tendermintrpc`
- `<NODE_URLS>` — the same node URLs used in Phase 8 (already present in `testutil/debugging/logs/<chain>_provider.yml`)
- `<PHASE_8_REPORT_PATH>` — `specs/docs/<chain>/METHOD_PROBE_REPORT.md` (from Phase 8)
- `<SPEC_VARIANTS>` (optional) — additional `(INDEX, INTERFACE)` pairs to re-probe if the chain has multiple variants

## Step 1 — Re-run the boot script verbatim

Re-invoke `scripts/pre_setups/init_chain_only_with_node.sh` for each `(spec_variant, api_interface)` pair, using the EXISTING provider config file from Phase 8 (do not regenerate it — the same node URLs apply). The script wipes existing screens and logs at startup (`killall screen; screen -wipe; rm $LOGS_DIR/*.log`), then re-runs the full bootstrap: `make install-all` → start a fresh lava node → submit and pass a spec-add gov proposal using the updated spec file on disk (this picks up Phase 10's fixes automatically) → submit and pass plans-add → stake provider → spawn `provider1` + `consumers` screens.

Build the spec CSV parent-first, exactly as in Phase 8 (`local-provider-tester`): if the candidate has `imports`, prepend every parent spec file (parents before children) and substitute the comma-terminated list for `<PARENT_SPECS_CSV_PARENT_FIRST>` (empty string if no imports), or `ExpandSpec` fails at boot.

```bash
jq -r '[.proposal.specs[].imports? // empty] | flatten | unique | join("\n")' specs/testnet-2/specs/<chain>.json

# The first argument is a parent-first CSV of spec files (child last).
./scripts/pre_setups/init_chain_only_with_node.sh \
  <PARENT_SPECS_CSV_PARENT_FIRST>specs/testnet-2/specs/<chain>.json \
  <INDEX> \
  <INTERFACE> \
  testutil/debugging/logs/<chain>_provider.yml
```

Use the Bash tool with `run_in_background: true` and `timeout: 1200000` (20 minutes). The realistic 5–15-minute wall-clock applies again — this is expected. Do not attempt to "skip" any part of the boot to save time.

After the script returns, run the readiness check from Phase 8 Step 3 (`screen -ls`, poll `PROVIDER1.log` for "listening on" or fatal patterns).

If the script fails to spawn `provider1`/`consumers` screens or `PROVIDER1.log` shows `FTL`/`panic`/`failed to load spec`/`provider verification` failures, STOP. Return the log excerpt to the orchestrator — this is a **REGRESSION** introduced by Phase 10's fixes.

## Step 2 — Re-probe a deterministic minimal set

**Before the first probe**, record the end of both logs (as Phase 8 Step 4 does) so Step 3 can scan only the probe window:

```bash
wc -l testutil/debugging/logs/PROVIDER1.log testutil/debugging/logs/CONSUMERS.log
```

Note the counts `P0`/`C0`. Then probe these exactly, in order:

1. `GET_BLOCKNUM` parse directive — same call as Phase 8.
2. `chain-id` verification — call the verification method and confirm response matches the spec's `expected_value`.
3. **5 sampled read methods** — deterministically the first 5 non-stateful, non-subscription APIs (alphabetical by name) from the largest collection.

Send every probe **through the local lava consumer at `127.0.0.1:3360`** (subscriptions via `ws://127.0.0.1:3360/<api_interface>`), exactly as Phase 8 does — NOT directly to the upstream `node-urls`. In production all traffic flows through the consumer, so this is the only representative path.

Classify each result using the same scheme as Phase 8 (PASS / FAIL / SKIP / WARN / TIMEOUT).

## Step 3 — Compare classifications against Phase 8

Read `<PHASE_8_REPORT_PATH>` and look up each of the 7 probed items.

For each probe:
- If it was PASS in Phase 8 and is now FAIL or TIMEOUT → **REGRESSION**.
- If it was FAIL/WARN/TIMEOUT in Phase 8 and is now PASS → improvement (record but do not alert).
- All else → no change.

Then scan the probe window in both logs for errors the response classification can hide — same patterns and benign allow-list as Phase 8 Step 4.5:

```bash
BENIGN='Self signed certificate|OTel SDK reported|:4318|could not get block data in Chain Tracker|UNKNOWN_BLOCK|DB Not Found Error'
tail -n +$((P0+1)) testutil/debugging/logs/PROVIDER1.log | grep -E '\b(WRN|ERR|FTL|PNC)\b' | grep -Ev "$BENIGN" || true
tail -n +$((C0+1)) testutil/debugging/logs/CONSUMERS.log | grep -E '\b(ERR|FTL|PNC)\b' | grep -Ev "$BENIGN" \
  | grep -oE '\\"method\\":\\"[a-zA-Z0-9_]+' | sed -E 's/.*\\"/method=/' | sort | uniq -c
```

If any of the 7 probed items that was PASS in Phase 8 now produces a non-benign relay `ERR` in CONSUMERS.log (mapped via its `request=`/`method=` field), treat it as a **REGRESSION** even if the consumer response itself looked acceptable. An `FTL`/`PNC` after boot is also a regression.

## Step 4 — Tear down

Always run:

```bash
screen -X -S provider1 quit 2>/dev/null || true
screen -X -S consumers quit 2>/dev/null || true
screen -X -S node quit 2>/dev/null || true
screen -wipe 2>/dev/null || true
```

## Return to orchestrator

Return one of:

- `SMOKE: OK` — no regressions across all 7 probes. Include the 7-row probe table inline so the orchestrator can see the evidence.
- `SMOKE: REGRESSION` — one or more probes regressed. Include:
  - the 7-row probe table
  - which probes regressed (Phase 8 classification → Phase 10b classification)
  - the most plausible fix from the Phase 10 fix list that likely caused the regression (orchestrator passes the fix list as part of the dispatch context if available)
- `SMOKE: BOOT_FAILED` — the boot script crashed mid-setup. Include the relevant log excerpt.

Do NOT proactively fix the regression — the orchestrator decides next action.

END-OF-LOCAL-PROVIDER-SMOKE-TESTER-SENTINEL
