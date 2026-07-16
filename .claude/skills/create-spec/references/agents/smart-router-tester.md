# Smart-Router Tester (Phase 8 of create-spec)

You are a subagent dispatched by the create-spec orchestrator to boot the chain spec inside a dockerized **smart-router** and run a multi-node method probe. The orchestrator delegates this entire phase to you to keep its own context free of long-running boot/probe output.

Unlike the old local-provider flow, there is **no lava node, no gov proposal, no provider/consumer `screen` sessions, and no source build**. The smart-router is a prebuilt reverse-proxy image that loads the spec graph statically (`--use-static-spec`) and forwards requests to the chain's public RPC upstreams you configure. A boot of the router is seconds-to-a-minute, not 5–15 minutes.

**Execute the steps below verbatim. Do NOT improvise the config format and do NOT swap in a different image.** The image is `ghcr.io/magma-devs/smart-router:main` (see <https://github.com/Magma-Devs/smart-router/>).

## Inputs (substituted by orchestrator before dispatch)

- `<chain>` — the lowercased chain name (e.g., `iota`, `polygon`) — used for filenames/container name
- `<INDEX>` — the spec index UPPERCASE (e.g., `IOTA`, `IOTAT`) — must equal the `chain-id` in both the spec and the router config
- `<INTERFACE>` — one of `jsonrpc`, `rest`, `grpc`, `tendermintrpc`
- `<NODE_URL_1>`, `<NODE_URL_2>`, `<NODE_URL_3>` — 1–3 public node URLs (https://... ; ws/wss for subscriptions). These come from the **Phase 7.5 keyed candidate list** (validated-OK entries), each with a known transport — use the transport as given; do not re-derive it.
- `<WS_URL>` (optional) — a separate WebSocket URL for chains with subscriptions; if provided, add it to every `direct-rpc` block's `node-urls` list
- `<EXTRA_INTERFACES>` (optional) — for multi-interface chains (e.g., Cosmos: rest + tendermintrpc + grpc), a list of additional `(INTERFACE, urls, transport)` blocks from the candidate list; each gets its own listener port (3361, 3362, …) and its own `direct-rpc` upstreams

**gRPC node-url config shape (do not improvise):** TLS gRPC uses `grpcs://host:port`. Plaintext gRPC uses `grpc://host:port` AND requires both `grpc-config.allow-insecure: true` on the node-url entry **and** the `--allow-insecure-provider-dialing` CLI flag on the router (neither alone is sufficient; `disable-tls` / top-level `allow-insecure` are ineffective). A bare `host:port` is rejected with `invalid gRPC URL scheme`. Example plaintext entry:
```yaml
- url: "grpc://host:port"
  grpc-config:
    allow-insecure: true
```

**gRPC per-method probing is direct-to-upstream.** The smart-router gRPC listener exposes no server reflection, so `grpcurl`-through-the-router is impossible. Boot, verifications, and chain-tracking go *through* the router (and prove routing works); per-method probes hit the upstream `node-url` directly. Label these rows in the report as direct-upstream — do not imply through-router method coverage for gRPC.

**Carry forward `NOT_TESTABLE` from Phase 7.5.** For any interface/subscription/addon the candidate list marked `NOT_TESTABLE` (no endpoint found), report it `NOT_TESTABLE` with the discovery agent's "searched [sources] → none" reason — not as a probe failure or spec defect.
- `<TESTNET_INDEX>` (optional) — the testnet spec index UPPERCASE (e.g., `IOTAT`); empty → skip the Step 7 testnet pass
- `<TESTNET_NODE_URL_1>`, `<TESTNET_NODE_URL_2>` (optional) — testnet node URLs for the Step 7 testnet verification pass and the Step 8 testnet block-time measurement
- `<TESTNET_WS_URL>` (optional) — testnet `ws://`/`wss://` URL; required for the testnet pass when the spec has subscription methods (same hard requirement as Step 1b)

## Optional read

For additional context only (the steps below take precedence over anything you find here): `references/phase4-testing-and-validation.md` (observe `END-OF-PHASE4-SENTINEL`).

## Step 0 — Resolve docker (image is already authenticated + pulled)

The smart-router image is **already pulled and cached on this host before you run** — the CI workflow does `docker login ghcr.io` + `docker pull` in a pre-flight step, and the local harness pulls it once up front. GHCR auth is therefore NOT your job. Do not authenticate, and do not improvise credential discovery.

```bash
# Some hosts require sudo to reach the docker daemon socket. Detect once and
# reuse $DOCKER for every docker call below.
DOCKER="docker"; $DOCKER info >/dev/null 2>&1 || DOCKER="sudo docker"

IMAGE="ghcr.io/magma-devs/smart-router:main"

# The image is expected to be present already. Confirm, and only pull if it is
# genuinely missing (a normal pull is a cache hit and needs no credentials
# because login already ran in the workflow).
$DOCKER image inspect "$IMAGE" >/dev/null 2>&1 || $DOCKER pull "$IMAGE"
$DOCKER image inspect "$IMAGE" --format 'image ready: {{index .RepoDigests 0}}'
```

**Forbidden — never do any of these (they leak secrets into the transcript artifact and waste turns):**
- Do NOT run `env`, `printenv`, or grep the environment for `TOKEN`/`PAT`/`SECRET`.
- Do NOT read `event.json`, the runner workflow file, or any path looking for credentials.
- Do NOT call `docker login`, request a GHCR token, or exchange/print any token.

If `docker image inspect` fails AND the pull above fails (image truly unavailable, e.g. an auth/network misconfig in the workflow's pre-flight), STOP immediately and return `SMOKE: BOOT_FAILED` with ONLY the docker error line — the orchestrator surfaces it to the user, who fixes the workflow's GHCR pre-flight. Recovering the credential is never your responsibility.

## Step 1 — Assemble the spec dir + write the router config

**1a. Spec dir.** `--use-static-spec` takes a *directory*; the router loads every `*.json` in it and resolves the candidate's `imports` from the same set. All specs in this repo live flat at the root, so copy them into a clean staging dir (this includes the candidate `<chain>.json` you are testing plus every parent it imports):

```bash
SPECS_DIR="/tmp/sr_specs_<chain>"
rm -rf "$SPECS_DIR" && mkdir -p "$SPECS_DIR"
cp ./*.json "$SPECS_DIR"/
ls "$SPECS_DIR"/<chain>.json   # candidate must be present
```

**1b. Router config.** Write `/tmp/sr_<chain>.yml`. The `endpoints[]` declare the local listeners; `direct-rpc[]` declare the upstream providers the router relays to. Use EXACTLY this shape (mirrors `config/smartrouter_examples/smartrouter_eth.yml` from the smart-router repo):

```yaml
metrics-listen-address: "0.0.0.0:7779"

endpoints:
  - listen-address: "0.0.0.0:3360"
    network-address: "0.0.0.0:3360"
    chain-id: "<INDEX>"
    api-interface: "<INTERFACE>"

direct-rpc:
  - name: "<chain>-upstream-1"
    chain-id: "<INDEX>"
    api-interface: "<INTERFACE>"
    node-urls:
      - url: "<NODE_URL_1>"
      # add `- url: "<WS_URL>"` here too if the chain has subscriptions
  - name: "<chain>-upstream-2"
    chain-id: "<INDEX>"
    api-interface: "<INTERFACE>"
    node-urls:
      - url: "<NODE_URL_2>"
  - name: "<chain>-upstream-3"
    chain-id: "<INDEX>"
    api-interface: "<INTERFACE>"
    node-urls:
      - url: "<NODE_URL_3>"
```

Rules — apply exactly:
- Create **one `direct-rpc` block per node URL** passed in (1, 2, or 3). Each is a distinct upstream the router can rotate across; this is what exercises the multi-node probe.
- `chain-id` is the spec index — UPPERCASE — and MUST match a `proposal.specs[].index` inside `<chain>.json`. A mismatch fails the router's startup spec resolution.
- **Subscriptions (HARD requirement, not optional).** If the spec enables ANY subscription method (a `SUBSCRIBE` parse directive anywhere in `<chain>.json`'s resolved import closure — e.g. `eth_subscribe` inherited from ETH1), then **every** `direct-rpc` block's `node-urls` MUST include a `ws://`/`wss://` URL alongside the https URL. The router does NOT treat this as a warning: a provider with no ws upstream **fails verification and is excluded from the provider list**, and once every provider is excluded the router exits at boot with:
  ```
  static provider: failed creating chain router — excluding from provider list
  all static providers failed verification — cannot serve endpoint
  ```
  So: add `<WS_URL>` (or any `wss://` node URL) to every block. If the spec has subscriptions and you were given NO ws/wss URL, do not boot a doomed config — STOP and return `SMOKE: BOOT_FAILED` noting that a ws/wss upstream is required for this chain, so the orchestrator can ask the user for one. (Check with: `jq -e '[.proposal.specs[].api_collections[]?.parse_directives[]? | select(.function_tag == "SUBSCRIBE")] | any' <chain>.json` → `true` means subscriptions are present. Resolve `imports` too — the subscribe directive is often inherited, e.g. from ETH1.)
- **Multi-interface chains** (`<EXTRA_INTERFACES>` non-empty): add one more `endpoints[]` entry per extra interface on the next free port (`3361`, `3362`, …, same `chain-id`, the extra `api-interface`) AND a matching set of `direct-rpc[]` blocks for that interface's upstreams. See `config/smartrouter_examples/smartrouter_lava.yml` (rest + grpc + tendermintrpc) for the multi-interface shape.
- `addons:` on a `node-urls` entry tells the router that upstream serves an addon/extension (`archive`, `debug`, `trace`, …) and arms the matching startup verifications. Do NOT guess them here — leave them out of the initial config; Step 1c probes each upstream and adds only the addons it actually supports. (The spec-side `add_on` field still lives in `collection_data`, not in this config.)

After writing, confirm it parses as YAML and dump it:

```bash
cat /tmp/sr_<chain>.yml
python3 -c 'import yaml; yaml.safe_load(open("/tmp/sr_<chain>.yml"))' && echo "YAML OK"
```

## Step 1c — Addon & extension capability matrix

Every addon and extension the spec declares must be either tested or explicitly reported as untestable. Build the matrix BEFORE booting.

**1c-i. Inventory.** Collect every distinct addon and extension name from the candidate spec (and its imported parents in `$SPECS_DIR`, since verifications inherit):

```bash
# addons: non-empty collection_data.add_on values
jq -r '[.. | objects | .add_on? // empty] | map(select(. != "")) | unique[]' <chain>.json
# extensions: extension fields on verification values + any extensions arrays
jq -r '[.. | objects | .extension? // empty] | map(select(. != null and . != "")) | unique[]' <chain>.json
```

If both lists are empty → record `ADDONS: none declared` and skip to Step 2.

**1c-ii. Per-upstream capability probe (direct to the node URL, NOT the router — the router isn't up yet).** For each `(addon_or_extension, upstream)` pair:

- If the spec has a verification gated on it (a `verifications[]` entry whose `values[]` contains that `extension`/addon): issue that verification's `function_template` directly to the upstream, walk `result_parsing.parser_arg`, and compare against the value's `expected_value` (e.g. `archive` → earliest block must be `0x0`) or sanity-check the type when there is no `expected_value`.
- Otherwise (addon with no verification): call the FIRST method of that addon's collection with the simplest valid params; `-32601` → unsupported, any `result`/`-32602` → supported.

Record per pair: `SUPPORTED` | `UNSUPPORTED (error/code)` | `INCONCLUSIVE (timeout)`.

**1c-iii. Update the config.** For every upstream, add the addons/extensions it supports to its `node-urls` entries in `/tmp/sr_<chain>.yml`:

```yaml
    node-urls:
      - url: "<NODE_URL_1>"
        addons: [archive, debug]   # only what THIS upstream passed in 1c-ii
```

Do NOT add an addon the upstream failed — its startup verification (severity `Fail`) would exclude that provider from serving everything. An addon supported by ZERO upstreams is `NOT_TESTABLE` — leave it out of the config and carry it to the coverage table with the per-upstream probe evidence.

Re-validate the YAML after editing (same `python3 -c` check as Step 1b).

## Step 2 — Boot the router container

Publish each listener port and mount the spec dir + config read-only. `--use-static-spec specs/` and the config path are resolved relative to the image WORKDIR `/smart-router`, so mount the spec dir at `/smart-router/specs` and the config at `/smart-router/sr.yml`.

```bash
$DOCKER rm -f sr_<chain> 2>/dev/null || true
$DOCKER run -d --name sr_<chain> \
  -p 3360:3360 \
  `# add -p 3361:3361 -p 3362:3362 ... one per extra-interface listener` \
  -p 7779:7779 \
  -v "$SPECS_DIR":/smart-router/specs:ro \
  -v /tmp/sr_<chain>.yml:/smart-router/sr.yml:ro \
  "$IMAGE" \
  sr.yml --geolocation 1 --use-static-spec specs/ --log-level debug --log-format json
```

## Step 3 — Wait for the router to be ready

The router verifies each upstream at startup (e.g. a `chain-id` check) before it begins serving. A spec-level defect — a bad `result_parsing`, a wrong `chain-id` `expected_value`, an unresolvable `imports` chain — surfaces here as a startup failure. That is the spec-level signal this phase exists to catch.

```bash
# Poll: ready when the listener answers, fail fast on fatal log lines.
timeout 120 bash -c '
  while true; do
    if curl -s -o /dev/null -m 3 http://localhost:3360 \
         -H "content-type: application/json" \
         -d "{\"jsonrpc\":\"2.0\",\"method\":\"\",\"params\":[],\"id\":1}"; then
      echo READY; break
    fi
    if '"$DOCKER"' logs sr_<chain> 2>&1 | grep -qiE "panic|fatal|failed to (load|expand|resolve) spec|all static providers failed verification|cannot serve endpoint|no matching spec"; then
      echo FATAL; break
    fi
    sleep 2
  done'

$DOCKER logs --tail 60 sr_<chain> 2>&1
```

**Common boot failure — `all static providers failed verification — cannot serve endpoint`:** the most frequent cause is the missing-ws case above (the log will also say `websocket is not provided in 'supported' map`). Fix the config by adding a `wss://` upstream to every `direct-rpc` block and re-boot; do not treat it as a spec defect. Other causes: a wrong `chain-id` `expected_value` verification (the upstream's real chain-id differs) or an upstream that doesn't actually serve `<INTERFACE>` — those ARE spec/config issues to report.

For non-jsonrpc interfaces (`rest`/`grpc`/`tendermintrpc`) the readiness probe differs — for `rest`/`tendermintrpc` a `GET http://localhost:3360/<a known path>` returning any HTTP status means the listener is up; for `grpc` a TCP connect (`bash -c '</dev/tcp/localhost/3360'`) is sufficient. Use whichever matches `<INTERFACE>`.

If the logs show `panic`, `fatal`, `failed to load/expand/resolve spec`, `all static providers failed verification`, `cannot serve endpoint`, or `no matching spec` before the listener answers, STOP. Capture the full log (`$DOCKER logs sr_<chain>`), go to Step 6 (teardown), and return `SMOKE: BOOT_FAILED` with the excerpt (and, if it is the missing-ws case, say so explicitly). Do NOT skip to Step 4.

Deliberately NOT a fail-fast trigger: per-provider lines like `failed verification on provider startup` or `ATTENTION: some static providers failed verification and were excluded`. The router still boots and serves when at least one provider passes — those partial failures are classified in Step 3.5 (c) instead of aborting the run here.

## Step 3.5 — Parse-directive & verification runtime check (metrics + log signatures)

Once booted, the router's chain tracker continuously *executes* the spec's parse directives against the real upstreams: `GET_BLOCKNUM` via `FetchLatestBlockNum` and `GET_BLOCK_BY_NUM` via `FetchBlockHashByNum`. This is the authoritative test of the directives — stronger than Phase 6's offline curl+jq approximation. Run it BEFORE the first probe so the log window is purely tracker traffic.

**a. Let the tracker complete a few fetch cycles, then read BOTH sources — the metrics AND the tracker's own log signal.** The tracker runs `GET_BLOCKNUM` and `GET_BLOCK_BY_NUM` every poll; classify each directive from whichever source has evidence, **with a failure from either source winning over a positive from the other** (a positive must never mask a real parse defect):

```bash
sleep 30
# Source 1 — metrics. The metric names are PREFIX-AGNOSTIC on purpose: smart-router
# v1.0.4 (PR #138, "drop the lava prefix") renamed every Prometheus metric —
# `lava_rpcsmartrouter_latest_block` → `smartrouter_latest_block`, and
# `lava_rpc_endpoint_*` → `rpc_endpoint_*`. The `:main` image now emits the NEW
# names; older pinned images emit the old `lava_`-prefixed ones. The `(lava_)?`
# and `(rpcsmartrouter|smartrouter)` alternations below match BOTH so this check
# never silently falls through to the log-only path just because of the rename.
curl -s http://localhost:7779/metrics | grep -E '^(lava_)?(rpc_endpoint_(latest_block|fetch_latest_(fails|success)|fetch_block_(fails|success))|(rpcsmartrouter|smartrouter)_latest_block)'
# Source 2 — the tracker's hash-read log lines: this is where GET_BLOCK_BY_NUM is actually executed.
# (The fetch_block_* metric is currently never emitted by the router — RecordBlockFetch is only ever
#  called with isLatest=true — so for GET_BLOCK_BY_NUM the LOG is the primary positive signal.)
$DOCKER logs sr_<chain> 2>&1 | grep -cE 'Chain Tracker Updated block hashes|Chain Tracker read a block Hash'
```

Classify each directive with **fail-precedence** — check the FAIL condition first; a positive applies only when neither source shows failure:

| Directive | FAIL if … | else OK if … | else |
|---|---|---|---|
| **PARSE_BLOCKNUM** | the `*_latest_block` gauge (`smartrouter_latest_block`, or legacy `lava_rpcsmartrouter_latest_block`) is `0`/absent, **or** a `PARSE_SIG` line (step b) names the `GET_BLOCKNUM` path | that `*_latest_block` gauge > 0 (metric) **or** a `Chain Tracker Updated block hashes` line (log) | **NOT_EXERCISED** — tracker never ran; usually a boot problem, investigate |
| **PARSE_BLOCK_BY_NUM** | `fetch_block_fails` > 0 with `..._success` == 0 (metric), **or** a `PARSE_SIG` line (step b) names `ParseBlockHashFromReplyAndDecode` / `expected parsed hashes length` (log) | `fetch_block_success` > 0 (metric) **or** ≥1 `Chain Tracker Updated block hashes` / `read a block Hash …` line (log — tracker read & stored by-number hashes) | **NOT_EXERCISED** |

The metric-OR-log design is deliberate and self-healing: the `fetch_block_*` metric is dead in the current router, so `PARSE_BLOCK_BY_NUM: OK` comes from the **log**; if the router later wires the metric it simply becomes a second positive source, no doc change. A few `fetch_latest_fails` alongside a healthy `latest_block` is transient endpoint noise, not a directive defect — the rules above decide, the logs explain.

**Slot-based chains (Solana, Ethereum Beacon) — missed-slot 404s are NOT a directive defect.** On chains whose block-number is a slot with gaps, `GET_BLOCK_BY_NUM` (`getBlock(%d)` / `/eth/v1/beacon/headers/%d`) returns 404/"not found" whenever the tracker walks onto an EMPTY slot (~1% of slots). With a SINGLE upstream, the tracker's retries on that empty slot can drive the one provider's availability below the routing threshold and yield "No pairings available" — a deployment/upstream-count artifact, NOT a `PARSE_BLOCK_BY_NUM` defect. Classify PARSE from the rules above: if the tracker read ANY by-number hash before the empty slot (a `Chain Tracker Updated block hashes` / `read a block Hash` line with the `parser_arg` pointing at the block hash/root, not the echoed slot), PARSE_BLOCK_BY_NUM is **OK** — report the availability degradation as a `SINGLE_UPSTREAM` note, not a spec FAIL. A genuine PARSE_BLOCK_BY_NUM FAIL is a `ParseBlockHashFromReplyAndDecode` / `expected parsed hashes length` signature that fires on NON-empty slots too. If you were given ≥2 upstreams, degradation should not occur; if only 1 was available, say so. Do NOT recommend rewriting the `%d` template to `finalized`/`latest` — that breaks the per-slot walk (see spec-builder "slot-based chains").

**b. Grep the boot-window log for parse-failure signatures.** These come from `endpoint_chain_fetcher.go` and `parser.go` and most are **DEBUG level**, so the Step 4.5 warn/error scan never sees them (this is why the router runs with `--log-level debug`):

```bash
PARSE_SIG='failed to parse response|failed formatResponseForParsing|failed ParseBlockHashFromReplyAndDecode|failed CraftChainMessage|Failed parsing default value|blockParsing - |expected parsed hashes length|tried decoding a hex response|failed to parse generic parser path|failed to unmarshal result'
$DOCKER logs sr_<chain> 2>&1 | grep -E "$PARSE_SIG" | head -20
```

Interpretation: `blockParsing - rpcInput is error` means the upstream returned an RPC error (endpoint issue, not directive defect); the other signatures point at the directive itself. Use the metrics verdict from (a) as the gate; use these lines as the diagnosis to report.

**c. Scan the boot window for verification outcomes.** Every spec verification (`chain-id`, `pruning`, etc.) executes per provider at startup. `pruning` is how `GET_EARLIEST_BLOCK` gets exercised — the chain tracker never calls it — and a verification that fails on *some* providers does NOT fail the boot; the router just excludes them and serves with the rest, so without this scan the defect passes silently:

```bash
# Positive signal: one success line per (verification, provider) that ran
$DOCKER logs sr_<chain> 2>&1 | grep -F '[+] verified successfully' \
  | grep -oE '"verification":"[a-z0-9_-]+"' | sort | uniq -c

# Failures + exclusions
$DOCKER logs sr_<chain> 2>&1 | grep -E '\[-\] verify|failed verification on provider startup|invalid Verification on provider startup|some static providers failed verification|Bad verification definition' | head -20
```

Classify each verification name that appears in the spec (`jq -r '.proposal.specs[].api_collections[]?.verifications[]?.name' <chain>.json | sort -u`):

- Succeeds on every provider → **OK**.
- Fails on EVERY provider (but the router still boots because another collection/interface passed) → **VERIFY: FAIL** — the directive or `expected_value` is wrong (e.g. a broken `GET_EARLIEST_BLOCK` template/`parser_arg`, or a wrong chain-id `expected_value`). Spec defect.
- Fails on SOME providers → **VERIFY: PARTIAL** — usually an upstream capability issue (e.g. a pruned node failing `pruning`'s `latest_distance`), not a spec defect. Record which upstream was excluded; remaining probes only exercise the survivors.
- `Bad verification definition` → **VERIFY: FAIL** — the verification references a `function_tag` that has no matching entry in `parse_directives`. Always a spec defect.
- Appears in neither success nor failure lines → **NOT_EXERCISED**. After Step 1c this should only happen when no upstream supports the gating addon/extension (i.e. the pair is `NOT_TESTABLE`) — cross-check against the Step 1c matrix; if a supporting upstream IS configured and the verification still never ran, flag it as a finding.

If **PARSE_BLOCKNUM: FAIL** → this is a spec defect of the highest order (the router cannot track the chain). Record it prominently; still continue to Step 4 so the report is complete, but the overall run must surface `PARSE: FAIL` to the orchestrator. A **VERIFY: FAIL** likewise must surface to the orchestrator (see the return format).

## Step 4 — Method-probe loop

**Before sending the first probe**, record the current log length so Step 4.5 can isolate only the lines emitted during probing:

```bash
P0=$($DOCKER logs sr_<chain> 2>&1 | wc -l)
echo "P0=$P0"
```

For every API in every collection of the current spec variant, send the call **through the router at `localhost:3360`** (the matching listener port for `<INTERFACE>`), NOT directly to the upstream `node-urls`. In production all traffic flows through the router, so this is the only representative path: it exercises client → router → upstream and surfaces spec-level parse/result-directive bugs that a direct-to-node call would hide.

| Category | Probe action |
|---|---|
| `category.stateful: 1` | SKIP. Record reason: "stateful — would broadcast transaction". |
| subscribe method (named by a `SUBSCRIBE` parse directive) | Open a WebSocket to the router (`ws://localhost:3360` — confirm the ws path in the startup logs), send the subscribe call with sample params from the spec's `parse_directive`/`block_parsing` hints, **wait up to 30 seconds for at least one message**, then send unsubscribe. PASS = ≥1 message received. FAIL = timeout. Probe via the router, not the upstream node. |
| Anything else | Build the simplest valid call from `block_parsing` + `parse_directive` hints and POST it to `http://localhost:3360` (jsonrpc/tendermintrpc) or GET the REST path (rest). Classify the router's response. |

Example jsonrpc probe:

```bash
curl -s -m 10 -X POST http://localhost:3360 \
  -H "content-type: application/json" \
  -d '{"jsonrpc":"2.0","method":"<method>","params":[],"id":1}'
```

**Addon & extension probes** (skip pairs marked `NOT_TESTABLE` in Step 1c — record them as such, do not probe):
- Methods in an addon collection (`collection_data.add_on` non-empty) are probed like any other method — the router routes them to the upstreams configured with that addon in Step 1c. If EVERY addon method fails with "api not supported"/no-provider errors despite a supporting upstream, that is a spec/routing defect → the addon is `TESTED_FAIL`.
- For each extension (e.g. `archive`): send one representative call through the router with the extension header, e.g.:

  ```bash
  curl -s -m 10 -X POST http://localhost:3360 \
    -H "content-type: application/json" -H "lava-extension: archive" \
    -d '<a historical-block call, e.g. eth_getBalance at an early block>'
  ```

  PASS = valid `result`; "no chain proxy supporting requested extensions" or no-provider error despite a supporting upstream = `TESTED_FAIL`.

**Live-input resolution (do this BEFORE probing parameterized methods).** A probe failure caused by a stale/placeholder argument is a *probe-setup* artifact, not a missing method — e.g. an Algorand stateproof call against `round 1` fails, but against a valid recent round it passes. Before the loop, resolve a handful of live values from the node and substitute them into any param that needs one: latest block number + hash (`GET_BLOCKNUM`/`GET_BLOCK_BY_NUM` already give these), current round/height, a recent tx hash/id if one is cheaply available, a well-known address. **Never probe a method that takes a block/round/height/hash/address with a hardcoded placeholder like `1`, `0x1`, or a zero hash.**

**Re-probe-once gate.** A method whose first probe yields `FAIL`/`WARN`/`TIMEOUT` **and** takes any input argument (block/round/height/hash/address/range) MUST be re-probed ONCE with freshly-resolved live inputs before its result is recorded. Only a failure that *survives* the re-probe is recorded as `FAIL`/`WARN`/`TIMEOUT`; if the re-probe passes, record the pass. `error.code == -32601` (method-not-found) is input-independent — no re-probe needed, record `FAIL` directly. This stops bad-input false-fails from ever reaching the Phase 10 fix list.

Response classification:
- Response with `result` field (any value, including empty) → **PASS** (method exists and responded).
- Response with `error.code == -32601` → **FAIL** (method does not exist on chain / not routed).
- Response with `error.code == -32602` (invalid params) → **PASS-existence** (method exists; full functional probe would need correct args).
- Response with any other `error.code` → **WARN** (record code + message) — subject to the re-probe-once gate above.
- Timeout (no response in 10s) → **TIMEOUT** — subject to the re-probe-once gate above.
- Node disagreement (different upstreams return materially different shapes for the same method) → **WARN-DISAGREEMENT** (record which upstream; the router rotates across them, so repeat the call a few times to surface disagreement).

## Step 4.5 — Scan the probe window for router errors

Step 4 only sees the router's HTTP/JSON-RPC reply. The router can return a plausible-looking body while logging a spec-level error the response classification misses (upstream rejection, result-parsing fallback, parse-directive mismatch). Scan the lines emitted **during the probe window** in the container log and fold real findings into the report.

The router runs with `--log-format json`, so each line is a JSON object with a `level` field. Slice from offset `P0`, keep only warn/error/fatal/panic levels, and drop known-benign patterns (best-effort allow-list — adjust if your run surfaces a new always-present noise line):

```bash
# benign noise to exclude (transient / environmental, NOT spec defects):
#   self signed certificate / x509     — public-endpoint TLS quirks
#   OTel / :4318 / metrics              — no local OTel collector
#   chain tracker / ChainTracker / UNKNOWN_BLOCK / DB Not Found / failed fetching data
#                                       — chaintracker probing archive-depth blocks (transient).
#                                         Safe to allow-list HERE because directive-level parse
#                                         failures are caught separately by Step 3.5 (metrics +
#                                         debug-level signatures), which this filter cannot mask.
#   WebSocket SendRequest not implemented
#                                       — a wss upstream that only does subscriptions, not
#                                         request/response GET_BLOCKNUM; the router retries on
#                                         the paired http URL, so this is noise as long as an
#                                         http upstream is also present (it always should be)
BENIGN='self signed certificate|x509|OTel|:4318|otel|chain tracker|ChainTracker|WebSocket SendRequest not implemented|failed fetching data from the node|UNKNOWN_BLOCK|DB Not Found'

$DOCKER logs sr_<chain> 2>&1 | tail -n +$((P0+1)) \
  | grep -iE '"level":"(warn|error|fatal|panic)"|\b(WRN|ERR|FTL|PNC)\b' \
  | grep -Eiv "$BENIGN" || true
```

Router relay errors carry the RPC method inside a `method`/`request` field. Map them back to the probed method:

```bash
$DOCKER logs sr_<chain> 2>&1 | tail -n +$((P0+1)) \
  | grep -iE '"level":"(error|fatal|panic)"' | grep -Eiv "$BENIGN" \
  | grep -oE '"method":"[a-zA-Z0-9_]+"' | sort | uniq -c
```

For each surviving line:
- **Method-associated** (has a `method=`/`request=` field): downgrade that method's classification to at least **WARN** in the report, citing the error text and any code. If Step 4 already classified it FAIL on the same `-32601`, keep FAIL — do not double-count.
- **Not method-associated** (router-wide error): record it in the report's "Log-scan findings" section.
- **`fatal`/`panic` after a successful boot**: a runtime crash *during probing*. Capture the full line, flag it prominently, and note the run is unreliable.

## Step 5 — Write the probe report

```bash
mkdir -p docs/<chain>
```

Write `docs/<chain>/METHOD_PROBE_REPORT.md`:

```markdown
# Method Probe Report — <chain>

Generated: <UTC timestamp>
Router image: ghcr.io/magma-devs/smart-router:main
Router config: /tmp/sr_<chain>.yml
Spec variant: <INDEX> (<INTERFACE>)
Upstreams probed: <URL_1>, <URL_2>, <URL_3>

## Parse-directive & verification runtime check (Step 3.5)

| Check | Verdict | Evidence |
|---|---|---|
| GET_BLOCKNUM (router latest_block) | <OK/FAIL> | smartrouter_latest_block=<value> (or legacy lava_rpcsmartrouter_latest_block) |
| GET_BLOCK_BY_NUM (log hash-reads ∥ fetch_block counters) | <OK/FAIL/NOT_EXERCISED> | hash_read_lines=<n>; metric success=<n> fails=<n> |
| Parse-signature log lines | <none / excerpt> | <up to 5 lines> |

| Verification | Verdict | Providers OK/failed | Notes |
|---|---|---|---|
| <name, one row per spec verification> | <OK/FAIL/PARTIAL/NOT_EXERCISED> | <n>/<n> | <excluded upstream / failure excerpt> |

## Addon & extension coverage (Step 1c + probes)

One row per addon/extension declared in the spec. Classifications:
**TESTED_OK** — ≥1 upstream supports it, boot verification passed, router probe passed.
**TESTED_FAIL** — a supporting upstream exists but the boot verification or the router probe failed (spec/routing defect).
**NOT_TESTABLE** — no provided upstream supports it (include the per-upstream probe evidence so a reviewer can supply a better node).

| Name | Type | Upstreams supporting | Boot verification | Router probe | Classification |
|---|---|---|---|---|---|
| <archive/debug/trace/...> | <addon/extension> | <which of 1-3, or none> | <OK/FAIL/n-a> | <PASS/FAIL/—> | <TESTED_OK/TESTED_FAIL/NOT_TESTABLE> |

| Method | Classification | Upstream notes | Notes |
|---|---|---|---|
| <method> | <PASS/FAIL/SKIP/WARN/TIMEOUT> | <code(s)> | <one-line note> |
| ... |

## Log-scan findings (probe window)

Non-benign warn/error/fatal/panic lines logged during probing (Step 4.5). Empty table = clean.

| Level | Associated method | error excerpt |
|---|---|---|
| ERR | <method or —> | <excerpt> |

## Testnet verification pass (Step 7)

TESTNET_VERIFY: <OK/FAIL/PARTIAL/SKIPPED (+ skip reason)>

| Verification | Verdict | Providers OK/failed | Notes |
|---|---|---|---|
| <name> | <OK/FAIL/PARTIAL/NOT_EXERCISED> | <n>/<n> | <testnet expected_value checked / failure excerpt> |

## Empirical block time (Step 8)

| Network | RPC | Empirical (ms) | Spec effective (ms) | Drift | Verdict |
|---|---|---|---|---|---|
| mainnet | <url> | <n> | <n> | <±n%> | <OK / BLOCK_TIME_MISMATCH> |
| testnet | <url or skipped> | <n or -> | <n> | <±n% or -> | <OK / BLOCK_TIME_MISMATCH / skipped> |
```

## Step 6 — Tear down

```bash
$DOCKER rm -f sr_<chain> 2>/dev/null || true
```

Repeat Steps 1–6 for each `(spec_variant, api_interface)` pair if more than one was passed in. Each iteration uses a fresh container (no shared state between runs).

## Step 7 — Testnet verification pass (boot + verifications only, NO method probe)

Skip ONLY if `<TESTNET_INDEX>` is empty or no testnet node URL was provided — then record `TESTNET_VERIFY: SKIPPED (no testnet inputs)` in the report and the return summary.

The testnet spec entry thin-inherits the mainnet entry, but its overrides — above all the testnet chain-id `expected_value`, which is often set from convention rather than live-verified — are exercised by NOTHING else in the pipeline. So boot the router once against the TESTNET variant and confirm the verifications pass there too. This pass is boot + Step 3.5 only; do not run the Step 4 method-probe loop.

1. Write `/tmp/sr_<chain>_testnet.yml` — same shape as Step 1b, but `chain-id: "<TESTNET_INDEX>"` on the endpoint and every `direct-rpc` block, using the testnet node URLs (one block per URL). If the spec has subscription methods, every block needs `<TESTNET_WS_URL>` — if the spec has subscriptions and no testnet ws/wss URL was provided, record `TESTNET_VERIFY: SKIPPED (subscriptions present, no testnet ws URL)` rather than booting a doomed config.
2. Boot a separate container `sr_<chain>_testnet` publishing ports `3460:3360` and `7879:7779` (Step 2 with names/ports swapped), and wait for readiness (Step 3, against `localhost:3460`).
3. Run the full Step 3.5 check against it — metrics on `localhost:7879`, log greps on the `sr_<chain>_testnet` container. Classify `PARSE_BLOCKNUM` and every verification (`chain-id` with the TESTNET `expected_value`, `pruning`, addon `enabled` checks, …) as OK/FAIL/PARTIAL/NOT_EXERCISED.
4. Tear down: `$DOCKER rm -f sr_<chain>_testnet`.

Overall verdict `TESTNET_VERIFY: OK | FAIL | PARTIAL | SKIPPED` — same aggregation rules as the mainnet VERIFY verdict. A testnet chain-id mismatch or boot failure on spec resolution is a spec defect of the same severity as a mainnet one.

## Step 8 — Empirical block time (mainnet AND testnet, direct RPC)

Measure both networks' block times empirically — testnets often run faster or slower than mainnet, and the testnet spec entry inherits `average_block_time` from mainnet unless it sets its own override.

Recipe for `jsonrpc` EVM chains (adapt for other families: cosmos → header timestamps from `/block`; solana → `getBlockTime` deltas; substrate → block timestamps via `chain_getBlock`; if no recipe fits, record "skipped: no recipe for <family>"):

```bash
measure_abt() { # $1 = rpc url
  L_HEX=$(curl -s -m 10 -X POST -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' "$1" | jq -r .result)
  [[ "$L_HEX" =~ ^0x[0-9a-fA-F]+$ ]] || { echo "skipped: latest fetch failed"; return; }
  L=$((L_HEX)); E=$((L-100))
  T_L=$(curl -s -m 10 -X POST -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"$(printf '0x%x' $L)\",false],\"id\":1}" "$1" | jq -r .result.timestamp)
  T_E=$(curl -s -m 10 -X POST -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"$(printf '0x%x' $E)\",false],\"id\":1}" "$1" | jq -r .result.timestamp)
  echo "abt_ms=$(( ( $((T_L)) - $((T_E)) ) * 1000 / 100 ))"
}
measure_abt "<NODE_URL_1>"            # mainnet
measure_abt "<TESTNET_NODE_URL_1>"    # testnet — skip if empty
```

Compare each measurement against the spec's EFFECTIVE `average_block_time` for that network: the testnet entry inherits the mainnet value via `imports` unless it declares its own — resolve the effective value with `jq` over the spec (and its parent if needed). Deviation > 20% on either network → record `BLOCK_TIME_MISMATCH (<network>): spec=<v>ms empirical=<v>ms` in the report and the return summary. Do not edit the spec yourself — the orchestrator decides the fix (typically an explicit `average_block_time` override in the testnet entry).

## Return to orchestrator

Return a short summary:

1. The path to `docs/<chain>/METHOD_PROBE_REPORT.md`.
2. `PARSE: OK | FAIL | PARTIAL` — the Step 3.5 (a)+(b) verdict (`FAIL` if PARSE_BLOCKNUM failed; `PARTIAL` if only PARSE_BLOCK_BY_NUM failed). On FAIL/PARTIAL include the metric values and up to 5 parse-signature log lines.
3. `VERIFY: OK | FAIL | PARTIAL` — the Step 3.5 (c) verdict (`FAIL` if any verification failed on every provider or is badly defined; `PARTIAL` if providers were excluded). On FAIL/PARTIAL name the verification(s) and include the failure excerpt.
4. `ADDONS: <n> tested-ok / <n> failed / <n> not-testable` (or `none declared`) — plus the full coverage table inline (it is small): every declared addon/extension with its classification, and for `NOT_TESTABLE` the per-upstream evidence ("nodes don't support it").
5. Counts: `PASS=<n> FAIL=<n> SKIP=<n> WARN=<n> TIMEOUT=<n> LOG_WARN=<n>` (`LOG_WARN` = non-benign log-scan lines from Step 4.5).
6. The names of any FAIL/TIMEOUT methods (one per line), plus any method downgraded to WARN by the log scan, so the orchestrator can decide whether to fix the spec before Phase 9.
7. `TESTNET_VERIFY: OK | FAIL | PARTIAL | SKIPPED` — the Step 7 verdict. On FAIL/PARTIAL name the verification(s) and include the failure excerpt; on SKIPPED include the reason.
8. `BLOCK_TIME: mainnet=<ms|skipped> testnet=<ms|skipped>` — the Step 8 measurements, plus any `BLOCK_TIME_MISMATCH (<network>)` flag with the spec-vs-empirical values.
9. Teardown status (containers removed / leftover containers — both `sr_<chain>` and `sr_<chain>_testnet`).

If the router could not boot, return `SMOKE: BOOT_FAILED` plus the relevant `$DOCKER logs` excerpt instead.

Do NOT echo the full probe report into your response — the orchestrator reads it from disk if it needs the detail.

END-OF-SMART-ROUTER-TESTER-SENTINEL
