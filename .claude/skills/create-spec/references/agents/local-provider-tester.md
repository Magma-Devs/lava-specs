# Local Provider Tester (Phase 8 of create-spec)

You are a subagent dispatched by the create-spec orchestrator to perform the full local-provider boot + multi-node method probe for a Lava chain spec. The orchestrator delegates this entire phase to you to keep its own context free of long-running boot output.

**Execute the steps below verbatim. Do NOT inspect `scripts/pre_setups/init_chain_only_with_node.sh` to reason about its internals, do NOT question the timeouts, and do NOT improvise the config format. The procedure below is authoritative.**

## Inputs (substituted by orchestrator before dispatch)

- `<chain>` — the lowercased chain name (e.g., `iota`, `polygon`) — used for filenames
- `<INDEX>` — the spec index UPPERCASE (e.g., `IOTA`, `IOTAT`)
- `<INTERFACE>` — one of `jsonrpc`, `rest`, `grpc`, `tendermintrpc`
- `<NODE_URL_1>`, `<NODE_URL_2>`, `<NODE_URL_3>` — 2–3 public node URLs (https://... or wss://...)
- `<WS_URL>` (optional) — WebSocket URL for chains with subscriptions; if provided, add it as another `node-urls` entry in the same list
- `<EXTRA_INTERFACES>` (optional) — for multi-interface chains (e.g., Cosmos: rest + tendermintrpc + grpc), a list of additional `(INTERFACE, urls)` blocks to add to the provider config

## Optional read

For additional context only (the steps below take precedence over anything you find here): `references/phase4-testing-and-validation.md` (observe `END-OF-PHASE4-SENTINEL`).

## Context

The boot script does a full local-chain bootstrap (compile binaries → start a fresh lava node → submit and pass a spec-add gov proposal → submit and pass a plans-add proposal → stake provider → advance an epoch → spawn `provider1` and `consumers` `screen` sessions). Realistic wall-clock: **5–15 minutes per invocation**. This is expected. Do not abort early.

## Step 1 — Write the provider config

Write `testutil/debugging/logs/<chain>_provider.yml` with EXACTLY this structure (no other fields, no other sections):

```yaml
# ./scripts/pre_setups/init_chain_only_with_node.sh specs/testnet-2/specs/<chain>.json <INDEX> <interface> testutil/debugging/logs/<chain>_provider.yml
endpoints:
  - api-interface: <INTERFACE>
    chain-id: <INDEX>
    network-address:
      address: 127.0.0.1:2220
    node-urls:
      - url: <NODE_URL_1>
      - url: <NODE_URL_2>
      - url: <NODE_URL_3>
```

Rules — apply exactly:
- `network-address` is a nested object with a single `address:` field. Value is **always** `127.0.0.1:2220` (the init script hardcodes this listener; do not change it).
- `<INTERFACE>` is the value passed in.
- `<INDEX>` is the spec index — uppercase.
- `node-urls` is a flat list of `- url: <URL>` items. **Add 2–3 entries**, one per node URL passed in.
- For chains with WebSocket subscriptions, add the `wss://` URL as ANOTHER entry in the same `node-urls` list (do NOT create a separate section). Example: `- url: wss://eth-rpc.example.com`.
- For multi-interface chains (Cosmos has jsonrpc + rest + tendermintrpc + grpc), repeat the `endpoints[]` block once per interface, all using the same `network-address.address: 127.0.0.1:2220`. See `testutil/debugging/logs/cosmoshub_provider.yml` for the multi-interface shape.
- `add_on` / addons are defined in the SPEC file (`collection_data.add_on`), NOT in this provider config. Do not invent addon fields here.

After writing, dump the file and confirm it parses as YAML:

```bash
cat testutil/debugging/logs/<chain>_provider.yml
python3 -c 'import yaml,sys; yaml.safe_load(open("testutil/debugging/logs/<chain>_provider.yml"))'
```

## Step 2 — Invoke the boot script

Run the script in the FOREGROUND (the script itself daemonizes the provider via `screen`; you must wait for the script to finish its setup work before probing).

**Build the spec CSV (parent-first).** Inspect the candidate's `imports` field:

```bash
jq -r '[.proposal.specs[].imports? // empty] | flatten | unique | join("\n")' specs/testnet-2/specs/<chain>.json
```

For each imported parent index, locate its spec file (search `specs/mainnet-1/specs/` then `specs/testnet-2/specs/`) and prepend it to the CSV, parents before children (a parent that itself imports must come first). Substitute the comma-terminated result for `<PARENT_SPECS_CSV_PARENT_FIRST>` (empty string if there are no imports). Example for a chain importing `ETH1`: `specs/mainnet-1/specs/ethereum.json,specs/testnet-2/specs/<chain>.json`.

```bash
# The first argument is a CSV of spec files. When the candidate spec has `imports`,
# every parent spec MUST appear BEFORE the child, or `ExpandSpec` fails at boot.
# Build the CSV parent-first: <parent specs, in dependency order>,<child spec>.
# If the candidate has no `imports`, the CSV is just the child spec.
./scripts/pre_setups/init_chain_only_with_node.sh \
  <PARENT_SPECS_CSV_PARENT_FIRST>specs/testnet-2/specs/<chain>.json \
  <INDEX> \
  <INTERFACE> \
  testutil/debugging/logs/<chain>_provider.yml
```

Use the Bash tool's `run_in_background: true` option, set `timeout: 1200000` (20 minutes), and watch for completion. Do NOT use a 60s timeout. Do NOT redirect to `/tmp/provider_*.log` — the script writes its real output to `testutil/debugging/logs/PROVIDER1.log` and `testutil/debugging/logs/CONSUMERS.log` (it `rm`s these at startup and re-creates them).

## Step 3 — Wait for the provider to be ready

The script returns control once it has spawned the `provider1` and `consumers` `screen` sessions. After it returns, the provider is starting up but may not yet be listening. Confirm readiness:

```bash
# 1. Both screen sessions exist
screen -ls | grep -E "(provider1|consumers)"
# Expected: two lines, one per session

# 2. Provider has bound its listener
timeout 60 bash -c 'until grep -q "listening on" testutil/debugging/logs/PROVIDER1.log 2>/dev/null \
  || grep -qE "FTL|panic|failed to load spec|provider verification" testutil/debugging/logs/PROVIDER1.log 2>/dev/null; do
  sleep 2
done'

# 3. Print last 50 lines of provider log for evidence
tail -n 50 testutil/debugging/logs/PROVIDER1.log
```

If the log shows `FTL`, `panic`, `failed to load spec`, or `provider verification` failures before any success marker, STOP. Capture the full log, return the error to the orchestrator, and go to Step 6 (teardown) before deciding next action. Do NOT skip to Step 4.

If `screen -ls` shows no `provider1` session, the script crashed mid-setup. STOP and return the script's stdout/stderr to the orchestrator.

## Step 4 — Method-probe loop

**Before sending the first probe**, record the current end of both logs so Step 4.5 can isolate only the lines emitted during probing:

```bash
wc -l testutil/debugging/logs/PROVIDER1.log testutil/debugging/logs/CONSUMERS.log
```

Note the two counts — call them `P0` (PROVIDER1) and `C0` (CONSUMERS). Then run the probe loop below.

For every API in every collection of the current spec variant:

| Category | Probe action |
|---|---|
| `category.stateful: 1` | SKIP. Record reason: "stateful — would broadcast transaction". |
| `category.subscription: true` | Open a WebSocket to the **local consumer** (`ws://127.0.0.1:3360/<api_interface>` — confirm the consumer ws path in CONSUMERS.log), send the subscribe call with sample params from the spec's `parse_directive` or `block_parsing` hints, **wait up to 30 seconds for at least one message**, then send unsubscribe. PASS = ≥1 message received. FAIL = timeout. Probe via the consumer, not the upstream node. |
| Anything else | Build the simplest valid call from `block_parsing` + `parse_directive` hints. Send it **through the local lava consumer at `127.0.0.1:3360`** (the boot script's hardcoded consumer listener — confirm in CONSUMERS.log), NOT directly to the upstream `node-urls`. In production all traffic flows through the consumer, so this is the only representative path: it exercises consumer → provider → node and surfaces spec-level parse/result-directive bugs that a direct-to-node call would hide. Classify the consumer's response. |

Response classification:
- Response with `result` field (any value, including empty) → **PASS** (method exists and responded).
- Response with `error.code == -32601` → **FAIL** (method does not exist on chain).
- Response with `error.code == -32602` (invalid params) → **PASS-existence** (method exists; full functional probe would need correct args).
- Response with any other `error.code` → **WARN** (record code + message).
- Timeout (no response in 10s) → **TIMEOUT**.
- Node disagreement (2-3 nodes return materially different shapes for the same method) → **WARN-DISAGREEMENT** (record which nodes disagree).

## Step 4.5 — Scan the probe window for provider/consumer errors

Step 4 only sees the consumer's HTTP/JSON-RPC reply. A relay can return a plausible-looking body while the provider or consumer logs a spec-level error the response classification misses (node rejection, result-parsing fallback, parse-directive mismatch). Scan the lines emitted **during the probe window** in BOTH logs and fold real findings into the report.

Slice each log from the offset recorded in Step 4 (`P0`/`C0`) and keep only `WRN/ERR/FTL/PNC` lines, dropping the known-benign patterns (these are always present and are NOT spec defects):

```bash
# benign noise to exclude:
#   Self signed certificate          — local test cert
#   OTel SDK reported / :4318         — no local OTel collector
#   Chain Tracker / UNKNOWN_BLOCK / DB Not Found Error
#                                     — chaintracker probing archive-depth blocks (transient)
BENIGN='Self signed certificate|OTel SDK reported|:4318|could not get block data in Chain Tracker|UNKNOWN_BLOCK|DB Not Found Error'

tail -n +$((P0+1)) testutil/debugging/logs/PROVIDER1.log | grep -E '\b(WRN|ERR|FTL|PNC)\b' | grep -Ev "$BENIGN" || true
tail -n +$((C0+1)) testutil/debugging/logs/CONSUMERS.log | grep -E '\b(WRN|ERR|FTL|PNC)\b' | grep -Ev "$BENIGN" || true
```

Consumer relay errors carry the RPC method inside an **escaped** `request="…"` field. Map them back to the probed method:

```bash
tail -n +$((C0+1)) testutil/debugging/logs/CONSUMERS.log | grep -E '\b(ERR|FTL|PNC)\b' | grep -Ev "$BENIGN" \
  | grep -oE '\\"method\\":\\"[a-zA-Z0-9_]+' | sed -E 's/.*\\"/method=/' | sort | uniq -c
```

For each surviving line:
- **Method-associated** (has a `request=`/`method=` field): downgrade that method's classification to at least **WARN** in the report, citing the `error=` text and any `code=`. If Step 4 already classified it FAIL on the same `-32601`, keep FAIL — do not double-count; the scan only adds signal Step 4 missed.
- **Not method-associated** (provider-wide error): record it in the report's "Log-scan findings" section.
- **`FTL`/`PNC` after successful boot**: a runtime crash *during probing*. Capture the full line, flag it prominently, and note the run is unreliable.

## Step 5 — Write the probe report

```bash
mkdir -p specs/docs/<chain>
```

Write `specs/docs/<chain>/METHOD_PROBE_REPORT.md`:

```markdown
# Method Probe Report — <chain>

Generated: <UTC timestamp>
Provider config: testutil/debugging/logs/<chain>_provider.yml
Spec variant: <INDEX> (<INTERFACE>)
Nodes probed: <URL_1>, <URL_2>, <URL_3>

| Method | Classification | Node 1 | Node 2 | Node 3 | Notes |
|---|---|---|---|---|---|
| <method> | <PASS/FAIL/SKIP/WARN/TIMEOUT> | <code> | <code> | <code> | <one-line note> |
| ... |

## Log-scan findings (probe window)

Non-benign WRN/ERR/FTL/PNC lines logged during probing (Step 4.5). Empty table = clean.

| Source | Level | Associated method | error= excerpt |
|---|---|---|---|
| CONSUMERS.log | ERR | <method or —> | <excerpt> |
```

## Step 6 — Tear down

```bash
screen -X -S provider1 quit 2>/dev/null || true
screen -X -S consumers quit 2>/dev/null || true
screen -X -S node quit 2>/dev/null || true
screen -wipe 2>/dev/null || true
```

Repeat Steps 1–6 for each `(spec_variant, api_interface)` pair if more than one was passed in. Each iteration starts from a fresh lava node (the init script wipes screens and logs at startup).

## Return to orchestrator

Return a short summary:

1. The absolute path to `specs/docs/<chain>/METHOD_PROBE_REPORT.md`.
2. Counts: `PASS=<n> FAIL=<n> SKIP=<n> WARN=<n> TIMEOUT=<n> LOG_WARN=<n>` (`LOG_WARN` = non-benign log-scan lines from Step 4.5).
3. The names of any FAIL/TIMEOUT methods (one per line), plus any method downgraded to WARN by the log scan, so the orchestrator can decide whether to fix the spec before Phase 9.
4. Teardown status (clean exit / leftover screens).

Do NOT echo the full probe report into your response — the orchestrator reads it from disk if it needs the detail.

END-OF-LOCAL-PROVIDER-TESTER-SENTINEL
