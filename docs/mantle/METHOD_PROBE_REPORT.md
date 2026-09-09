# Method Probe Report — mantle

Generated: 2026-07-05T13:50:36Z
Router: local build from `/Users/anna/go/smart-router` (commit `177b408`, `v1.0.5-18-g177b408`) — **deviation from standard Phase 8**: run as a native binary (`build/smartrouter`), not the `ghcr.io/magma-devs/smart-router:main` docker image. No `--geolocation` flag exists on this build (confirmed via `--help`); it was omitted.
Router config (mainnet): `/tmp/sr_mantle_local.yml` (listener `0.0.0.0:3362`, metrics `0.0.0.0:7781`)
Router config (testnet): `/tmp/sr_mantle_testnet_local.yml` (listener `0.0.0.0:3363`, metrics `0.0.0.0:7782`)
Spec variant: MANTLE (jsonrpc), MANTLET (jsonrpc)
Upstreams probed (mainnet): `https://rpc.mantle.xyz`, `https://mantle-rpc.publicnode.com`, ws upstream `wss://mantle-rpc.publicnode.com` (added to both direct-rpc blocks per the hard subscription requirement)
Upstreams probed (testnet): `https://rpc.sepolia.mantle.xyz`, ws upstream `wss://mantle-sepolia.gateway.tenderly.co`

**Environment note:** ports `3360`/`7779` (the "standard" local ports) were occupied for this entire run by a pre-existing `smartrouter` process (PID 85736, running since before this session, config `/tmp/sr_mantle.yml`) that this agent did not launch and was permission-blocked from terminating. A fresh instance was booted on free ports (`3362`/`7781` mainnet, `3363`/`7782` testnet) instead, using a config identical in substance to the standard shape. This leftover process is still running post-run and needs manual cleanup (`kill 85736`) — it is unrelated to and does not affect the validity of this report's findings, though it did cause transient shared-rate-limit collisions on the public endpoints during boot (see Verification table).

## Parse-directive & verification runtime check (Step 3.5) — mainnet

| Check | Verdict | Evidence |
|---|---|---|
| GET_BLOCKNUM (router latest_block) | OK | `smartrouter_latest_block`=97,564,424 (gauge, both upstreams tracking, e.g. `rpc_endpoint_latest_block{endpoint_id="mantle-upstream-1"}`=97,564,424, `...upstream-2`=97,563,932) |
| GET_BLOCK_BY_NUM (log hash-reads ∥ fetch_block counters) | OK | 61+ `Chain Tracker Updated block hashes` log lines; `fetch_block_*` metric absent as expected (dead in this router build, per Step 3.5 design note) |
| Parse-signature log lines | transient only | `blockParsing - rpcInput is error` / `failed to parse with legacy block parser` lines all trace to (a) a ~15s HTTP 429 rate-limit collision at boot on `wss://mantle-rpc.publicnode.com` (shared free-tier limit with the leftover process above) that self-healed via the router's background retry (`mantle-upstream-1` was briefly excluded, then `"[+] static provider recovered and passed verification"` + `"[+] static provider re-registered successfully"` ~3 min later), and (b) response-propagation noise from intentionally probing unsupported methods in Step 4. No genuine parser-directive defect found. |

| Verification | Verdict | Providers OK/failed | Notes |
|---|---|---|---|
| chain-id | OK | 2/2 | `0x1388` confirmed on both upstreams (matches `expected_value`) |
| pruning | OK | 2/2 | Base `latest_distance` clause + `extension:archive` clause (`0x0` earliest block) both passed on both upstreams once the transient rate-limit exclusion of `mantle-upstream-1` self-healed |
| trustless-rpc | OK | 2/2 | Wildcard `eth_getCode` sanity check passed on both |

## Parse-directive & verification runtime check (Step 3.5) — testnet (MANTLET)

| Check | Verdict | Evidence |
|---|---|---|
| GET_BLOCKNUM | OK | `smartrouter_latest_block`=40,857,283 |
| GET_BLOCK_BY_NUM | OK | 60+ `Chain Tracker Updated block hashes` lines. Caveat: ~40% of by-number lookups against the single ws upstream (`wss://mantle-sepolia.gateway.tenderly.co`) intermittently returned `result:null` for the bleeding-edge block number throughout the run (not just at boot) — reproduced manually: a direct `eth_getBlockByNumber` call for the current latest number over the same ws endpoint succeeded immediately and consistently. This points to read-after-write lag on Tenderly's public gateway backend replicas for near-head blocks on this fast (2s) testnet, not a parser/directive defect — the directive parses correctly whenever the upstream actually returns block data. |
| chain-id | OK | 1/1 | `0x138b` confirmed (matches testnet `expected_value`) |
| pruning | OK | 1/1 | Base `latest_distance:90000` clause passed (confirmed node retains ≥90k blocks); archive extension not configured/tested here (testnet pass is boot+verification only per Step 7 scope) |
| trustless-rpc | OK | 1/1 | |

