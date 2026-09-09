# Spec Review — `icp.json` (Internet Computer Rosetta API / ICP)

Standalone `/review-spec` pass. No `--api-docs` and no `--credentials` supplied for
this run (both passed empty per the task). This review relies on the spec itself,
`docs/icp/METHOD_PROBE_REPORT.md` (a full router-mediated live probe already
performed against `https://rosetta-api.internetcomputer.org`), the repo's mechanical
checker scripts, and cross-comparison against sibling specs and the Rosetta v1.4.10
API surface / reference implementation (`rs/rosetta-api/icp/src/rosetta_server.rs`).

- Spec: `icp.json` — 1 spec entry (`ICP`), 2 collections (`rest`/POST, 18 APIs;
  `rest`/GET, 1 API — `/status`), 19 APIs total, no `imports`, mainnet-only
  (the IC has no public testnet).
- Live evidence source: `docs/icp/METHOD_PROBE_REPORT.md`, generated 2026-09-08
  against router image `ghcr.io/magma-devs/smart-router:main` (binary
  `v1.4.0-25-g00fd115`), single upstream `rosetta-api.internetcomputer.org`.

## Summary

| Severity | Count |
|---|---|
| CRITICAL | 0 |
| MEDIUM | 1 |
| MINOR | 2 |

**Verdict: ready to merge.** The one MEDIUM is a precision gap on a single endpoint
with a clear, guide-backed fix; it was never exercised by the probe in the specific
shape that would surface it, so it is reported as an unverified-but-well-evidenced
correctness concern rather than a confirmed break. Both MINORs are documentation-level
caveats, not defects.

---

## CRITICAL — none

---

## MEDIUM-1 — `/account/balance` block_parsing and determinism assume `block_identifier` is always present, but Rosetta defines it as optional

**The field.** Per the Rosetta Data API spec, `AccountBalanceRequest.block_identifier`
is a `PartialBlockIdentifier` and is **optional** — omitting it is the documented way
to ask for the *current* balance. `icp.json` does not special-case this:

```json
{
  "name": "/account/balance",
  "block_parsing": {
    "parser_arg": ["0", "block_identifier", "index"],
    "parser_func": "PARSE_CANONICAL"
  },
  "category": { "deterministic": true, "stateful": 0 }
}
```

**Part A — block_parsing.** `PARSE_CANONICAL ["0","block_identifier","index"]` walks
the request body for a field that a large, entirely valid class of requests (any
"what's my current balance" call — arguably the single most common Rosetta balance
query pattern) simply does not send. Contrast with `/block/transaction`, where
Rosetta requires a fully-populated `BlockIdentifier` (both `index` and `hash`
mandatory), so the identical `PARSE_CANONICAL` shape has no such gap there.

This is not a case for weighing `PARSE_CANONICAL` against `DEFAULT` as a tradeoff.
The spec guide's own REST convention table lists exactly this shape — "Returns
current chain state" — as canonically `DEFAULT`, using `/accounts/{address}` as its
worked example, and states the general rule plainly: "Per-endpoint `block_parsing`
primarily tells Lava whether to associate the request with the latest block
(`DEFAULT`) or no block at all (`EMPTY`)" — per-endpoint `block_parsing` is not the
chain's historical-routing mechanism; `parse_directives` (`GET_BLOCK_BY_NUM`, already
correctly configured on `/block`) carry that weight. `PARSE_CANONICAL` here is the
deviation that needs justification, not `DEFAULT`.

**Part B — deterministic.** `deterministic: true` is set unconditionally, but the
endpoint is only genuinely deterministic when a historical `block_identifier` is
supplied. When it is omitted, this is a "current state" query — the same category
`/network/status` falls into in this same spec, which is correctly marked
`deterministic: false` specifically because two honest providers at slightly
different sync heights can legitimately return different values at the same instant.
`/account/balance` with no `block_identifier` is the identical situation, applied to
account state instead of chain-tip state, and the spec treats it oppositely. That
internal inconsistency — one call shape, two different determinism verdicts for the
same underlying reason — is the clearest evidence this is a real gap, not a style
preference.

