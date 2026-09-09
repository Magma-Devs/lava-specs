# Spec Review Gaps — ICP (`icp.json`)

**Reviewer**: parallel_3 — assigned angle: method-set completeness and the archive/pruning tier. CU pricing and per-method block-parsing correctness are covered by parallel reviewers and are intentionally not re-litigated here except where a finding is structural rather than a pricing/parsing judgment call.

**Inputs**: `icp.json` (435 lines, single spec `ICP`, mainnet-only). No API-docs path supplied. No credentials path supplied (Phase 9 live testing substituted by `docs/icp/METHOD_PROBE_REPORT.md`, an already-completed live probe run through the smart-router against `https://rosetta-api.internetcomputer.org`, read in full before this review).

---

## Phase 0 — Removed-field / internal-path guard

```
$ bash .claude/skills/create-spec/scripts/check_unused_fields.sh icp.json
RESULT: PASS (no removed fields)                                    exit=0
```

`internal_path` is `""` on both collections (lines 18, 405) — the internal-path guard's trigger condition ("if any spec under review sets `internal_path`") does not apply, but it was run anyway for completeness:

```
$ bash .claude/skills/create-spec/scripts/check_internal_paths.sh icp.json
RESULT: PASS (0 warning(s), no errors)                              exit=0
```

No `NAME_CARRIES_PATH`, `LABEL_AS_PATH`, `AMBIGUOUS_REST_NAME`, or `AMBIGUOUS_REST_SHAPE` hits. Envelope is exactly `{ "proposal": { "specs": [ ... ] } }` (`jq '.proposal|keys'` → `["specs"]`); no `title`/`description`/`deposit`; spec-level keys are exactly `allowed_block_lag_for_qos_sync, api_collections, average_block_time, block_distance_for_finalized_data, blocks_in_finalization_proof, enabled, imports, index, name` — identical to the key set used by every other single-entry mainnet-only spec checked for comparison (`aca.json`, `tendermint.json`, `trac.json`, `xrt.json`, `cosmossdkv45.json`, others). **No cleanup findings.**

---

## Phase 1 — Provider identification

Native Rosetta v1.4.10 reference implementation (`ic-rosetta-api`), self-hosted binary, `api_interface: rest`, plain JSON over HTTP POST at the root path (no version prefix). Two `api_collections`, both `add_on: ""`: a POST collection (18 apis, lines 22–301) and a GET collection (1 api, `/status`, lines 409–424). `imports: []` (line 8) — mainnet-only, no inheritance, consistent with 25+ other single-entry specs in the repo and with the IC having no separate public testnet network. Not reviewed further here — not this reviewer's angle and not disputed by the probe report.

---

## Phase 2 — Network parameters

```
$ bash .claude/skills/create-spec/scripts/check_network_params.sh icp.json
=== PASS ===
blocks_in_finalization_proof|ICP|1
average_block_time|ICP|4500
block_distance_for_finalized_data|ICP|1
=== FAIL ===
allowed_block_lag_for_qos_sync|ICP|expected=3 declared=20        exit=1
```

The `allowed_block_lag_for_qos_sync=20` FAIL is a **pre-adjudicated, evidence-backed override**, not a finding: ICP ledger blocks are transaction-paced (one tx per block, index advances on demand, not on a fixed timer), and 124 consecutive tip-delta samples showed a max gap of 50.5s against the formula's implied 13.5s window — the formula's `3` would false-flag a healthy, fully-synced provider. 11 other specs already use exactly 20 (`flow.json` FLOWT, `cronos.json` CRONOS/CRONOST, `eos.json` EOS/EOST, `base.json` BASES, `arbitrum.json` ARBITRUM/ARBITRUMN/ARBITRUMS, `tempo.json` TEMPO/TEMPOT — independently confirmed by grep), and `movement.json` overrides the same formula more aggressively (lag 50 at `average_block_time` 10000) for the same class of reason (irregular block cadence). Not reported as a finding per the task's standing instruction.

`blocks_in_finalization_proof: 1` matches ICP's deterministic BLS threshold finality with an explicit no-reorg guarantee (finality-typed rule, not the probabilistic-finality fallback) — pre-adjudicated, not a finding.

---

## Phase 3 — API completeness (primary angle)

### 3.1 Spec-internal consistency

`icp.json` declares 19 `apis` (18 POST + 1 GET). Extracted and diffed programmatically against `/tmp/icp_methods.txt` (19 lines) and re-verified with the repo's own diff tool:

