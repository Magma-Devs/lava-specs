# ICP Spec Review — Gap Report (final pass)

**Spec under review:** `icp.json` (435 lines, untracked)
**API docs path:** none supplied — see Phase 3 for how completeness was anchored instead
**Credentials path:** none supplied — see Phase 9 for the substitute evidence base
**Reference material read in full:** `.claude/skills/review-spec/SPEC_GUIDE.md` (2163 lines, `END-OF-GUIDE-SENTINEL` observed at line 2161), `docs/icp/METHOD_PROBE_REPORT.md`, `docs/icp/FIX_LIST.md`, the three archived Phase-9 reviews under `docs/icp/_archive/`.

**Scope note.** This is the post-fix adversarial pass. The seven settled decisions (canonical envelope; `blocks_in_finalization_proof: 1`; probe errors never justify disabling; the frozen `allowed_block_lag_for_qos_sync: 20`; `/call` + `/status` gateway filtering; the `LOG_WARN=49` router-relay cascade; `/account/balance` `block_parsing`) are treated as adjudicated and are not re-litigated. The four MINORs dropped in `FIX_LIST.md` were reviewed and are deliberately not re-raised. Only `icp.json` was reviewed; nothing in it was modified.

## Result summary

| Severity | Count |
|---|---|
| CRITICAL | 0 |
| MEDIUM | 1 |
| MINOR | 2 |

All three findings are new — none appears in `SPEC_REVIEW_GAPS_parallel_1/2/3.md` or `FIX_LIST.md`. All three were found by reading the reference implementation's source rather than by re-running gates, which is why they survived Phases 6–10: **no automated gate in this repo can detect this class of defect** (see MEDIUM-1, "Why every gate missed it").

---

## Phase 0 — Removed-field guard

```
$ bash .claude/skills/create-spec/scripts/check_unused_fields.sh icp.json
RESULT: PASS (no removed fields)                                    exit=0

$ bash .claude/skills/create-spec/scripts/check_internal_paths.sh icp.json
RESULT: PASS (0 warning(s), no errors)                              exit=0
```

**Cleanup findings: none.** No `REMOVED_FIELD` hits; no `NAME_CARRIES_PATH`, `LABEL_AS_PATH`, `AMBIGUOUS_REST_NAME` or `AMBIGUOUS_REST_SHAPE` warnings. Envelope is exactly `{ "proposal": { "specs": [ … ] } }` — no `title`, `description`, or `deposit`. Both collections carry `internal_path: ""`, so the internal-path guard has nothing to flag.

**Disabled-API ledger verified:**

```
$ jq '[.proposal.specs[] | .api_collections[] | select(.enabled==false)] | length' icp.json   → 0
$ jq '[.proposal.specs[] | .api_collections[] | .apis[] | select(.enabled==false)] | length' icp.json → 0
$ bash .claude/skills/create-spec/scripts/check_disabled_count.sh icp.json
=== DISABLED IN FILE (0 distinct method(s), 0 row(s)) ===  RESULT: PASS
```

Zero disabled collections and zero disabled APIs. No justification rows are required and none are missing. No CRITICAL finding on this axis.

---

## Phase 1 — Provider identification

Native reference implementation, self-hosted: the DFINITY **ICP Rosetta API** binary (`rs/rosetta-api/icp/`), Rosetta `API_VERSION = "1.4.10"` (confirmed at `rs/rosetta-api/icp/src/lib.rs`). Not a third-party aggregator, so the guide's Step 1.1a authentication (`pass_send`) and platform-endpoint-exclusion rules apply only weakly. `api_interface: "rest"` (POST-with-JSON-body, the Rosetta convention), `chain_family: other`, `imports: []`, one spec entry (mainnet-only — the IC has no public testnet). Two collections, both `add_on: ""`, differing only in `collection_data.type` (POST ×18 APIs, GET ×1).

---

## Phase 2 — Network parameters audit

```
$ bash .claude/skills/create-spec/scripts/check_network_params.sh icp.json
=== PASS ===
blocks_in_finalization_proof|ICP|1
average_block_time|ICP|4500
block_distance_for_finalized_data|ICP|1
=== FAIL ===
allowed_block_lag_for_qos_sync|ICP|expected=3 declared=20            exit=1
```

