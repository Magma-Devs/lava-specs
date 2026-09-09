# Method Probe Report — icp

Generated: 2026-09-08T14:13:44Z
Router image: ghcr.io/magma-devs/smart-router:main (sha256:80eb3b0b3d7fbae541e8b1a1f5575625c220060a669f1abf33bb639dd3f881f6, binary v1.4.0-25-g00fd115)
Router config: /tmp/sr_icp.yml
Spec variant: ICP (rest)
Upstreams probed: https://rosetta-api.internetcomputer.org (the only public upstream for this chain — one `direct-rpc` block, no URL 2/3)

**Host-port note:** this host already runs an unrelated long-lived `smart-router-dashboard-router-1` container publishing `3360-3367`/`7779`, so `sr_icp` was published on host ports **13402→3360** and **17782→7779** instead of the usual `3360`/`7779`. Container-internal ports and the router config are unchanged from the standard shape; all `curl` commands below target `localhost:13402`/`localhost:17782`.

**Interface note:** both `api_collections` in `icp.json` are `api-interface: "rest"`, differing only in `collection_data.type` (`POST` vs `GET`) — one listener on port 3360 covers both, per the task's Override 1. `rest` here means POST-with-JSON-body (the Rosetta convention, same as `tron.json`), not GET-with-path; the sole `GET` collection is `/status`.

## Parse-directive & verification runtime check (Step 3.5)

| Check | Verdict | Evidence |
|---|---|---|
| GET_BLOCKNUM (router latest_block) | OK | `smartrouter_latest_block=3.8267907e+07`; `rpc_endpoint_fetch_latest_success{endpoint_id="icp-upstream-1"}=9`, no `fetch_latest_fails` observed |
| GET_BLOCK_BY_NUM (log hash-reads ∥ fetch_block counters) | NOT_EXERCISED | 0 `Chain Tracker Updated block hashes` / `read a block Hash` lines; `fetch_block_*` metric absent (expected — dead in this router build). Boot log: `"enabled":"false","reason":"off-operator-choice","message":"block-hash polling (fork detection) resolved"` — a router-level default in this build (v1.4.0-25-g00fd115), not attributable to `icp.json`. **Independently hand-verified** (Phase-6-grade, not runtime-grade): the exact GET_BLOCK_BY_NUM `function_template`/`result_parsing` pathway (`POST /block {block_identifier:{index:N}}` → `.block.block_identifier.hash`) was executed manually against the upstream for index 38267873 and returned a populated hash (`88d15afe6b37c37dddf68815eaa92ea0fc579bd8cebb2d0551e57a3cde0f359d`) and for index 0 (genesis, `ffca0ecf5e837541c7ee5be431e433ad8e972a7f371e86fbe4f8ad646c7cbcea`). This corroborates the directive shape is correct but is not a substitute for the tracker actually running it. |
| Parse-signature log lines | none | Clean — no `PARSE_SIG` matches anywhere in the boot or probe window |

| Verification | Verdict | Providers OK/failed | Notes |
|---|---|---|---|
| chain-id | OK | 1/1 | `rawData:"00000000000000020101"` == `expected_value`, `parser_arg:["0","network_identifiers","0","network"]` walked correctly by the router's Go rest parser (the nested-array shape flagged as a boot-fail risk in the task brief — same shape as `stacks.json` — parsed with no issue) |
| pruning | OK | 2/2 (both verification keys: base `{Extension:,Addon:}` and `{Extension:archive,Addon:}`) | Base key: `latest_distance:29509` clause satisfied (earliest block 0, far more retention than required). Archive key: `rawData:"0"` == `expected_value:"0"` — the upstream serves the true genesis (2021-05-06 MINT block) |

PARSE: OK (GET_BLOCK_BY_NUM NOT_EXERCISED by the tracker for the reason above; directive shape independently confirmed). VERIFY: OK, 0 failures/exclusions.

## Addon & extension coverage (Step 1c + probes)

Addons: none declared (`collection_data.add_on` is `""` on both collections). Extensions: `archive` (only).

| Name | Type | Upstreams supporting | Standalone | Boot verification | Router probe | Classification |
|---|---|---|---|---|---|---|
| archive | extension | upstream-1 (only upstream given) | — (1c-ii-b base-collection probe: `POST /network/status` answers normally on this upstream → ordinary extending add-on, not disjoint; `standalone-addons` correctly omitted) | OK (`pruning` verification, `Extension:archive` key, `rawData:"0"`==`expected_value:"0"`) | PASS (`POST /block {index:0}` through the router with `lava-extension: archive` returned the real genesis block, hash `ffca0ecf…`, timestamp `1620328630192` = 2021-05-06; same call without the header also passed, as expected for a non-disjoint extension on a single upstream) | TESTED_OK |

## Method probe (Step 4) — 19 APIs (18 POST + 1 GET), through the router at localhost:13402