```
$ bash .claude/skills/create-spec/scripts/compare_spec_methods.sh icp.json /tmp/icp_methods.txt
=== MISSING (in your list, not in spec or imports) ===
=== EXTRA IN SPEC (not in your list) ===
                                                                       exit=0
$ bash .claude/skills/create-spec/scripts/check_method_schema.sh icp.json
=== FAIL ===
                                                                       exit=0
```

19 PRESENT, 0 MISSING, 0 EXTRA, 0 schema failures, 0 duplicate names. This confirms `icp.json` matches `/tmp/icp_methods.txt` exactly — an internal-consistency check, not on its own an independent completeness proof (a wrong reference list would pass silently).

### 3.2 Independent completeness anchor

To corroborate against something other than the supplied reference list, I reconciled the count against the **published Rosetta v1.4.x API surface** (Data API + Construction API + the optional Indexer and Call extensions — a stable, versioned, publicly documented spec, independent of any file in this repo or session):

| Category | Standard endpoints | Count |
|---|---|---|
| Data — Network | `/network/list`, `/network/options`, `/network/status` | 3 |
| Data — Account | `/account/balance`, `/account/coins` | 2 |
| Data — Block | `/block`, `/block/transaction` | 2 |
| Data — Mempool | `/mempool`, `/mempool/transaction` | 2 |
| Construction | `/construction/{derive,preprocess,metadata,payloads,parse,combine,hash,submit}` | 8 |
| Indexer (optional) | `/search/transactions`, `/events/blocks` | 2 |
| Call (optional) | `/call` | 1 |
| **Total standard surface** | | **20** |

`icp.json` implements 18 of these 20 — omitting exactly `/account/coins` and `/events/blocks` — and adds one non-standard, implementation-specific endpoint, `/status` (a liveness/health route, not part of the Rosetta spec proper). 18 + 1 = **19**, matching `icp.json` exactly. This is consistent with the task's citation of the reference binary's route table (`rs/rosetta-api/icp/src/rosetta_server.rs`: 18 `#[post(...)]` + one `#[get("/status")]`, all wired via `.service(...)`) without depending on it.

`/account/coins` and `/events/blocks` are genuinely absent from `icp.json` — not present-and-disabled:

```
$ grep -n "account/coins\|events/blocks" icp.json
NOT FOUND (confirms genuinely absent, not present-and-disabled)
```

This is the structurally correct treatment per the spec guide's "exclude, don't include-and-disable" rule for endpoints the reference implementation never registers.

