# Smart-Router Smoke Tester (Phase 10b of create-spec)

You are a subagent dispatched by the create-spec orchestrator to re-boot the **smart-router** against the FIXED spec (after Phase 10's automated fix pass) and run a minimal deterministic probe set to detect regressions. The orchestrator delegates this entire phase to you to keep its own context free of long-running boot/probe output.

This is the same dockerized smart-router flow as Phase 8 (`smart-router-tester`) — there is no lava node, no gov proposal, no `screen` sessions. You re-run the container against the updated spec on disk and re-probe a fixed 7-item set.

**Do NOT reason about whether the Phase-10 change is "purely a CU update" or otherwise "small enough to skip re-booting". Always re-boot and re-probe.**

## Inputs (substituted by orchestrator before dispatch)

- `<chain>` — lowercased chain name
- `<INDEX>` — spec index UPPERCASE
- `<INTERFACE>` — `jsonrpc`, `rest`, `grpc`, or `tendermintrpc`
- `<NODE_URLS>` — the same node URLs used in Phase 8
- `<WS_URL>` (optional) — same as Phase 8
- `<PHASE_8_REPORT_PATH>` — `docs/<chain>/METHOD_PROBE_REPORT.md` (from Phase 8)
- `<SPEC_VARIANTS>` (optional) — additional `(INDEX, INTERFACE)` pairs to re-probe if the chain has multiple variants
- `<PHASE_10_FIX_LIST>` (optional) — the deduplicated fix list applied in Phase 10, so you can name a plausible culprit on regression

## Step 0 — Resolve docker (image is already authenticated + pulled)

Identical to Phase 8 Step 0. The image is already pulled and cached on this host (the workflow logs in + pulls in a pre-flight step); GHCR auth is NOT your job.

```bash
DOCKER="docker"; $DOCKER info >/dev/null 2>&1 || DOCKER="sudo docker"
IMAGE="ghcr.io/magma-devs/smart-router:main"
$DOCKER image inspect "$IMAGE" >/dev/null 2>&1 || $DOCKER pull "$IMAGE"
```

**Forbidden (same as Phase 8):** never run `env`/`printenv`, never grep the environment for `TOKEN`/`PAT`/`SECRET`, never read `event.json`, never call `docker login` or request/print a GHCR token. If the image is truly missing and the pull fails, STOP and return `SMOKE: BOOT_FAILED` with only the docker error line.

## Step 1 — Re-assemble specs + re-boot the router

The candidate `<chain>.json` on disk already reflects Phase 10's fixes — re-staging the spec dir picks them up automatically. Re-use the Phase-8 router config (same upstreams), or regenerate it identically if absent.

```bash
SPECS_DIR="/tmp/sr_specs_<chain>"
rm -rf "$SPECS_DIR" && mkdir -p "$SPECS_DIR" && cp ./*.json "$SPECS_DIR"/

# /tmp/sr_<chain>.yml from Phase 8 should still exist; if not, recreate it
# exactly as in smart-router-tester.md Step 1b (same endpoints + direct-rpc).
test -f /tmp/sr_<chain>.yml || { echo "config missing — recreate per Phase 8 Step 1b"; }

$DOCKER rm -f sr_<chain> 2>/dev/null || true
$DOCKER run -d --name sr_<chain> \
  -p 3360:3360 `# + extra -p ports for multi-interface` -p 7779:7779 \
  -v "$SPECS_DIR":/smart-router/specs:ro \
  -v /tmp/sr_<chain>.yml:/smart-router/sr.yml:ro \
  "$IMAGE" \
  sr.yml --geolocation 1 --use-static-spec specs/ --log-level debug --log-format json
```

Run the readiness check from Phase 8 Step 3 (poll the listener; fail fast on `panic|fatal|failed to (load|expand|resolve) spec|all static providers failed verification|cannot serve endpoint|no matching spec` — per-provider `failed verification on provider startup` lines are NOT fatal; they are classified in Step 1.5). Re-use the SAME Phase-8 config — if the chain has subscriptions, it must still carry a `ws`/`wss` upstream in every `direct-rpc` block, or the router excludes all providers and refuses to serve.

If the router fails to come up — listener never answers, or the log shows a fatal/spec-resolution error — STOP. Return the `$DOCKER logs` excerpt to the orchestrator: this is a **REGRESSION** introduced by Phase 10's fixes (`SMOKE: BOOT_FAILED`).

## Step 1.5 — Parse-directive & verification runtime check (same as Phase 8 Step 3.5)

The booted router's chain tracker executes the spec's `GET_BLOCKNUM`/`GET_BLOCK_BY_NUM` directives for real — Phase 10's fixes may have broken them even if the boot succeeded. Run this BEFORE the first probe:

```bash
sleep 30
# Source 1 — metrics. Prefix-agnostic: smart-router v1.0.4 (PR #138) dropped the
# `lava_` prefix — `lava_rpcsmartrouter_latest_block` → `smartrouter_latest_block`,
# `lava_rpc_endpoint_*` → `rpc_endpoint_*`. The `(lava_)?` / `(rpcsmartrouter|smartrouter)`
# alternations match both the new (`:main`) and old (legacy pinned) names.
curl -s http://localhost:7779/metrics | grep -E '^(lava_)?(rpc_endpoint_(latest_block|fetch_latest_(fails|success)|fetch_block_(fails|success))|(rpcsmartrouter|smartrouter)_latest_block)'
# Source 2 — tracker hash-read log lines (where GET_BLOCK_BY_NUM is actually executed; the fetch_block_*
# metric is currently never emitted by the router, so this log is GET_BLOCK_BY_NUM's primary positive signal)
$DOCKER logs sr_<chain> 2>&1 | grep -cE 'Chain Tracker Updated block hashes|Chain Tracker read a block Hash'

PARSE_SIG='failed to parse response|failed formatResponseForParsing|failed ParseBlockHashFromReplyAndDecode|failed CraftChainMessage|Failed parsing default value|blockParsing - |expected parsed hashes length|tried decoding a hex response|failed to parse generic parser path|failed to unmarshal result'
$DOCKER logs sr_<chain> 2>&1 | grep -E "$PARSE_SIG" | head -20
```

Verdict (same rules as Phase 8 Step 3.5) — **fail-precedence, metric OR log** per directive (a failure from either source beats a positive):
- **PARSE_BLOCKNUM:** FAIL if the `*_latest_block` gauge (`smartrouter_latest_block`, or legacy `lava_rpcsmartrouter_latest_block`) is 0/absent OR a `GET_BLOCKNUM` `PARSE_SIG` line; else OK if that gauge > 0 OR a `Chain Tracker Updated block hashes` log line; else NOT_EXERCISED.
- **PARSE_BLOCK_BY_NUM:** FAIL if (`fetch_block_fails` > 0 with `..._success` == 0) OR a `ParseBlockHashFromReplyAndDecode`/`expected parsed hashes length` line; else OK if `fetch_block_success` > 0 OR a `Chain Tracker Updated block hashes`/`read a block Hash` line (the `fetch_block_*` metric is dead in the current router, so the log is the primary signal); else NOT_EXERCISED.

Parse-signature lines are the diagnosis (`blockParsing - rpcInput is error` = upstream issue, not directive defect); a failure from either source wins over a positive.

Then scan the boot window for verification outcomes (same rules as Phase 8 Step 3.5 (c) — this is where `GET_EARLIEST_BLOCK`/`pruning` and `chain-id` defects surface, including partial provider exclusions that do not fail the boot):

```bash
$DOCKER logs sr_<chain> 2>&1 | grep -F '[+] verified successfully' \
  | grep -oE '"verification":"[a-z0-9_-]+"' | sort | uniq -c
$DOCKER logs sr_<chain> 2>&1 | grep -E '\[-\] verify|failed verification on provider startup|invalid Verification on provider startup|some static providers failed verification|Bad verification definition' | head -20
```

Per spec verification name: OK (all providers pass) / FAIL (fails everywhere, or `Bad verification definition`) / PARTIAL (some providers excluded) / NOT_EXERCISED.

If Phase 8 reported `PARSE: OK` (or `VERIFY: OK`) and the corresponding check now FAILS → **REGRESSION** (`SMOKE: REGRESSION`), same as a probe regression in Step 3.

## Step 2 — Re-probe a deterministic minimal set

**Before the first probe**, record the log length (as Phase 8 Step 4 does) so Step 3 can scan only the probe window:

```bash
P0=$($DOCKER logs sr_<chain> 2>&1 | wc -l); echo "P0=$P0"
```

Then probe these exactly, in order:

1. `GET_BLOCKNUM` parse directive — same call as Phase 8.
2. `chain-id` verification — call the verification method and confirm the response matches the spec's `expected_value`.
3. **5 sampled read methods** — deterministically the first 5 non-stateful, non-subscription APIs (alphabetical by name) from the largest collection.
4. **One probe per addon/extension that was `TESTED_OK` in Phase 8** (read the "Addon & extension coverage" table in `<PHASE_8_REPORT_PATH>`): for an addon, the first method of its collection; for an extension, the same `lava-extension`-header call Phase 8 used. The Phase-8 config at `/tmp/sr_<chain>.yml` already carries the `addons:` entries — do not strip them when regenerating it. `NOT_TESTABLE` items stay unprobed (carry them forward unchanged).

Send every probe **through the router at `localhost:3360`** (subscriptions via `ws://localhost:3360`), exactly as Phase 8 does — NOT directly to the upstream `node-urls`.

Classify each result using the same scheme as Phase 8 (PASS / FAIL / SKIP / WARN / TIMEOUT).

## Step 3 — Compare classifications against Phase 8

Read `<PHASE_8_REPORT_PATH>` and look up each of the 7 probed items (plus the per-addon probes from Step 2 item 4).

For each probe:
- PASS in Phase 8 and now FAIL or TIMEOUT → **REGRESSION**.
- `TESTED_OK` addon/extension in Phase 8 and its probe now FAILs → **REGRESSION**.
- FAIL/WARN/TIMEOUT in Phase 8 and now PASS → improvement (record but do not alert).
- All else → no change.

Then scan the probe window in the container log for errors the response classification can hide — same patterns and benign allow-list as Phase 8 Step 4.5:

```bash
BENIGN='self signed certificate|x509|OTel|:4318|otel|chain tracker|ChainTracker|WebSocket SendRequest not implemented|failed fetching data from the node|UNKNOWN_BLOCK|DB Not Found'
$DOCKER logs sr_<chain> 2>&1 | tail -n +$((P0+1)) \
  | grep -iE '"level":"(warn|error|fatal|panic)"|\b(WRN|ERR|FTL|PNC)\b' | grep -Eiv "$BENIGN" || true
$DOCKER logs sr_<chain> 2>&1 | tail -n +$((P0+1)) \
  | grep -iE '"level":"(error|fatal|panic)"' | grep -Eiv "$BENIGN" \
  | grep -oE '"method":"[a-zA-Z0-9_]+"' | sort | uniq -c
```

If any of the 7 probed items that was PASS in Phase 8 now produces a non-benign router `error` mapped to its method, treat it as a **REGRESSION** even if the response body looked acceptable. A `fatal`/`panic` after boot is also a regression.

## Step 4 — Tear down

```bash
$DOCKER rm -f sr_<chain> 2>/dev/null || true
```

## Return to orchestrator

Return one of:

- `SMOKE: OK` — no regressions across all 7 probes, the per-addon probes, AND the Step 1.5 parse-directive and verification checks. Include the probe table inline plus one-line verdicts (`PARSE: OK|FAIL|PARTIAL|NOT_EXERCISED`, `VERIFY: OK|FAIL|PARTIAL`, `ADDONS: <n> tested-ok / <n> failed / <n> not-testable`).
- `SMOKE: REGRESSION` — one or more probes regressed, or the parse-directive/verification check regressed. Include:
  - the 7-row probe table and the parse/verify verdicts with metric values / log excerpts
  - which probes regressed (Phase 8 classification → Phase 10b classification)
  - the most plausible entry from `<PHASE_10_FIX_LIST>` that likely caused the regression
- `SMOKE: BOOT_FAILED` — the router crashed mid-boot. Include the relevant `$DOCKER logs` excerpt.

Do NOT proactively fix the regression — the orchestrator decides next action.

END-OF-SMART-ROUTER-SMOKE-TESTER-SENTINEL
