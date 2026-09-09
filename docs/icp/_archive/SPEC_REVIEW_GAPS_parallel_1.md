# ICP Spec Review — Gap Report

**Spec file:** `icp.json` (435 lines) · **Branch:** `icp-spec` · **Reviewer:** parallel_1
**Chain:** Internet Computer (ICP) Rosetta API — Rosetta v1.4.10, plain JSON over HTTP POST, served at root path (no `/rosetta/v1` prefix)
**Scope:** `--api-docs=` (none) `--credentials=` (none). Reviewed against `docs/icp/METHOD_PROBE_REPORT.md` (live router + direct-upstream probe, generated 2026-09-08T14:13:44Z) and the upstream reference implementation source (`dfinity/ic`, `rs/rosetta-api/icp/src/*`, fetched live via `gh api` during this review).

## Result summary

| Severity | Count |
|---|---|
| CRITICAL | 0 |
| MEDIUM | 1 |
| MINOR | 0 |

Spec is ready for deployment. The one MEDIUM finding is a compute-unit pricing question that was deliberately left open for independent adjudication — it does not block correctness, boot, parsing, or verification.

## Phase 0 — Removed-field / envelope guard

```
$ bash .claude/skills/create-spec/scripts/check_unused_fields.sh icp.json
RESULT: PASS (no removed fields)

$ bash .claude/skills/create-spec/scripts/check_internal_paths.sh icp.json
RESULT: PASS (0 warning(s), no errors)
```

Envelope is exactly `{ "proposal": { "specs": [ … ] } }` (icp.json:1-4, 431-435) — no `title`/`description`/`deposit`, no removed governance fields. This is the correct current shape, not a gap.

## Phase 1 — Provider identification

- `api_interface: "rest"` on both collections (icp.json:17, 404); collection 1 is `POST`/18 APIs (icp.json:19,22-301), collection 2 is `GET`/1 API (`/status`, icp.json:406,409-424). Both `add_on: ""`.
- `imports: []` (icp.json:8) — no parent spec; every field must be self-defined. Confirmed complete (Phase 7 below).
- 1 spec entry (`ICP`, icp.json:5) — mainnet-only. Correct: the IC has no public testnet; 26 specs on this branch (including icp.json) are now single-entry, precedent-consistent.

## Phase 2 — Network parameters

| Param | Value | Verdict |
|---|---|---|
| `average_block_time` | 4500 (icp.json:9) | OK — probe Step 8 measured 4274-4848ms across 1k/5k/10k-block windows, all within +/-20% |
| `block_distance_for_finalized_data` | 1 (icp.json:11) | OK — IC has deterministic BLS-threshold (instant) finality |
| `blocks_in_finalization_proof` | 1 (icp.json:12) | OK — fast/instant-finality typed, per guide's explicit carve-out |
| `allowed_block_lag_for_qos_sync` | 20 (icp.json:10) | Deliberate evidence-backed override — see "Checked, not findings" below |

`check_network_params.sh` output:
```
=== PASS ===
blocks_in_finalization_proof|ICP|1
average_block_time|ICP|4500
block_distance_for_finalized_data|ICP|1

=== FAIL ===
allowed_block_lag_for_qos_sync|ICP|expected=3 declared=20
```
The FAIL is expected and already adjudicated (see below) — not counted as a finding.

## Phase 3 — API completeness

No `--api-docs=` was supplied. Rather than stop at "cannot verify," this review pulled the reference server's route table directly (`gh api repos/dfinity/ic/contents/rs/rosetta-api/icp/src/rosetta_server.rs`, `master` branch, fetched live during this review) and diffed it against `icp.json`'s API list.

Reference binary registers exactly 19 `.service(...)` routes: `account_balance, block, call, block_transaction, construction_combine, construction_derive, construction_hash, construction_metadata, construction_parse, construction_payloads, construction_preprocess, construction_submit, mempool, mempool_transaction, network_list, network_options, network_status, search_transactions, status`.