**Conclusion: no completeness gap.** Two independent cross-checks (repo diff tooling against the supplied method list; the public Rosetta v1.4.x endpoint taxonomy against the reference binary's known omissions) both land on exactly 19/19 with the same two absences accounted for.

---

## Phase 4 — Method-by-method (scope note)

Per-method `block_parsing`/`category` correctness is the explicit angle of a parallel reviewer. One item is flagged here only as a **scope note**, not a finding, so Phase 10 consolidation can distinguish "examined and cleared" from "nobody looked": `/network/options` (line 54) and `/status` (line 411) both use `parser_func: EMPTY` + `deterministic: false`, whereas every other `EMPTY`-parsed API in the file pairs `EMPTY` with `deterministic: true`. Whether `EMPTY`+`false` is the right pairing for a live-status/options endpoint (vs. `DEFAULT`, which the guide's own appendix uses for the analogous `eth_syncing`) is a per-method parsing judgment call, left to the parsing reviewer. `check_method_schema.sh` confirms this combination is schema-valid either way (no FAIL).

---

## Phase 5 — Parse directives audit

All three required directives present in the POST collection and reference APIs that exist in the spec:

| Directive | `api_name` | Verdict |
|---|---|---|
| `GET_BLOCKNUM` (line 312) | `/network/status` | Present, correct shape, probe-confirmed live (`smartrouter_latest_block` populated) |
| `GET_BLOCK_BY_NUM` (line 325) | `/block` | Present, correct shape; router-tracker exercise was NOT_EXERCISED for a router-build reason unrelated to `icp.json` (block-hash polling off by `off-operator-choice` default), but the exact directive pathway was independently hand-verified against the upstream for two block indices (38267873, genesis 0) per the probe report |
| `GET_EARLIEST_BLOCK` (line 339) | `/network/status` | Present, correct shape, probe-confirmed live (pruning verification OK 2/2) |

No `SUBSCRIBE`/`UNSUBSCRIBE` — correct, Rosetta REST has no WebSocket subscription surface and none of the 19 methods imply one.

```
$ bash .claude/skills/create-spec/scripts/check_directive_presence.sh icp.json
OK                                                                    exit=0
```

---

## Phase 6 — Verification audit, including the archive tier (primary angle)

### 6.1 chain-id

`expected_value: "00000000000000020101"` (line 371), parsed via a 4-deep nested-array walk (`parser_arg: ["0","network_identifiers","0","network"]`, line 359–364) — probe-confirmed OK, 1/1 provider, correct value.

### 6.2 The archive/pruning/extension triplet

```json
// verifications (line 375)
{
  "name": "pruning",
  "parse_directive": { "function_tag": "GET_EARLIEST_BLOCK" },
  "values": [
    { "latest_distance": 29509 },
    { "extension": "archive", "expected_value": "0" }
  ]
}
// extensions (line 391)
{ "name": "archive", "cu_multiplier": 5, "rule": { "block": 29509 } }
```

This is structurally identical in shape to the spec guide's own template (Step 3.5: `pruning` verification referencing `GET_EARLIEST_BLOCK`, a base-tier `latest_distance` value, an `{extension, expected_value}` archive-tier value, and a matching `archive` extension with `cu_multiplier` + `rule.block`) and passes every automated gate that targets this triplet:

```
$ bash .claude/skills/create-spec/scripts/check_archive_value.sh icp.json      → PASS
$ bash .claude/skills/create-spec/scripts/check_extensions.sh icp.json         → PASS  (cu_multiplier=5, rule.block=29509)
$ bash .claude/skills/create-spec/scripts/check_verifications.sh icp.json      → PASS  (chain-id + pruning both structurally sound; the one INFO line — "values[0].expected_value missing" — is expected for a latest_distance-only base-tier check, not a defect)
$ bash .claude/skills/create-spec/scripts/check_pruning.sh icp.json 29509      → PASS  (rule.block and latest_distance both within band of the research figure)
```

and was boot-verified live per the probe report: `pruning` OK 2/2 (base-tier `latest_distance` clause satisfied against an earliest block of 0; archive-tier key `rawData:"0" == expected_value:"0"`), and the archive extension itself round-tripped a real genesis block through the router with the `lava-extension: archive` header (Phase 8, `TESTED_OK`).

**Is `expected_value: "0"` (vs. the generic non-EVM default `"1"`) defensible?** Yes — probe-confirmed live: the upstream's `genesis_block_identifier.index` is `0` (ICP's ledger genesis is literally index 0, unlike chains whose "genesis" for pruning purposes is conventionally block 1). This is a correct, evidence-backed deviation from the generic default, not an oversight.

**Is the `29509`-block sizing defensible?** The right comparison is block count, not wall-clock, because nothing in the router or spec model converts `rule.block`/`latest_distance` through `average_block_time` at runtime — they are raw block-count thresholds. On that axis: a pruned ICP Rosetta node (`--store-max-blocks`, undocumented flag in `rs/rosetta-api/icp/src/main.rs`) prunes only in `PRUNE_DELAY = 100_000`-block batches, so any operator who enables pruning at all still retains at least on the order of 100,000 blocks. `29509` sits at **~30% of that floor — roughly a 3.4x safety margin** — regardless of which block-production rate is used to narrate it in wall-clock terms. No spec I could find in this repo pairs an archive `rule.block` with a `latest_distance` smaller than `rule.block` (checked: 0 of 85 archive-bearing specs; see 6.3), and none exceed a real retention floor the way this one would need to for the sizing to be a problem.

One documentation-only wrinkle, not a functional defect: the "24 hours" framing for `29509` implies `86,400,000 ms ÷ 2928 ms/block` — a faster rate than both the spec's declared `average_block_time: 4500` and the probe report's own Step-8 empirical measurements (4274–4848 ms across three window sizes). Read against the spec's own declared/measured rate, `29509` blocks span closer to ~37 hours than 24. This doesn't change the safety conclusion (both readings stay far under the ~100k-block floor above), but the "recent-era rate" isn't independently corroborated anywhere in `docs/icp/` — worth a one-line rationale note for future maintainers, nothing more.

**cu_multiplier: 5** — confirmed the only value `archive.cu_multiplier` takes anywhere in this repo:

```
$ grep -rl '"cu_multiplier"' --include="*.json" . | wc -l
100
# every archive extension in every spec that has one uses exactly 5 — no other value found
```

### 6.3 Is the equal `rule.block == latest_distance` pairing (29509/29509) itself a gap?

This is the one question none of the automated gates actually settle (`check_pruning.sh` compares each value independently against a caller-supplied research figure — passing it `29509` trivially self-validates; the Phase 8 boot never exercised the boundary because the probed upstream has unbounded retention). Checked directly against every other spec in the repo that declares both an `archive.rule.block` and a `pruning.latest_distance`:

| Pattern | Count (distinct spec indices) | Examples |
|---|---|---|
| `latest_distance == rule.block` | 46 | AKASH, DYDX, EOS, IOTA, KAVA, THORCHAIN, NEUTRON, UNICHAIN, MULTIVERSX, XDC, **ICP** |
| `latest_distance > rule.block` (small margin) | 39 | ETH1 (127/128), TRX (127/128), AVALANCHEC (127/128), CARDANO (8192/8193), NEAR (63900/64800) |
| `latest_distance < rule.block` | 0 | — |

ICP's equal pairing (29509/29509) falls in the **larger** of the two established repo buckets (46 vs. 39), including several large, mature specs. Zero specs anywhere in the repo have `latest_distance < rule.block` (which would be the actually unsafe direction — claiming a base tier retains less than the point at which archive becomes mandatory). **Not a finding** — equal is squarely within repo convention, and the smaller "±1 block" margin seen in the other 39 looks like an artifact of two independently-rounded formulas rather than an enforced rule.

---

## Phase 7 — Collection inheritance

N/A — `imports: []`, no parent spec, nothing to merge or override. Both collections (`add_on: ""` POST/GET, differentiated by `type`) are self-contained, consistent with a from-scratch (non-inheriting) spec per Step 3.1.

---

## Phase 8 — Headers audit

Single header, POST collection only: `content-type: application/json`, `kind: pass_override` (line 302–308). Correct and safe as a blanket override — Rosetta uses uniform JSON POST bodies across all 18 POST endpoints (no CBOR/form-encoded outlier the way Cardano/Stellar have), so the "mixed content-type" failure mode the guide warns about does not apply. No `pass_send` auth header — consistent with a self-hosted reference binary that Lava providers run directly (no third-party API key layer). GET collection has no headers, appropriately.

---

## Phase 9 — Live testing

No credentials path supplied to this review. Substituted by `docs/icp/METHOD_PROBE_REPORT.md`, a completed live run through the smart-router against the only public upstream. Read in full; its FAIL/WARN items (`/call` and `/status` HTTP 404, `LOG_WARN=49`) are gateway-filtering and router-relay artifacts already adjudicated as non-defects in the task brief, not re-litigated here.

---

## Findings

No CRITICAL or MEDIUM findings.

**MINOR-1 — Archive-sizing rate rationale undocumented.** The `29509`-block archive/pruning threshold is narrated (in review context, not in-repo) as "24h at a recent-era rate of 2928 ms/block," which diverges from both the spec's declared `average_block_time: 4500` and the probe report's empirical 4274–4848 ms range. Does not affect correctness or safety (29509 blocks stays ~3.4x under the real ~100k-block pruning floor either way, and `rule.block`/`latest_distance` are raw block counts never derived from `average_block_time` at runtime). Suggested action: add a one-line note to `docs/icp/` recording which rate and window were used to derive `29509`, for future maintainers re-deriving this number after a chain-wide throughput change. Non-blocking.

**MINOR-2 — Scope note, not a defect.** `/network/options` and `/status` pair `parser_func: EMPTY` with `deterministic: false`, the only two `EMPTY`-parsed APIs in the file not paired with `deterministic: true`. Schema-valid either way; whether this is the ideal pairing (vs. `DEFAULT`, as the guide's own `eth_syncing` example uses for comparable live-status endpoints) is a per-method parsing call explicitly in a parallel reviewer's lane and is flagged here only so it is not silently uncovered by either review.

## Cleanup findings

None. `check_unused_fields.sh` exits 0 with no `REMOVED_FIELD` hits.

---

## Summary

- **Endpoints reviewed**: 19/19 (18 POST + 1 GET), 100% coverage against both the supplied reference list and an independently reconstructed Rosetta v1.4.x standard-surface count.
- **Gaps by severity**: CRITICAL 0, MEDIUM 0, MINOR 2 (both non-blocking; one documentation-rationale note, one scope handoff).
- **Archive tier**: triplet (`archive` extension / `pruning` verification / `GET_EARLIEST_BLOCK` directive) is structurally correct, passes all four targeted gates plus live boot verification, and the `29509` sizing is defensible on the safety-relevant axis (block count vs. the real ~100k-block pruning floor) with ~3.4x margin. The equal `rule.block == latest_distance` pairing matches the larger of two established repo conventions (46/85 specs), not an outlier.
- **Readiness verdict**: no completeness or archive-tier blocker found. Ready from this reviewer's angle, pending the parallel CU-pricing and per-method-parsing reviews.
