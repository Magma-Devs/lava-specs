# ICP Spec — Phase 10 Fix List

Consolidated from four Phase-9 inputs, read in full:
- `docs/icp/SPEC_REVIEW_GAPS_parallel_1.md` (R1 — tally: CRITICAL=0, MEDIUM=1, MINOR=0)
- `docs/icp/SPEC_REVIEW_GAPS_parallel_2.md` (R2 — tally: CRITICAL=0, MEDIUM=1, MINOR=2)
- `docs/icp/SPEC_REVIEW_GAPS_parallel_3.md` (R3 — tally: CRITICAL=0, MEDIUM=0, MINOR=2)
- `docs/icp/METHOD_PROBE_REPORT.md` (live probe evidence cited by all three reviews; carries no independent severity tally)

Dedup key: `(gap_title, evidence_line_number)`. The two MEDIUM gaps below concern different endpoints (`/call` vs `/account/balance`) with disjoint evidence, so no cross-report merge was needed — each reviewer's single MEDIUM stands as its own entry.

## Result

| Severity | Distinct count after dedup | Disposition |
|---|---|---|
| CRITICAL | 0 | — |
| MEDIUM | 2 | Both approved and applied to `icp.json` (see Job 2) |
| MINOR | 4 | Dropped per strip rule — not carried into this list |

**Disable-suggestion filter: 0 stripped.** No report actually recommended setting `enabled: false` on or removing any method/addon/collection on the strength of probe results alone. The only candidates that surfaced non-2xx on probe — `/call` and `/status`, both `HTTP 404` — were independently identified by all three reviewers *and* the probe report itself as Cloudflare-gateway filtering, not absence, each backed by positive evidence that both routes are registered in the reference binary (`rs/rosetta-api/icp/src/rosetta_server.rs`, `#[post("/call")]` → `.service(call)` at line 307, `#[get("/status")]` → `.service(status)` at line 323). All four documents explicitly say "not a finding" / "do not disable" for these two. The filter's carve-out (positive evidence of registration, with URL) was already satisfied before this consolidation pass — there was nothing left to strip.

No CRITICAL and no third MEDIUM gap was found beyond the two expected below — matches the pre-stated reviewer tallies exactly.

---

## MEDIUM-1 — `/call` `compute_units` priced for its cheapest branch, not its worst one

**Source:** R1 (`SPEC_REVIEW_GAPS_parallel_1.md:68-90`). **Evidence:** `icp.json:172`.

**Status: APPLIED** (`compute_units: 10` → `80`).

**Rationale:** `/call` dispatches to five fixed read-only NNS methods, one of which (`query_block_range`) is a bulk historical-range read hard-capped at `MAX_BLOCKS_PER_QUERY_BLOCK_RANGE_REQUEST = 10000` (`rs/rosetta-api/icp/src/lib.rs:15`) — a single request can return up to 10,000 full blocks. Lava prices CU per API name, not per request-body dispatch branch, so it must be priced for the worst reachable branch. 80 matches `eth_getLogs` (ETH1) and `/search/transactions` in this same spec (`icp.json:157`), both capped bulk-range reads of the same shape. The Phase 6 gate's proposed `simulate` band (40-60) is the wrong frame — nothing here executes arbitrary code.

---

## MEDIUM-2 — `/account/balance` `category.deterministic` inconsistent with the rest of the spec's "current state" handling

**Source:** R2 (`SPEC_REVIEW_GAPS_parallel_2.md:37-97`), Part B only. **Evidence:** `icp.json:103-118` (`category.deterministic`, line 115).

**Status: APPLIED** (`category.deterministic: true` → `false`).

**Rationale:** Rosetta makes `block_identifier` optional on this endpoint; omitted, it returns the *current* balance, which legitimately differs across providers sitting at different sync heights. `/network/status` in this same spec is already `deterministic: false` for exactly that reason, so `true` here is an internal inconsistency.

---

## Considered and rejected