| Parameter | Value | Verdict |
|---|---|---|
| `average_block_time` | 4500 | OK — probe measured 4274/4416/4848 ms across 1k/5k/10k-block windows, all inside ±20% |
| `block_distance_for_finalized_data` | 1 | OK — deterministic BLS threshold finality |
| `blocks_in_finalization_proof` | 1 | OK — fast/instant finality, per settled decision (b) |
| `allowed_block_lag_for_qos_sync` | 20 | **Expected FAIL — adjudicated, frozen per settled decision (d).** Not a finding, not a re-raise. Recorded here only so the non-zero exit is not mistaken for an oversight. |

---

## Phase 3 — API completeness audit

No API-docs path was supplied, so the skill's Phase 3 diff could not be run as written. Rather than record this only as a limitation, completeness was anchored against a **stronger** source than documentation — the reference binary's actual route table, fetched and enumerated directly:

```
$ grep -nE '#\[(post|get)\("' rs/rosetta-api/icp/src/rosetta_server.rs
18 × #[post("…")]   +   1 × #[get("/status")]      (all 19 wired via .service(…) at lines 305–323)
```

The 19 registered routes match `icp.json`'s 19 APIs **exactly** — 0 missing, 0 extra. `/account/coins` and `/events/blocks` (standard Rosetta v1.4.x endpoints) are genuinely unregistered in this implementation and correctly excluded rather than included-and-disabled. This independently confirms R3's completeness conclusion from the primary source. `check_method_schema.sh` reports `schema ok` for all 19.

**No completeness gap.**

---

## Phase 4 — Method-by-method review

Block parsing, category flags and CU were checked for all 19 APIs. Findings: MINOR-1 below (`/call`). Everything else is correct or matches established repo convention — see "Checked — not findings" for the items that were actively investigated and cleared, including two that nearly became findings.

---

## Phase 5 — Parse directives audit

All three required directives are present and reference APIs that exist in the spec (`check_directive_presence.sh` → `OK`).

| Tag | api_name | Verdict |
|---|---|---|
| GET_BLOCKNUM | `/network/status` → `["0","current_block_identifier","index"]` | OK — router reached `smartrouter_latest_block=38267907` |
| GET_BLOCK_BY_NUM | `/block` → `["0","block","block_identifier","hash"]`, template uses `%d` | OK — decimal index is correct for ICP; hand-verified against the upstream |
| GET_EARLIEST_BLOCK | `/network/status` → `["0","genesis_block_identifier","index"]` | **Defective — see MEDIUM-1** |
| SUBSCRIBE / UNSUBSCRIBE | — | Correctly absent; ICP Rosetta registers no WebSocket route |

---

## Phase 6 — Verification audit

`chain-id` is correct (`expected_value: "00000000000000020101"`, probe-confirmed 1/1, the 4-deep nested-array walk parses cleanly). `pruning` is structurally correct per the guide's Step 3.5 template and passes every repo gate — and is nonetheless inert. See MEDIUM-1.

---

## Phase 7 — Collection inheritance audit

N/A — `imports: []`. Nothing to merge or override; the empty-array-inherits-everything trap cannot apply. Both collections are self-contained.

---

## Phase 8 — Headers audit

One header: `content-type: application/json`, `kind: pass_override`, on the POST collection only. Safe as a blanket override — all 18 POST endpoints take uniform JSON bodies, including `/construction/submit` (whose CBOR/hex payload is a *string inside* a JSON body). The guide's mixed-content-type failure mode does not apply. The GET collection correctly carries no headers. No `pass_send` auth header, correct for a self-hosted binary.

---

## Phase 9 — Live testing

No credentials path supplied. Substituted with `docs/icp/METHOD_PROBE_REPORT.md` (read in full) plus direct live probes and reference-source retrieval performed during this review:

- `POST /network/status` against `https://rosetta-api.internetcomputer.org` — live response captured (see MEDIUM-1 evidence).
- `rosetta_server.rs`, `request_handler.rs`, `main.rs`, `lib.rs`, `ledger_blocks_sync.rs`, `blocks.rs` fetched from `dfinity/ic@master` and read.

---

# Findings