icp.json defines exactly these 19 (18 POST + 1 GET, icp.json:22-301,409-424) — **19/19 exact match, no missing routes, no phantom routes.** This upgrades Phase 3 from "unverifiable" to a positive completeness confirmation. (`/account/coins` is correctly absent — ICP's ledger is account-based, not UTXO, so Rosetta's optional UTXO-only endpoint doesn't apply.)

## Phase 4 — Method-by-method review

Block parsing, category flags, and CU were checked for all 19 APIs against the guide's rules and, where the guide's rule was ambiguous, against the reference implementation source. Only one finding resulted.

### Finding MEDIUM-1 — `/call` (icp.json:164-178) is priced for its cheapest branch, not its worst one

**Severity:** MEDIUM

**Evidence:**
- icp.json:172 sets `"compute_units": 10` for `/call`, the same tier as simple no-block-param reads (icp.json:31,46,61 etc.).
- The reference implementation (`rs/rosetta-api/icp/src/request_handler.rs:200-284`, `call()`) dispatches on a request-body `method_name` field to five fixed operations:
  - `get_proposal_info`, `get_pending_proposals`, `get_minimum_dissolve_delay`, `list_known_neurons` — each a single cheap NNS lookup, genuinely worth the 10-CU tier.
  - `query_block_range` (request_handler.rs:241-284) — reads a **bulk, capped range of historical blocks** from local storage (`self.ledger.read_blocks()` -> `get_hashed_block_range(...)`, line 264) and converts+serializes every block in range into the response. The cap is `MAX_BLOCKS_PER_QUERY_BLOCK_RANGE_REQUEST = 10000` (`rs/rosetta-api/icp/src/lib.rs:15`) — i.e. a single `/call` request can legitimately return up to 10,000 full blocks.
- Lava's `compute_units` is set per API **name**, not per request-body dispatch branch — there is no spec-level mechanism to price `query_block_range` differently from the other four `method_name` values that share the same `/call` endpoint. The price must therefore cover the worst reachable branch, not the modal one.

**Why not the Phase 6 gate's proposed 40-60 "simulate" band:** that band's reasoning (contract-execution/simulation cost, triggered by the substring "call") doesn't apply here — none of the five dispatch branches execute arbitrary code; `/call` is not `eth_call`. The actual cost driver is a capped bulk historical-range read, a different shape (and a better-fitting comparison set) than a simulate/execute call.

**Comparison set (capped/bulk range reads):**
- `eth_getLogs` (ETH1) = 80 CU — the guide's own reference example for range-scan-shaped queries.
- `/search/transactions`, **in this same spec** (icp.json:157, `compute_units: 80`) — the spec's own author already priced a bulk/searchable read at 80, one tier above simple reads.
- Rejected the higher "Heavy ops / full scan" tier (500-5000 CU, e.g. `txpool_content`/`gettxoutsetinfo`): `query_block_range`'s reads are server-local (no external RPC fan-out) and hard-capped at 10,000 blocks by the binary itself, not an open-ended full-chain scan — that tier is for uncapped/full-dataset operations, which this isn't.

**Recommendation:** raise `/call`'s `compute_units` from 10 to **80**, matching both the in-spec `/search/transactions` precedent and the cross-spec `eth_getLogs` precedent for capped bulk-range reads multiplexed behind one endpoint.

**Impact if unfixed:** every provider serving ICP is economically exposed — a consumer can request the maximum 10,000-block range on every `/call` at 1/8th the CU cost the spec itself already assigns to comparable bulk reads, underpricing providers for the heaviest legitimate use of this endpoint.

*(This finding was flagged for independent adjudication in the review task rather than auto-applied — no edit was made to icp.json; this is a recommendation only.)*

## Phase 5 — Parse directives

| Directive | api_name | Verdict |
|---|---|---|
| GET_BLOCKNUM (icp.json:311-323) | /network/status | OK — probe: router `latest_block` populated, 9 successful fetches, 0 fails |
| GET_BLOCK_BY_NUM (icp.json:324-337) | /block | OK — router tracker did not exercise it in this run (router-level "block-hash polling" default is off in this build, not attributable to icp.json), but the directive's exact shape was hand-verified against the upstream for index 38267873 and index 0 (genesis), both returning correct populated hashes |
| GET_EARLIEST_BLOCK (icp.json:338-350) | /network/status | OK — required by the archive extension (icp.json:391-399), present, probe confirms pruning verification 2/2 |
| SUBSCRIBE/UNSUBSCRIBE | — | N/A — Rosetta REST has no WebSocket subscription model; correctly absent |

## Phase 6 — Verifications (icp.json:352-390)

| Verification | Verdict |
|---|---|
| chain-id (icp.json:353-374), expected `00000000000000020101` | OK — probe: live `rawData` match 1/1. Nested-array `parser_arg` path (`["0","network_identifiers","0","network"]`) walked correctly by the router's Go rest parser |
| pruning (icp.json:375-389) | OK — required (archive extension present), references GET_EARLIEST_BLOCK, shape matches the guide's template exactly (latest_distance-only base clause + `extension:"archive"` clause). Probe: live 2/2 (base `latest_distance:29509` satisfied; archive `expected_value:"0"` matched against true genesis) |

No independent research source for ICP's non-archival retention depth was available to cross-check the `29509`/`29509` figures (icp.json:382,396) against an external number; flagging this as a documented limitation, not a finding — the probe's live corroboration (node satisfies the clause with room to spare) is the only available check and it passes.

## Phase 7 — Collection inheritance

N/A — `imports: []` (icp.json:8). Both collections are fully self-defined; no parent-merge behavior to audit.

## Phase 8 — Headers

- POST collection: single `content-type: application/json` `pass_override` (icp.json:302-308) applied blanket across all 18 POST endpoints. Correct — unlike the guide's Cardano/CBOR mixed-content-type example, every Rosetta endpoint on this chain uses JSON uniformly; no endpoint needs a different content-type, so the "mixed content-type" anti-pattern doesn't apply here.
- GET collection: `headers: []` (icp.json:426) — correct; the reference `/status` handler takes no request body (`async fn status(req_handler: ...)`, no `web::Json<...>` parameter), so no content-type override is needed.
- No `pass_send` auth header on either collection — correct; ICP Rosetta is a self-hosted binary, not a third-party API-key-gated provider (unlike Blockfrost/Cardano).
- No `pass_reply`/`pass_both` — correct; block-height data travels in the JSON body (parsed via parse directives), not response headers.

## Phase 9 — Live testing

No `--credentials=` was supplied. In place of fresh credentialed testing, this review relies on `docs/icp/METHOD_PROBE_REPORT.md` (generated same-day, 2026-09-08T14:13:44Z), which already performed router + direct-upstream live testing: GET_BLOCKNUM verified live, GET_BLOCK_BY_NUM hand-verified live, chain-id verified live 1/1, pruning verified live 2/2, and all 19 APIs individually probed (16 clean PASS, 2 gateway-filtered non-defects, 1 correctly SKIPped stateful API). See "Checked — not findings" below for how each probe-report item was handled.

---

## Checked — not findings

Reviewed and confirmed correct/expected as-is. Listed explicitly so a consolidator doesn't re-flag these from a probe-report or gate re-run:

- **`allowed_block_lag_for_qos_sync = 20`** (icp.json:10) — deliberate override of the `max(ceil(10000/average_block_time),1)=3` formula. `check_network_params.sh` reports `expected=3 declared=20` as FAIL — expected, already adjudicated. ICP ledger blocks are transaction-paced, not clock-paced (median gap 2126ms, max observed 50,459ms over 124 samples, 2.4% of gaps >30s); lag=3 (13.5s window) would false-flag a healthy provider on that one observed gap alone. Repo precedent: `movement.json` uses 50 at `average_block_time`=10000 against 1-2 bracket neighbours; 11 other spec entries already use exactly 20 (`arbitrum.json`x3, `base.json`, `cronos.json`x2, `eos.json`x2, `flow.json`, `tempo.json`x2 — confirmed by direct count).
- **`blocks_in_finalization_proof = 1`** (icp.json:12) — fast/instant-finality typed (BLS threshold, no-reorg guarantee), not the probabilistic-finality `3`. Correct per guide's explicit carve-out.
- **Absence of `title`/`description`/`deposit`/9 governance fields** — correct current model shape; guard exits 0 (Phase 0 above).
- **`/call` and `/status` returning HTTP 404 in the probe report** — gateway filtering (`rosetta-api.internetcomputer.org` is a Cloudflare gateway forwarding only textbook Rosetta paths), not absence. Independently reconfirmed in this review: both routes are registered in the reference binary (`rosetta_server.rs`, `.service(call)` / `.service(status)`, confirmed via direct source fetch during this review). No disable/removal action taken.
- **`LOG_WARN=49` in the probe report** — traced to the router's single-provider relay treating Rosetta's HTTP-5xx-with-structured-body error convention as a hard transport failure and discarding the body, on 6 request/response cycles. Router relay-policy issue, not an icp.json defect — no spec action indicated, kept out of this report's tally.
- **`/status` uses `parser_func: EMPTY`** (icp.json:416) — checked against a real counter-precedent (`near.json`'s and `tendermint.json`'s `status` methods both use `DEFAULT`, both `deterministic:false`) and against the actual reference handler rather than assumed consistent with that precedent: ICP's `GET /status` (`rosetta_server.rs`, fn `status`) returns only `RosettaStatus { rosetta_blocks_mode }` — a static per-instance feature flag set at server startup, not chain-tip/sync data the way NEAR's and Tendermint's `status` are. The near.json/tendermint.json precedent doesn't transfer here because those methods' payloads are materially different (they report live sync height). `EMPTY` is correct.
- **`/network/options` uses `deterministic: false`** (icp.json:64) — confirmed correct by precedent: `web3_clientVersion` in `ethereum.json` (`deterministic:false`) vs. `eth_chainId`/`net_version`/`eth_protocolVersion` (`deterministic:true`) — the split is protocol-constant (true) vs. software/build-version-dependent (false). `/network/options`' response includes `node_version`, which varies by which Rosetta binary build each provider runs, so it can legitimately differ across correctly-configured providers. Matches `false` here, and matches `tendermint.json`'s `status`/`abci_info` (both `false`) for the same "node self-report" shape.
- **Construction API offline/online split** (icp.json:179-300) — verified against source, not just the guide's convention: `construction_derive` and `construction_preprocess` are non-`async fn` in the reference (`request_handler/construction_derive.rs`, `construction_preprocess.rs`), touching only static config getters (`ledger_canister_id()`, `token_symbol()`, `governance_canister_id()`) — correctly `EMPTY`/`deterministic:true`. `construction_metadata` is `async fn` and awaits `self.ledger.transfer_fee()` — a live ledger call — correctly `DEFAULT`/`deterministic:false`. `payloads`/`parse`/`combine`/`hash` are pure functions — correctly `EMPTY`/`deterministic:true`.
- **19/19 route match** against the reference binary's registered `.service(...)` handlers (Phase 3 above) — no missing or phantom endpoints.
- **No duplicate API names, valid JSON, all APIs `enabled:true`, `timeout_ms` present only on the one stateful/hanging API (`/construction/submit`)** — verified directly (`jq`).

---

## Conclusion

- **Endpoints reviewed:** 19/19 (18 POST + 1 GET)
- **CRITICAL:** 0
- **MEDIUM:** 1 (`/call` compute_units — recommend 10 -> 80; not auto-applied per task instructions)
- **MINOR:** 0
- **Deployment readiness:** Ready. The one MEDIUM finding is a pricing-fairness recommendation, not a functional, parsing, or verification defect — nothing here blocks router boot, data reliability, or chain-id verification.