**Evidence gap, stated plainly.** The probe report's `/account/balance` row is a
`PASS` (`HTTP 200`, `balances:[{"value":"0",...}]`), but the live-inputs paragraph
shows the probe's inputs were resolved with a specific block index in hand, so this
almost certainly exercised the *with-`block_identifier`* path, not the omitted-field
path. The failure mode of `PARSE_CANONICAL` against a genuinely absent path was not
probed here, so this is reported as a well-evidenced, protocol-spec-backed concern —
not a confirmed runtime break — and sized MEDIUM rather than CRITICAL on that basis.

**Fix.** Align with `/network/status`'s pattern for the same reason:
```json
{
  "block_parsing": { "parser_arg": ["latest"], "parser_func": "DEFAULT" },
  "category": { "deterministic": false, "stateful": 0 }
}
```

---

## MINOR

1. **Five of six `/construction/*` "pure" functions have `deterministic: true` inferred from protocol design, not observed.** Rosetta's Construction API is deliberately split into offline-capable pure functions, which is why `true` is the protocol-correct default for `/construction/derive`, `/construction/preprocess`, `/construction/payloads`, `/construction/parse`, `/construction/combine`, and `/construction/hash` — none of them touch chain state by design. But the probe evidence for these six is not uniform, and the task's framing slightly over-generalizes it: **`/construction/derive` actually has a real observed success** (`PASS`, `HTTP 200`, a genuine 35-byte `hex_bytes` input under `curve_type:edwards25519` returned a real derived `account_identifier`). The other five — `preprocess`, `payloads`, `parse`, `combine`, `hash` — are `PASS-existence` only: every probe of them used malformed/placeholder input and only ever observed the *error* path (Rosetta codes 730/700/701), confirming the route and request shape exist but never exercising a successful, comparable-output call. `deterministic: true` is still the right call on protocol-design grounds for all six, but for those five specifically it is inferred, not observed — worth a documentation note for whoever runs the next live-credentialed pass, not a spec change.

2. **`/block`'s `PARSE_CANONICAL` has the same class of gap as MEDIUM-1, at much smaller scale.** Rosetta's `BlockRequest.block_identifier` is a `PartialBlockIdentifier` (object required, but `index`/`hash` are individually optional — at least one must be set). A hash-only `/block` query would leave `["0","block_identifier","index"]` pointing at nothing. This is far lower-impact than `/account/balance`: the internal `GET_BLOCK_BY_NUM` parse directive always supplies `index` (`"block_identifier":{"index":%d}`), so chain-tracker traffic is unaffected, and sequential-index block walking (the dominant real-world access pattern for `/block`) always supplies `index` too. Recorded for completeness; not sized to block merge.

---

## Items considered and dismissed (with rationale)