Live inputs resolved before probing (archive node, so historical values stay valid): tip block index 38267878 (later re-confirmed at 38267930/38267961 as the chain advanced), block index 38267873 / hash `88d15afe6b37c37dddf68815eaa92ea0fc579bd8cebb2d0551e57a3cde0f359d`, tx hash `588d6247a1085e53fc4f39d18f9d65cfd8133f7ec6bff7d81af9480924c86922` (from that block), account address `40bcc4c247057843de07c7fce34e603a44461bf8e25fe12f7697175595a9cdb9` (a real operations-side address from that same block).

| Method | Classification | Upstream notes | Notes |
|---|---|---|---|
| /network/list | PASS | HTTP 200 | Returns `{"network_identifiers":[{"blockchain":"Internet Computer","network":"00000000000000020101"}]}` |
| /network/status | PASS | HTTP 200 | Valid `current_block_identifier`/`genesis_block_identifier`/`sync_status` |
| /network/options | PASS | HTTP 200 | Valid; also yields the full Rosetta error-code table (700–770) used to interpret the 500-wrapped rows below |
| /block | PASS | HTTP 200 | Valid block at requested index |
| /block/transaction | PASS | HTTP 200 | Returned exactly the requested tx hash with matching operations |
| /account/balance | PASS | HTTP 200 | `balances:[{"value":"0",...}]` — valid shape (account had a 0 balance at query time, which is a legitimate answer) |
| /mempool | PASS | HTTP 200 | `{"transaction_identifiers":[]}` — empty is a valid response |
| /mempool/transaction | PASS-existence | Through-router: HTTP 500 generic router wrapper (`"failed relay, insufficient results"`). Direct-upstream (same body): HTTP 500, Rosetta `{"code":720,"message":"Transaction not in the mempool"}` | Route is live and correctly processed — see "Log-scan findings" for the router-swallow mechanism. Re-probed once through the router (determinism check): identical result, confirmed not an input-freshness artifact |
| /search/transactions | PASS | HTTP 200 | `limit:10` used per Override 2 — returned 10 transactions, no timeout/oversized body |
| /call | FAIL | HTTP 404, empty body | **Expected non-defect** — gateway filtering, not absence. Both `/call` and `/status` exist in the reference binary (`rs/rosetta-api/icp/src/rosetta_server.rs` `#[post("/call")]`/`#[get("/status")]`, wired at `.service(call)`/`.service(status)`) but `rosetta-api.internetcomputer.org` is a Cloudflare gateway that forwards only textbook Rosetta paths and filters these two. Do not act on this per the Phase 10 disable-filter rule |
| /construction/derive | PASS | HTTP 200 | Accepted a 35-byte placeholder `hex_bytes` under `curve_type:edwards25519` and returned a derived `account_identifier` |
| /construction/preprocess | PASS-existence | Through-router: HTTP 500 generic wrapper. Direct-upstream: HTTP 500, Rosetta `{"code":730,"message":"An invalid transaction has been detected","details":{"error_message":"Operations don't contain any actions."}}` | Same router-swallow mechanism as `/mempool/transaction` |
| /construction/metadata | PASS | HTTP 200 | `{"metadata":{},"suggested_fee":[{"value":"10000",...}]}` |
| /construction/payloads | PASS-existence | Through-router: HTTP 500 generic wrapper. Direct-upstream: HTTP 500, Rosetta `{"code":700,"message":"Internal server error","details":{"error_message":"Expected field 'public_keys' to be populated"}}` | Same router-swallow mechanism |
| /construction/parse | PASS-existence | Through-router: HTTP 500 generic wrapper. Direct-upstream: HTTP 500, Rosetta `{"code":701,"message":"Invalid request","details":{"error_message":"Could not decode unsigned transaction: unassigned type at offset 1"}}` | Same router-swallow mechanism |
| /construction/combine | PASS-existence | Through-router: HTTP 500 generic wrapper. Direct-upstream: HTTP 500, Rosetta `{"code":701,"message":"Invalid request","details":{"error_message":"Could not deserialize unsigned transaction: unassigned type at offset 1"}}` | Same router-swallow mechanism |
| /construction/hash | PASS-existence | Through-router: HTTP 500 generic wrapper. Direct-upstream: HTTP 500, Rosetta `{"code":701,"message":"Invalid request","details":{"error_message":"Cannot deserialize the hash request in CBOR format because of: unassigned type at offset 1"}}` | Same router-swallow mechanism |
| /construction/submit | SKIP | — | `category.stateful: 1` — would broadcast a transaction |
| /status | FAIL | HTTP 404, empty body | **Expected non-defect** — same gateway filtering as `/call` (see that row's evidence) |

Counts: **PASS=16** (10 clean HTTP 200 + 6 PASS-existence), **FAIL=2** (`/call`, `/status` — both documented gateway-filtering non-defects, not spec defects), **SKIP=1** (`/construction/submit`), **UNPROBED=0**, **WARN=0**, **TIMEOUT=0**, **LOG_WARN=49** (all 49 attributable to the 6-method router-swallow cascade below, not new findings). All 19 APIs probed; no rate limiting encountered (unpaced mode used throughout).

## Log-scan findings (probe window)

Non-benign warn/error/fatal/panic lines during the probe window (Step 4.5): 49 lines, all attributable to exactly 6 request/response cycles (`/mempool/transaction` ×2 — one deliberate determinism re-probe, `/construction/preprocess`, `/construction/payloads`, `/construction/parse`, `/construction/combine`, `/construction/hash`). No `fatal`/`panic` anywhere in the probe window; the router was stable throughout.

**Finding — single-upstream relay swallows valid Rosetta application-error bodies.** For every one of the 6 paths above, the upstream answers with a legitimate, well-formed Rosetta error (a `code`/`message`/`details` JSON object, e.g. `720`/`730`/`700`/`701` — confirmed by probing the identical body directly against `rosetta-api.internetcomputer.org`), but Rosetta's convention is to carry these at **HTTP 500**. The smart-router's relay layer classifies any non-2xx upstream response as a hard transport failure (`error_name:"NODE_INTERNAL_ERROR"`, `error_category:"external"`) rather than a relayable application response, triggers `"Circuit breaker triggered: All providers exhausted, stopping retries"` (immediate, since there is exactly one provider), and returns a generic `{"error":"...failed relay, insufficient results..."}` wrapper to the client — discarding the upstream's real, informative body. This reproduced deterministically on every trial (confirmed via a same-input re-probe on `/mempool/transaction`). **This is not an `icp.json` defect** — the API paths, request bodies, and directive shapes are all correct, and the upstream Rosetta implementation behaves exactly per spec; it is a smart-router relay-layer policy (any non-2xx = provider failure) colliding with a chain family (Rosetta) whose spec routinely encodes legitimate, structured application errors via non-2xx HTTP status. It is being surfaced here as a router-behavior finding, distinct from the `/call`/`/status` gateway-filtering finding, worth the orchestrator's attention for Phase 9/10 triage even though no spec edit is indicated. **Scoping caveat:** this was observed with exactly one configured provider (per the task's single-upstream constraint); whether a ≥2-provider deployment would relay the real body through (fail over and eventually surface it) or just fail over and still discard it on every attempt was not tested here.

Representative log excerpt (one cycle, `/mempool/transaction`):
```
{"level":"error","error":"HTTP 500","error_code":"2003","error_name":"NODE_INTERNAL_ERROR","error_category":"external","retryable":"true","provider":"icp-upstream-1","message":"could not send relay to provider"}
{"level":"warn","message":"Circuit breaker triggered: All providers exhausted, stopping retries"}
{"level":"error","error":"HTTP 500","message":"failed relay, insufficient results"}
{"level":"error","...","message":"failed processing responses from RPC endpoints"}
{"level":"error","request":"{...transaction_identifier hash 588d6247...}","response":"{\"Error_GUID\":...}","method":"POST","path":"/mempool/transaction","HasError":"true","message":"http in/out"}
```

| Level | Associated method | error excerpt |
|---|---|---|
| ERR | /mempool/transaction | `NODE_INTERNAL_ERROR` → `failed relay, insufficient results` (upstream real body: Rosetta 720, swallowed) |
| ERR | /construction/preprocess | same cascade (upstream real body: Rosetta 730, swallowed) |
| ERR | /construction/payloads | same cascade (upstream real body: Rosetta 700, swallowed) |
| ERR | /construction/parse | same cascade (upstream real body: Rosetta 701, swallowed) |
| ERR | /construction/combine | same cascade (upstream real body: Rosetta 701, swallowed) |
| ERR | /construction/hash | same cascade (upstream real body: Rosetta 701, swallowed) |
| WRN | (all 6 above) | `Circuit breaker triggered: All providers exhausted, stopping retries` — expected with exactly 1 configured provider |

No other non-benign lines. All other 13 methods produced clean logs (no warn/error/fatal/panic).

## Testnet verification pass (Step 7)

TESTNET_VERIFY: SKIPPED (mainnet-only spec — the IC has no public testnet)

## Empirical block time (Step 8)

Recipe: ICP Rosetta `/block` timestamps (milliseconds) over the direct upstream, per the task's Override 3 recipe. Sampled three window sizes for stability (tip at time of measurement: 38267961).

| Network | RPC | Window (blocks) | Empirical (ms) | Spec effective (ms) | Drift | Verdict |
|---|---|---|---|---|---|---|
| mainnet | https://rosetta-api.internetcomputer.org | 1,000 | 4848 | 4500 | +7.7% | OK |
| mainnet | https://rosetta-api.internetcomputer.org | 5,000 | 4416 | 4500 | −1.9% | OK |
| mainnet | https://rosetta-api.internetcomputer.org | 10,000 | 4274 | 4500 | −5.0% | OK |
| testnet | — | — | skipped | — (no testnet) | — | skipped (no public testnet) |

All samples within the ±20% mismatch threshold; no `BLOCK_TIME_MISMATCH`. Per the task brief, ICP's ledger is transaction-paced (finalizes on demand, not on a fixed clock), so meaningful window-to-window drift (measured here: 4274–4848ms; task brief notes a wider historical range of 2873–6957ms) is **informational, not a defect** — no change to `average_block_time: 4500` is recommended.