## MEDIUM-1 — The `pruning` verification is structurally inert: `GET_EARLIEST_BLOCK` parses a network constant, not a node retention indicator

**Evidence (spec):** `icp.json:338-350` (the `GET_EARLIEST_BLOCK` directive), `icp.json:375-389` (the `pruning` verification), `icp.json:391-399` (the `archive` extension).

```json
// icp.json:338-350
{ "function_tag": "GET_EARLIEST_BLOCK",
  "api_name": "/network/status",
  "result_parsing": { "parser_arg": ["0","genesis_block_identifier","index"], "parser_func": "PARSE_CANONICAL" } }

// icp.json:375-389
{ "name": "pruning",
  "parse_directive": { "function_tag": "GET_EARLIEST_BLOCK" },
  "values": [ { "latest_distance": 29509 },
              { "extension": "archive", "expected_value": "0" } ] }
```

### The defect

`genesis_block_identifier` is a **network-level constant**, not a retention indicator. Per the Rosetta specification the retention-sensitive field is `oldest_block_identifier` ("the oldest block available… if not populated, the `genesis_block_identifier` is assumed to be the oldest known block"). The ICP implementation follows that contract exactly — `rs/rosetta-api/icp/src/request_handler.rs`, `network_status`, `RosettaBlocksMode::Disabled` branch:

```rust
// request_handler.rs:618-624
let genesis_block = blocks.get_hashed_block(&0)?;            // ← ALWAYS index 0
let first_verified_block = blocks.get_first_verified_hashed_block()?;
let oldest_block_id = if first_verified_block.index != 0 {   // ← retention-sensitive
    Some(convert::block_id(&first_verified_block)?)          //    populated ONLY when pruned
} else { None };
```

The spec reads the first of these two fields. It is hardcoded to block 0.

**Block 0 is never pruned — this is explicit in the store.** `rs/rosetta-api/icp/ledger_canister_blocks_synchronizer/src/blocks.rs`, `prune()`:

```rust
// blocks.rs:1078-1083
connection.execute(
    "DELETE FROM blocks WHERE block_idx > 0 AND block_idx < ?",   // ← block_idx > 0
    params![hb.index],
)
```

The `block_idx > 0` clause deliberately preserves genesis forever, which is precisely why `get_hashed_block(&0)?` can be called unconditionally on every `/network/status`. So `genesis_block_identifier.index` is `0` on **every ICP Rosetta node, pruned or not**. This is not an inference about prune internals — it is the DELETE statement.

The same holds in the other operating mode: in the `RosettaBlocksMode::Enabled` branch (`request_handler.rs:647-679`) `oldest_block_id` is passed as a literal `None` and genesis resolves to index 0 in both sub-branches.

Live confirmation on the reference upstream — note the complete absence of `oldest_block_identifier`, exactly as the code predicts for an unpruned node:

```json
{"current_block_identifier":{"index":38268334,…},
 "genesis_block_identifier":{"index":0,"hash":"ffca0ecf…"},
 "sync_status":{…},"peers":[]}
```

### Impact — both tiers of the verification are unenforced

`GET_EARLIEST_BLOCK` always returns `0`, therefore:

1. **Archive tier** — `{extension: "archive", expected_value: "0"}` string-compares `"0"` to `"0"`. **Every provider passes**, including one that has pruned away all deep history. Archive-tagged requests are then billed at `cu_multiplier: 5` against a node that cannot serve them.
2. **Base tier** — `{latest_distance: 29509}` compares `latest − 0` against 29509 with `latest ≈ 38.2M`. **Always true.** The guarantee that every ICP provider retains ~29,509 blocks is never actually checked.

The verification cannot return a negative result for any provider, in any configuration. It is a no-op that reads as a passing safety gate — the failure class `MAG-3353` ("make the archive pruning gate able to reject a pruned node") exists to prevent.

**Correction to a prior review — the assumed safety margin does not exist.** R3 (`SPEC_REVIEW_GAPS_parallel_3.md:159`) reasoned that `29509` is safe because "a pruned ICP Rosetta node prunes only in `PRUNE_DELAY = 100_000`-block batches, so any operator who enables pruning at all still retains at least on the order of 100,000 blocks… roughly a 3.4x safety margin." `PRUNE_DELAY` is batching hysteresis, not a retention floor — the source comment says so directly:

```rust
// ledger_blocks_sync.rs:23-25
// If pruning is enabled, instead of pruning after each new block
// we'll wait for PRUNE_DELAY blocks to accumulate and prune them in one go
const PRUNE_DELAY: u64 = 100000;

// blocks.rs:1365-1385 — try_prune
if first_idx + block_limit + prune_delay < last_idx {
    let new_first_idx = last_idx - block_limit;   // retention == block_limit
```

Steady-state retention equals `block_limit` — i.e. whatever the operator passes to `--store-max-blocks` (`main.rs:60-61`, `max_blocks: Option<u64>`), oscillating up to `block_limit + 100_000` between prunes. It is unbounded below. An operator running `--store-max-blocks 5000` retains 5,000 blocks, passes both clauses of the verification, and cannot serve the base tier's own 29,509-block window — let alone archive. The 3.4x margin should not be carried forward.

### Why every gate missed it

This defect is invisible to the entire existing toolchain, which is the substantive reason it survived Phases 6–10 and three parallel reviewers:

- `check_archive_value.sh` → PASS. It string-matches `expected_value` against the declared shape; it never asks whether the parsed field *can* vary.
- `check_verifications.sh` → PASS. Confirms `pruning` references a `GET_EARLIEST_BLOCK` that exists in the collection — structure, not semantics.
- `check_pruning.sh` takes the retention figure as a **caller-supplied argument**; passing it `29509` self-validates.
- `check_extensions.sh` → PASS (`cu_multiplier=5`, `rule.block=29509`).
- Phase 8 boot verification reported `pruning OK 2/2` — but the only upstream is fully unpruned, so the probe proved the gate **accepts** a good node. Nothing tested that it **rejects** a bad one, and by construction it cannot.

**ICP is the only spec in the repo whose `GET_EARLIEST_BLOCK` parses a network constant.** Surveyed across all specs declaring the directive, every other one reads a genuine node-retention indicator — `eth_getBlockByNumber("earliest") → ["0","number"]` (ETH1 and ~25 EVM specs), `sync_info.earliest_block_height` (AKASH), `available_block_range.low` (CASPER, the closest structural analogue), `["0","height"]` (CARDANO), `["0","block","rnd"]` (ALGORAND).

### Recommended direction — needs router-side validation, do not apply blind

The obvious swap to `["0","oldest_block_identifier","index"]` is **not** a drop-in: that field is emitted *only* when the node is pruned (`request_handler.rs:620`), so it is absent on exactly the healthy nodes that must pass, and `PARSE_CANONICAL` would be walking a missing path. Pairing it with `default_value: "0"` is the natural shape, but **no parse directive anywhere in this repo uses `default_value` inside `result_parsing`** (verified: the jq sweep over all specs returns empty; the 33 existing `PARSE_CANONICAL` + `default_value` pairings are all request-side `block_parsing`, never directive `result_parsing`). Whether the router's Go parser honours it there is unverified.

Note also that pinning the genesis *hash* instead of the index would add **no** discrimination for pruning — a pruned node retains block 0 and would pass a hash check exactly as it passes the index check. (It does help MINOR-2; see there.)

A gate that genuinely discriminates has to probe a **deep historical block the pruned node has dropped**, not index 0. Whether Lava's verification model supports a fixed-index `VERIFICATION` template composed with `values[].extension: "archive"` — the current `pruning` entry uses a bare `parse_directive: {function_tag: GET_EARLIEST_BLOCK}` with no template — is the constraint to settle first. **Recommended next step: confirm the supported shape against the router before editing `icp.json`.** If no shape works, the honest alternative is to record in `docs/icp/` that the pruning verification is documentation-only for this chain, so the next reviewer does not re-derive false assurance from a passing gate.

### Why MEDIUM and not CRITICAL

Considered and rejected. Nothing breaks at boot or in the relay path; no incorrect chain data is served; the correctly-configured provider set behaves exactly as probed. Exposure requires an operator to deliberately enable a non-default flag (`--store-max-blocks` has no default — pruning is off unless explicitly requested), and the failure surfaces as failed relays plus QoS demotion rather than silent corruption. It sits at the top of the MEDIUM band: it is a safety mechanism that reports success unconditionally, and the corrected exposure analysis above removes the margin previously assumed to protect it.