| Area | Observation | Disposition | Rationale |
|---|---|---|---|
| `allowed_block_lag_for_qos_sync = 20` | `check_network_params.sh` reports `FAIL` (`expected=3 declared=20`) | Not a finding | Settled decision (d) — deliberate, evidence-backed override for a transaction-paced (not clock-paced) ledger; 124-sample empirical gap distribution (max 50.5s) makes the formula's `3` a false-flag risk. Pre-adjudicated; reported here only so the expected `FAIL` isn't mistaken for something this review missed. |
| `blocks_in_finalization_proof = 1` | Non-default value | Not a finding | Settled decision (b) — ICP has deterministic BLS threshold finality with an explicit no-reorg guarantee; `1` is the fast/instant-finality case, correctly classified. |
| Missing `title`/`description`/`deposit`, nine governance fields | Absent from spec | Not a finding | Settled decision (a) — removed from the model. `check_unused_fields.sh` confirms **PASS, no removed fields**; envelope is the canonical `{ "proposal": { "specs": [...] } }`. |
| `/call`, `/status` — `HTTP 404` on probe | FAIL rows in probe report | Not a finding | Settled decision (e) — gateway filtering on the public Cloudflare-fronted host, not absence. Verified against reference source (`rosetta_server.rs` `#[post("/call")]`/`#[get("/status")]`, both wired to `.service(...)`). Do not disable. |
| `LOG_WARN = 49` | Router-swallow of valid Rosetta 5xx application-error bodies | Not a finding | Settled decision (f) — single-provider relay policy issue (any non-2xx treated as hard failure), not an `icp.json` defect; the six affected methods' request/response shapes are all correct. |
| GET collection (`/status`) has empty `parse_directives`/`verifications` | All directives/verifications live in the POST collection | Not a finding | All three directive targets and both verification targets (`/network/status`, `/block`, `/network/list`) are POST-typed, so they can only live in the POST collection. Confirmed against exact repo precedent: `tron.json`'s GET collection (17 APIs) also carries 0 `parse_directives`/0 `verifications`, with all 3 directives + 2 verifications concentrated in its POST collection — the same "rest = POST-JSON, not GET-path" convention this spec follows, and the same file the probe report names as the closest analog. |
| `/construction/submit` `timeout_ms: 30000` | Blocks until IC consensus finality; value not empirically probed (correctly `SKIP`ped — stateful broadcast) | Not a finding | Repo survey of every `hanging_api: true` API across all specs: `30000` is the second-most-common non-null value (11 occurrences, behind only `10000`'s 18). It is also the exact value `algorand.json` uses for `/v2/status/wait-for-block-after/{round}`, a genuinely-blocking wait-for-state-change endpoint — the closest semantic analog in the repo to "blocks until finality." Supporting data point, not a discrepancy: the only other Rosetta spec in the repo, `stacks.json`, sets no `timeout_ms` and no `hanging_api` at all on its own `/construction/submit`, making `icp.json`'s version the more carefully specified of the two. `cu: 10` matches the guide's "transaction submission (stateful) = 10 CU" bracket exactly, and `stateful:1`/`hanging_api:true`/`deterministic:false` matches the guide's documented "Transaction" pattern precisely. |
| `/account/coins` absent | Standard Rosetta Data API endpoint, not in spec | Not a finding | UTXO-model-only endpoint per the Rosetta spec; ICP's ledger is account-based, so this correctly has no analog. |
| `/events/blocks` absent | Optional Rosetta "indexer" endpoint, not in spec | Not a finding | Optional surface; absent from the reference binary's route table (same `rosetta_server.rs` cross-checked for settled decision (e)) — correctly excluded, not a gap. |
| 0 disabled APIs | — | Not applicable | `jq` count confirms 0 APIs with `enabled: false`; no PR-body disable-count claim exists to cross-check (`check_disabled_count.sh` needs a claim to compare against), and settled decision (c)'s "no disabling on free-tier/gateway evidence alone" rule is trivially respected since nothing is disabled. |
| Inheritance / merge-semantics risk | Empty arrays in a child collection merge rather than zero out (guide Step 3.1a) | Not applicable | `grep -l '"ICP"' *.json` (excluding `icp.json` itself) returns nothing — no spec currently imports `ICP`, so this has no live consequence today. Worth re-checking if a future ICP-testnet-shaped spec is added. |
| `/network/options` `deterministic: false` | Response embeds `version.node_version` | Correct, no finding | Provider-binary metadata, not chain state; `false` correctly prevents spurious cross-provider reliability mismatches between different node builds. |
| `/search/transactions`, `/call` `deterministic: false` | — | Correct, no finding | `/search/transactions` result sets can depend on provider indexing depth; `/call`'s determinism depends entirely on the underlying dispatched method, so the conservative default is correct absent per-method granularity. |

---

## What was verified and found correct

- **Removed-field guard**: `check_unused_fields.sh` → `PASS`, exit 0. **Internal-path guard**: `check_internal_paths.sh` → `PASS`, 0 warnings.
- **Network params** (`check_network_params.sh`): `blocks_in_finalization_proof`, `average_block_time`, `block_distance_for_finalized_data` all `PASS`; the one `FAIL` (`allowed_block_lag_for_qos_sync`) is settled decision (d), see table above.
- **Extensions** (`check_extensions.sh`): `PASS` — `archive` extension `cu_multiplier=5`, `rule.block=29509`.
- **Verifications** (`check_verifications.sh`): `PASS` — `chain-id` and `pruning` both present with correct severities; the one `INFO` (base `pruning` value has no `expected_value`, `latest_distance`-only) matches the guide's own worked example shape exactly, not a gap.
- **Archive value** (`check_archive_value.sh`): `PASS`.
- **Method schema** (`check_method_schema.sh`): `PASS` — all 19/19 APIs have valid `enabled`/`compute_units`/`block_parsing`/`category`, correct `parser_arg` shape, no duplicates.
- **Directive presence** (`check_directive_presence.sh`): `OK`.
- **Parse directives**: `GET_BLOCKNUM` (probe-confirmed live against real tip), `GET_BLOCK_BY_NUM` (not exercised by this router build's tracker for an unrelated reason, but independently hand-verified correct against two live indices including genesis), `GET_EARLIEST_BLOCK` (probe-confirmed, returns real genesis index 0) — all three correctly shaped and api_name-targeted.
- **Verifications live-confirmed**: `chain-id` (`00000000000000020101`, 1/1 providers), `pruning` (2/2 keys, both base and `archive` extension).
- **Method probe**: 16 clean/existence `PASS` + 2 expected gateway-filter `FAIL` (`/call`, `/status`, non-defects per settled (e)) + 1 correctly `SKIP`ped stateful broadcast (`/construction/submit`) = all 19 APIs accounted for, 0 unexplained.
- **Empirical block time**: measured 4274–4848ms across three window sizes against a configured `average_block_time` of 4500ms — all within the ±20% tolerance, 0 `BLOCK_TIME_MISMATCH`.
- **Headers**: single `content-type: application/json` `pass_override` on the POST collection is safe — unlike mixed-content-type third-party APIs, Rosetta's convention is uniformly JSON across every POST endpoint, so there is no risk of the blanket override breaking an endpoint that needs a different content-type. No `pass_send` auth headers, correctly absent — self-hosted Rosetta nodes require no provider-supplied API key.
- **Compute units**: 10/20/80 assignments all match the guide's brackets (`simple reads`=10, `block/transaction queries`=20, `complex queries`=80 for `/search/transactions` — the same bracket as `eth_getLogs`, `transaction submission`=10 for `/construction/submit`).
- **API completeness** (no `--api-docs` supplied, so this substitutes structural verification): the 19 APIs map onto the full standard Rosetta v1.4.10 surface (Data API + Construction API + `/status`) with exactly the two expected, justified absences (`/account/coins`, `/events/blocks` — see table above). Cross-checked against the reference implementation's route table, not just documentation.

## Scope limits of this review

- No `--api-docs` path was supplied. Mitigated by a direct reference-implementation source check (`rosetta_server.rs`) rather than documentation alone, which is materially stronger evidence than a docs diff for the two settled gateway-filtering items and the two "correctly absent" endpoints.
- No `--credentials` path was supplied; this review relies entirely on the already-completed `docs/icp/METHOD_PROBE_REPORT.md` live router probe rather than running new live calls.
- Single upstream (`rosetta-api.internetcomputer.org`) is the only public host for this chain — consistent with the IC's mainnet-only architecture, not a probe limitation specific to this review.
- The omitted-`block_identifier` request shape for `/account/balance` (MEDIUM-1) was not itself probed; the finding rests on the Rosetta specification's documented optionality plus this spec's own internal precedent (`/network/status`), not a reproduced failure.