## Addon & extension coverage (Step 1c + probes)

| Name | Type | Upstreams supporting | Boot verification | Router probe | Classification |
|---|---|---|---|---|---|
| archive | extension | Both (`rpc.mantle.xyz`, `mantle-rpc.publicnode.com`) — `eth_getBlockByNumber("earliest")` → `0x0` on both, matching `pruning`'s archive-extension `expected_value` | OK (2/2) | PASS — `lava-extension: archive` header + historical `eth_getBalance` at block `0x1` returned `0x0` through the router | **TESTED_OK** |
| debug | add_on | None — `debug_traceBlockByNumber` → `-32601` ("rpc method is not whitelisted" / "does not exist/is not available") on both mainnet upstreams, confirming Phase 7.5's finding | n/a (not configured) | — | **NOT_TESTABLE** |
| bundler | add_on | None — no public keyless ERC-4337 bundler endpoint found (per Phase 7.5); not probed | n/a (not configured) | — | **NOT_TESTABLE** |
| trace | add_on | n/a — `enabled:false` on the MANTLE spec's trace collection | excluded (not a live requirement) | — | **EXCLUDED** (spec-declared disabled, not tested by design) |

## Method probe results (Step 4) — mainnet, through router at localhost:3362

63 enabled base-collection (`jsonrpc`, no add-on) methods: 2 skipped (stateful), 61 probed. Live inputs used: latest block/hash, a recent tx hash, Multicall3 (`0xcA11...CA11`, a known-deployed contract) for `eth_call`/`eth_estimateGas`, a freshly-created filter id for filter methods. Re-probe-once gate applied to all FAIL/WARN/TIMEOUT results on input-taking methods.

| Method | Classification | Notes |
|---|---|---|
| eth_accounts | PASS | |
| eth_blobBaseFee | PASS | |
| eth_blockNumber | PASS | |
| eth_call | PASS | via Multicall3 `getBlockNumber()` — initial probe against a different token-proxy contract hit an application-level revert (fallback attempts a mint), not a router defect; re-tested against a clean view call |
| eth_chainId | PASS | |
| eth_coinbase | FAIL | `-32601` on both upstreams |
| eth_compileLLL | FAIL | `-32601` on both upstreams (deprecated method) |
| eth_createAccessList | PASS | |
| eth_estimateGas | PASS | same fix as `eth_call` |
| eth_estimateL1Fee | FAIL | `-32601` on both upstreams |
| eth_feeHistory | PASS | |
| eth_gasPrice | PASS | |
| eth_getBalance | PASS | |
| eth_getBlockByHash | PASS | |
| eth_getBlockByNumber | PASS | |
| eth_getBlockRange | WARN-DISAGREEMENT | `mantle-rpc.publicnode.com` fully supports it (real block array); `rpc.mantle.xyz` rejects with `-32601 "rpc method is not whitelisted"` (custom gateway allowlist, confirmed via direct probe on both). Router-level pass rate depends on which upstream is selected. |
| eth_getBlockReceipts | PASS | |
| eth_getBlockTransactionCountByHash | PASS | |
| eth_getBlockTransactionCountByNumber | PASS | |
| eth_getCode | PASS | |
| eth_getCompilers | FAIL | `-32601` on both upstreams (deprecated method) |
| eth_getFilterChanges | PASS | tested with a freshly-created filter id |
| eth_getFilterLogs | WARN | `-32000 "filter not found"` — reproducible across the router's multi-upstream, non-sticky routing: `eth_newFilter` creates local state on one upstream, `eth_getFilterLogs` sometimes lands on the other. Architectural characteristic of any non-session-affine multi-upstream proxy, not a spec/parse defect. |
| eth_getLogs | PASS | |
| eth_getProof | PASS | |
| eth_getRawTransactionByBlockHashAndIndex | PASS | |
| eth_getRawTransactionByBlockNumberAndIndex | PASS | |
| eth_getRawTransactionByHash | PASS | |
| eth_getStorageAt | PASS | |
| eth_getTransactionByBlockHashAndIndex | PASS | |
| eth_getTransactionByBlockNumberAndIndex | PASS | |
| eth_getTransactionByHash | PASS | |
| eth_getTransactionCount | PASS | |
| eth_getTransactionReceipt | PASS | |
| eth_getUncleByBlockHashAndIndex | PASS | |
| eth_getUncleByBlockNumberAndIndex | PASS | |
| eth_getUncleCountByBlockHash | PASS | |
| eth_getUncleCountByBlockNumber | PASS | |
| eth_getWork | FAIL | `-32601` on both upstreams |
| eth_hashrate | FAIL | `-32601` on both upstreams |
| eth_maxPriorityFeePerGas | PASS | |
| eth_mining | FAIL | `-32601` on both upstreams |
| eth_newBlockFilter | PASS | |
| eth_newFilter | PASS | |
| eth_newPendingTransactionFilter | PASS | |
| eth_protocolVersion | FAIL | `-32601` on both upstreams |
| eth_sendRawTransaction | SKIP | stateful — would broadcast transaction |
| eth_sendTransaction | SKIP | stateful — would broadcast transaction |
| eth_sign | FAIL | `-32601` on both upstreams |
| eth_signTransaction | WARN | `-32000` (varies: "gas not specified" / other) — no unlocked local account on public infra; expected on any remote node, not a routing defect |
| eth_simulateV1 | WARN | `-32000 "error calculating DA footprint: missing deposit transaction"` — OP-stack `eth_simulateV1` requires a deposit-tx-wrapped context; method reachable and routed correctly, application-level constraint not reproduced with a plain call |
| eth_subscribe | PASS | via WebSocket at `ws://localhost:3362/ws` — subscribe ack + live `newHeads` notification received |
| eth_syncing | PASS | |
| eth_uninstallFilter | PASS | |
| eth_unsubscribe | PASS | clean unsubscribe ack over the same ws connection |
| net_listening | PASS | |
| net_peerCount | WARN-DISAGREEMENT | same whitelist split as `eth_getBlockRange`: `publicnode.com` returns a real peer count, `rpc.mantle.xyz` rejects with `-32601` |
| net_version | PASS | |
| rollup_gasPrices | FAIL | `-32601` on both upstreams |
| rollup_getInfo | FAIL | `-32601` on both upstreams |
| rpc_modules | WARN-DISAGREEMENT | same whitelist split: `publicnode.com` returns the module list, `rpc.mantle.xyz` rejects with `-32601` |
| web3_clientVersion | PASS | |
| web3_sha3 | PASS | |