### `/account/balance` `block_parsing`: `PARSE_CANONICAL` → `DEFAULT` (REJECTED — do not apply)

**Source:** R2 MEDIUM-1 Part A (`SPEC_REVIEW_GAPS_parallel_2.md:54-69, 91-97`).

R2 also recommended changing `/account/balance`'s `block_parsing` from `PARSE_CANONICAL ["0","block_identifier","index"]` to `DEFAULT ["latest"]`, on the grounds that the omitted-`block_identifier` request shape (the "current balance" call) leaves the `PARSE_CANONICAL` walk pointing at a field that isn't there.

**Rejected for two reasons, both already established:**
1. The Phase 8 probe called `/account/balance` *without* a `block_identifier` and got `HTTP 200` PASS through the live router (`METHOD_PROBE_REPORT.md:47`) — the alleged breakage does not occur.
2. `DEFAULT ["latest"]` would classify a historical balance query as a latest-block query and could route it to a pruned provider that cannot serve it — strictly worse, and it would undermine the archive extension for this endpoint.

`block_parsing` on `/account/balance` is left exactly as it was (`icp.json:104-111`, unchanged).

---

## MINOR gaps — dropped per strip rule (not carried into this fix list)

- R2 MINOR-1 (`SPEC_REVIEW_GAPS_parallel_2.md:103`) — five of six `/construction/*` "pure" functions have `deterministic: true` inferred from protocol design, not observed live for 5 of 6. Documentation note for a future credentialed pass, not a spec change.
- R2 MINOR-2 (`SPEC_REVIEW_GAPS_parallel_2.md:105`) — `/block`'s `PARSE_CANONICAL` has the same class of gap as MEDIUM-1 (R2's rejected item above), at much smaller scale; internal `GET_BLOCK_BY_NUM` directive and real-world sequential access both always supply `index`, so unaffected in practice.
- R3 MINOR-1 (`SPEC_REVIEW_GAPS_parallel_3.md:207`) — archive/pruning `29509`-block sizing's "24h" rationale narrative doesn't match the spec's declared/measured block rate; sizing itself remains safe (~3.4x under the real ~100k-block pruning floor either reading). Documentation-rationale note only.
- R3 MINOR-2 (`SPEC_REVIEW_GAPS_parallel_3.md:209`) — scope note (not a defect): `/network/options` and `/status` pair `parser_func: EMPTY` with `deterministic: false`, the only two `EMPTY`-parsed APIs in the file not paired with `deterministic: true`. R3 explicitly frames this as a handoff to the parsing-focused reviewer, not a claim of breakage. Note R1 (`SPEC_REVIEW_GAPS_parallel_1.md:136-137`) separately reviewed `/status`'s `parser_func: EMPTY` and `/network/options`'s `deterministic: false` individually (each cleared as correct against the reference implementation) — that covers the two fields but not the specific EMPTY+false *pairing* R3 calls out, so treat this as MINOR-dropped, not as independently adjudicated.

## Out-of-scope findings (not `icp.json` gaps — not carried into this fix list)

- `METHOD_PROBE_REPORT.md:68` — "single-upstream relay swallows valid Rosetta application-error bodies" (the 6-method / 49-line `LOG_WARN` cascade). Explicitly a smart-router relay-layer policy issue (`any non-2xx = provider failure`), not an `icp.json` defect — the report itself says "no spec edit is indicated." Flagged for orchestrator triage outside this fix list, not a gap against the spec.

## Frozen / do-not-touch (confirmed correct by all three reviewers, not a gap)

- **`allowed_block_lag_for_qos_sync = 20`** (`icp.json:10`) — deliberate, evidence-backed override of the formula value `3`. ICP ledger blocks are transaction-paced; a directly measured 50.5s inter-block gap would false-flag a healthy provider under a 3-block (13.5s) window. `check_network_params.sh` reporting this as `FAIL` (`expected=3 declared=20`) is expected and already adjudicated. **Not changed. Must not be changed.**