---

## MINOR-1 — `/call` is classified as a latest-block request although it is the spec's deepest historical read; archive gating can never apply to it

**Evidence:** `icp.json:164-178` (`block_parsing: DEFAULT ["latest"]`, `compute_units: 80`).

Phase 10 raised `/call` to 80 CU precisely because it dispatches `query_block_range`, a bulk historical read capped at `MAX_BLOCKS_PER_QUERY_BLOCK_RANGE_REQUEST = 10000` (confirmed in `lib.rs`). The dispatch and its range walk are at `request_handler.rs:202` (`match msg.method_name.as_str()`) and `:241-263`, where `lowest_index = highest_block_index.saturating_sub(number_of_blocks)` — an arbitrary window anywhere in the ledger's 38M-block history.

The CU was corrected; the block classification was not. Under `DEFAULT ["latest"]` every `/call` is classified as a latest-block request, so `archive.rule.block: 29509` can never trigger for it and a deep-history `query_block_range` is routed as if it were a tip query.

**This is the same argument settled decision (g) used to *reject* `DEFAULT ["latest"]` for `/account/balance`** — "would classify a historical query as latest-block and could route it to a pruned provider that cannot serve it, undermining the archive extension." That rationale was applied to `/account/balance` and not to `/call`, which is the endpoint where it bites hardest. Recording the asymmetry, not re-litigating (g).

**No clean fix exists, which is why this is MINOR.** Lava classifies per API name; `/call` multiplexes five NNS methods over one name, and a `PARSE_CANONICAL` into `parameters.highest_block_index` would resolve only for `query_block_range` and walk a missing path for the other four. Suggested action: record the limitation in `docs/icp/` alongside the CU rationale, so the next maintainer knows `/call` is deliberately un-gated rather than overlooked.

---

## MINOR-2 — Rosetta-blocks mode silently changes the block index space, and the endpoint that detects it carries no verification

**Evidence:** `icp.json:409-424` (`/status`, `EMPTY` / `deterministic: false`, no verification), `icp.json:426-429` (`verifications: []` on the GET collection).

ICP Rosetta has two operating modes. Under `--enable-rosetta-blocks` (`main.rs:235-236`), several ledger transactions are aggregated into one *Rosetta block*, and `network_status` returns `highest_rosetta_block.block_identifier` (`request_handler.rs:647-679`) — a **different index space** from the default mode. `/block`, `GET_BLOCKNUM`, `GET_BLOCK_BY_NUM` and `archive.rule.block` all shift with it.

Two providers in different modes would report different heights for the same chain state and different hashes at the same index — corrupting block-lag QoS scoring and hash-based fork detection. The `chain-id` verification cannot discriminate: `/network/list` returns the same ledger canister id in both modes.

The spec already serves the one endpoint that reports the mode. `GET /status` returns exactly that and nothing else (`rosetta_server.rs:254-262`):

```rust
#[get("/status")]
async fn status(req_handler: web::Data<RosettaRequestHandler>) -> HttpResponse {
    let rosetta_blocks_mode = req_handler.rosetta_blocks_mode().await;
    to_rosetta_response(Ok(RosettaStatus { rosetta_blocks_mode }), …)
}
```

`/status` is therefore well justified in the spec — it is the mode discriminator, not a generic liveness route — but it is configured as a plain read with no verification attached.

**Two caveats, both deliberate reasons this is MINOR and carries no concrete patch:**

1. `--enable-rosetta-blocks` sits behind `#[cfg(feature = "rosetta-blocks")]`, so stock builds will not even accept the flag. Real but low likelihood.
2. The JSON serialization of `RosettaStatus.rosetta_blocks_mode` could **not** be observed — the public gateway 404s `/status` (settled decision (e)) — so no `parser_arg` or `expected_value` is proposed here; it would need a live check against a self-hosted binary first.