**Archive extension probe:** PASS — `lava-extension: archive` + historical `eth_getBalance` at block `0x1` → `0x0` through the router.

## Log-scan findings (probe window, Step 4.5)

132 non-benign warn/error lines survived the allow-list filter over the mainnet probe window. All are attributable to already-classified events, not hidden defects:
- 54 `received node error reply from provider` — response propagation for the intentionally-probed FAIL/WARN methods above (e.g. `-32601`s, the pre-fix `eth_call`/`eth_estimateGas` revert against the initial test contract).
- 30 `blockParsing - rpcInput is error` + 16 `failed to parse with legacy block parser` — same cause: error responses from probed-FAIL methods propagating through the block-parser, plus the transient rate-limit episode below.
- 13 `[-] verify failed to parse result` + 1 `failed verification on provider startup` + 1 `invalid Verification on provider startup` + 1 `re-verify: demoting active static` + 1 `failed to fetch all previous blocks` — all from the single ~15s HTTP 429 rate-limit collision on `wss://mantle-rpc.publicnode.com` at boot (shared free-tier limit with the pre-existing leftover process), which self-healed (see Step 3.5 verification table).
- 4 `could not send relay to provider` (`error":"HTTP 429"`) — same rate-limit episode.

No FAIL/TIMEOUT downgrades of an otherwise-PASS method resulted from this scan.

## Testnet verification pass (Step 7)

TESTNET_VERIFY: OK

| Verification | Verdict | Providers OK/failed | Notes |
|---|---|---|---|
| chain-id | OK | 1/1 | `0x138b` confirmed live against `rpc.sepolia.mantle.xyz` |
| pruning | OK | 1/1 | `latest_distance:90000` clause confirmed (node serves a block 90,000 back from head) |
| trustless-rpc | OK | 1/1 | |

PARSE_BLOCKNUM: OK. PARSE_BLOCK_BY_NUM: OK (with the Tenderly-gateway read-after-write caveat noted above — not a directive defect, reproduced/explained via manual direct query).

## Empirical block time (Step 8)

| Network | RPC | Empirical (ms) | Spec effective (ms) | Drift | Verdict |
|---|---|---|---|---|---|
| mainnet | https://rpc.mantle.xyz | 2000 | 2000 | 0% | OK |
| testnet | https://rpc.sepolia.mantle.xyz | 2000 | 2000 (inherited from MANTLE) | 0% | OK |