Note the trade-off before acting: a verification on `/status` would convert decision (e)'s benign gateway artifact into a **hard provider rejection** for anyone fronted by a filtering gateway. That may be acceptable — such a provider is already failing a mandatory base-collection API — but it is a deliberate policy choice, not a free win. A genesis-*hash* verification on `/block {index:0}` is the lower-blast-radius alternative: it catches the `first_rosetta_block_index == 0` variant, whose index-0 block is a Rosetta block with a hash differing from the ledger genesis `ffca0ecf5e837541c7ee5be431e433ad8e972a7f371e86fbe4f8ad646c7cbcea` (already captured byte-identically twice in Phase 8/10b). It does not catch the `first_rosetta_block_index > 0` variant.

---

# Checked — not findings

Recorded with evidence so they are not re-litigated next pass. The first two were nearly filed as findings and were killed by repo-convention checks.

| Item | Evidence | Verdict |
|---|---|---|
| **No `timeout_ms` on `/call` and `/search/transactions`** (80 CU each, both bulk-range reads) while the trivial `/construction/submit` has 30000 | ETH1's own `eth_getLogs` is cu=80 with **no** timeout; `eth_estimateGas` cu=100, none. Repo-wide only **19 of 631** APIs at cu≥80 declare one | **Not a finding** — matches the primary reference spec and repo convention |
| **`/mempool` at 10 CU** vs the guide's "mempool list queries = 20 CU" | Every mempool-class endpoint in the repo uses 10 (`CARDANO /mempool/{hash}`, all `txpool_*` across ~20 specs). ICP's mempool is a stub that returns empty | **Not a finding** — guide line is a soft default; repo convention is uniform at 10 |
| **`/status` sits in a mandatory `add_on: ""` base collection** — initially suspected as a guide Step 1.1a platform-endpoint exclusion | It is the `rosetta_blocks_mode` discriminator (`rosetta_server.rs:254`), not a health route, and it is a registered route of the self-hosted binary — not a third-party platform endpoint | **Not a finding** — placement is justified; see MINOR-2 for what it *should* additionally be used for |
| API completeness | Route table enumerated from `rosetta_server.rs`: 18 POST + 1 GET, exact match to the spec's 19; `/account/coins` and `/events/blocks` genuinely unregistered | **Not a finding** — independently confirms R3 from the primary source |
| Nested-array `parser_arg` `["0","network_identifiers","0","network"]` | Probe-confirmed; `rawData` matched `expected_value` 1/1 | Correct |
| `GET_BLOCK_BY_NUM` template uses `%d` | ICP block indices are decimal, not hex | Correct |
| Blanket `content-type: application/json` `pass_override` | All 18 POST endpoints take JSON bodies; no CBOR/form-encoded outlier | Correct |
| Duplicate API names / schema | `check_method_schema.sh` → all 19 `schema ok`, no duplicates | Correct |
| `archive.cu_multiplier: 5`, `rule.block == latest_distance` (29509/29509) | Guide's canonical multiplier; 46 repo specs use the equal pairing, 0 use the unsafe direction | Correct (independent of MEDIUM-1, which concerns the *field parsed*, not the *values chosen*) |
| `run_stats.sh` | Errors on argument shape (`start_epoch_seconds must be an integer`), not on the spec | Not applicable — not scored |
| The four `FIX_LIST.md` MINORs | Reviewed in full | Deliberately not re-raised |

---

# Summary

- **Endpoints reviewed:** 19 (18 POST + 1 GET), across 2 api_collections, plus 3 parse directives and 2 verifications.
- **Gaps by severity:** CRITICAL 0, MEDIUM 1, MINOR 2.
- **Cleanup findings:** none.

**Deployment readiness.** The spec is functionally sound and can deploy as-is: it boots, parses, verifies, and relays correctly, and every mechanical gate passes except the adjudicated `allowed_block_lag_for_qos_sync` override. Nothing found in this pass blocks deployment.

The one substantive caveat is MEDIUM-1: `icp.json` ships a `pruning` verification that **cannot reject any provider in any configuration**, and both the base-tier retention guarantee and the 5x-CU archive tier are therefore unenforced. That is a latent admission-control hole, not an active break — it only bites once a provider enables pruning. It should be resolved before providers are onboarded at scale, and it needs a router-side answer about the supported verification shape rather than a blind spec edit. Until then, the passing `pruning` gate in Phase 6/8 output should not be read as evidence that pruned providers are being excluded.
