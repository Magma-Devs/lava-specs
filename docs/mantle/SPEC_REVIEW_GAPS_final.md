# Spec Review Gaps — Mantle (MANTLE / MANTLET) — Final Pass

**Spec file**: `mantle.json`
**Review type**: Final pass, after Phase 10 fixes
**API docs path**: none provided
**Credentials path**: none provided (no fresh live testing performed by this review; relies on `docs/mantle/METHOD_PROBE_REPORT.md` for live-node evidence, and independent structural cross-checks against sibling specs in this repo)

## Scope & Method

This pass reviewed `mantle.json` against:
- `.claude/skills/review-spec/SPEC_GUIDE.md` (full guide, read start to finish, sentinel confirmed)
- `docs/mantle/METHOD_PROBE_REPORT.md` (Phase 8 mainnet/testnet probe + Phase 10b re-probe evidence)
- `docs/mantle/FIX_LIST.md` (Phase 10 consolidated fix list from 3 parallel reviewers + probe)
- `docs/mantle/DISABLED_JUSTIFICATIONS.md` (positive-evidence ledger for disabled inheritance)
- Sibling gold specs: `ethereum.json` (ETH1), `optimism.json`, `base.json`, `monad.json`, `avalanche_c.json`, `celo.json`

No `--api-docs` path was supplied, so a docs-vs-spec endpoint diff (guide Phase 3) could not be performed directly. This is substantially mitigated by `METHOD_PROBE_REPORT.md`, which live-probed 61 of 63 enabled base-collection methods against two real Mantle upstreams plus a WebSocket upstream, and separately verified `GET_BLOCKNUM`, `GET_BLOCK_BY_NUM`, `GET_EARLIEST_BLOCK`/pruning, chain-id, trustless-rpc, and the archive extension on both mainnet and testnet. This limitation is recorded for the record and is not counted as a finding.

## Disabled-entry audit (CRITICAL gate)

```
jq '[.. | objects | select(has("enabled") and .enabled==false)]' mantle.json
```
Returns exactly **one** entry — the `trace` add-on collection (`add_on: "trace"`, `enabled: false`, `apis: []`). Cross-checked against `docs/mantle/DISABLED_JUSTIFICATIONS.md`: it has a positive-evidence row (docs-explicit + client-source: op-geth has no Parity `trace_*` namespace, URL to `docs.mantle.xyz` and `github.com/ethereum-optimism/op-geth` cited). No other `enabled: false` api/collection exists anywhere in the spec (methods, add-ons, or collections) — nothing lacks a ledger row.

**Result: 0 CRITICAL.**

## Independent cross-checks performed this pass

- **`eth_simulateV1` fix verified landed**: `mantle.json` line 186, `compute_units: 40` (confirmed via direct read of the file, not just the fix list's claim). Correctly in the 40–60 simulate band, 2× `eth_call`. Not re-flagged per task instruction (f).
- **The 9 Mantle-specific additions** (`eth_getBlockRange`, `rollup_getInfo`, `rollup_gasPrices`, `eth_estimateL1Fee`, `eth_blobBaseFee`, `eth_getRawTransactionByHash`, `eth_getRawTransactionByBlockHashAndIndex`, `eth_getRawTransactionByBlockNumberAndIndex`, `eth_simulateV1`) confirmed absent from `ethereum.json` (no accidental redundant override of an ETH1-inherited method).
  - `eth_getBlockRange`, `rollup_getInfo`, `rollup_gasPrices` — byte-for-byte identical (`compute_units`, `block_parsing`, `category`) to `optimism.json`'s production-gold declarations.
  - `eth_getRawTransactionByHash` (CU 20), `eth_getRawTransactionByBlockHashAndIndex` (CU 10, `DEFAULT`), `eth_getRawTransactionByBlockNumberAndIndex` (CU 10, `PARSE_BY_ARG` pos 0) — byte-for-byte identical to `avalanche_c.json`'s production-gold declarations for the same methods.
  - `eth_blobBaseFee` — no tracked production-gold precedent exists in this repo (only appears elsewhere in the untracked, in-progress `ronin.json`); CU 10 / `DEFAULT` is consistent with ETH1's simple-read tier and internally consistent with the collection.
  - `eth_estimateL1Fee`, `eth_simulateV1` — no sibling spec declares either; no gold precedent to defer to (already noted in `FIX_LIST.md`).
- **Duplicate API names**: none found (`jq` group-by check across all collections in both specs).
- **JSON validity**: `jq empty mantle.json` succeeds.
- **Network parameters**: `average_block_time=2000`, `block_distance_for_finalized_data=1`, `allowed_block_lag_for_qos_sync=5` (=10000/2000, formula-correct), `reliability_threshold=268435455`, `data_reliability_enabled=true` — all present on both MANTLE and MANTLET, matching the `optimism.json`/`base.json` OP-Stack pattern; probe report confirms 0% empirical block-time drift on both networks.
- **Archive extension + pruning**: `rule.block=90000` / `latest_distance=90000` — internally consistent, and matches `monad.json`'s production-gold pattern exactly (same fields, same values, same `expected_value: "0x0"` archive clause). Live-confirmed via probe (`pruning: OK 2/2` mainnet, `OK 1/1` testnet).
- **Collection inheritance**: `debug` and `bundler` add-ons are correctly left undefined in `mantle.json` (full automatic inheritance from ETH1), matching every sibling OP-Stack spec checked. `trace`'s `collection_data` matches ETH1's on all four differentiator fields (`api_interface`, `internal_path`, `type`, `add_on`), so the disable override correctly takes effect and propagates through to `MANTLET` (which imports `MANTLE`, not `ETH1`, and does not redeclare `trace`).
- **MANTLET (testnet) inheritance**: imports `MANTLE`; only overrides the `chain-id` verification's `expected_value` (`0x138b`), with `parse_directive` correctly omitted so it inherits from the parent per merge semantics (Step 3.1a). Pruning, archive, and the 9 custom methods are all correctly inherited unchanged and were independently confirmed live in the probe report's testnet pass (`chain-id`, `pruning`, `trustless-rpc` all OK 1/1).
- **Economic parameters**: `min_stake_provider` = 5000 LAVA, `shares=1` on both specs — consistent with sibling OP-Stack specs.

## Considered and dismissed (not counted as findings)

| Item | Disposition | Rationale |
|---|---|---|
| `deposit: "10000000ulava"` | Not a finding | Settled decision (a) |
| `blocks_in_finalization_proof: 1` | Not a finding | Settled decision (b) — fast/instant OP-Stack finality, matches `optimism.json` mainnet |
| All `-32601` FAIL/WARN-DISAGREEMENT results in the probe report (`eth_coinbase`, `eth_compileLLL`, `eth_getCompilers`, `eth_getWork`, `eth_hashrate`, `eth_mining`, `eth_protocolVersion`, `eth_sign`, `eth_estimateL1Fee`, `rollup_gasPrices`, `rollup_getInfo`, `eth_getBlockRange`, `net_peerCount`, `rpc_modules`) | Not a finding | Settled decision (c) — confirmed live gateway method whitelist, not positive evidence of client-side absence; nothing disabled on this basis |
| `eth_getFilterLogs` WARN, `eth_signTransaction` WARN, `eth_simulateV1` WARN (`-32000`s) | Not a finding | Non-sticky multi-upstream routing / no-unlocked-account / OP-Stack deposit-tx DA-footprint constraint — architectural/application-level, not spec defects |
| `trace` add-on disabled | Not a finding | Settled decision (d), ledgered in `DISABLED_JUSTIFICATIONS.md` with positive evidence |
| Disabled `trace` stub's empty `verifications`, and the locally-declared `GET_EARLIEST_BLOCK` directive in MANTLE's main collection | Not a finding | Settled decision (e) — both match production golds (MONAD/avalanche_c/celo) |
| `eth_simulateV1` `compute_units: 40` | Not a finding | Settled decision (f) — Phase 10 fix applied and verified present in the file; resolves prior R1 MEDIUM |
| `eth_estimateL1Fee` marked `category.deterministic: false` | Not a finding (considered, dismissed) | Raised as MINOR by R1 in the pre-fix pass ("worth double-checking intent") but explicitly evaluated and dropped in `FIX_LIST.md`: a live L1-fee estimate legitimately varies with L1 base-fee/GasPriceOracle state, so `false` is defensible. It is also the conservative direction — it only excludes the method from cross-provider data-reliability checks and cannot cause a false fraud flag. R2 and R3 (independent parallel reviewers) both reached the same conclusion. Not re-counted here. |
| `debug`, `bundler` add-ons NOT_TESTABLE on public gateways | Not a finding | No positive evidence of absence; correctly left inherited-enabled per settled decision (c) |
| Missing `--api-docs` (Phase 3 completeness diff) | Limitation, not counted | Substantially mitigated by the live method probe (61/63 enabled base methods probed against real upstreams) |

## Summary

- **Endpoints reviewed**: 63 enabled base-collection (`jsonrpc`, no add-on) methods on mainnet (54 inherited from ETH1 unchanged + 9 Mantle-specific additions), plus the inherited `debug` (11 APIs) and `bundler` (5 APIs) add-on collections (left enabled/inherited, consistent with sibling OP-Stack specs), and the disabled `trace` collection (justified). Testnet (`MANTLET`) inherits all of the above via `imports: ["MANTLE"]` and overrides only `chain-id`.
- **Gaps found**: 0 CRITICAL, 0 MEDIUM, 0 MINOR.
- **Deployment readiness**: Ready for deployment. All prior findings from the 3-reviewer Phase 10 pass have been either fixed (`eth_simulateV1` CU 20→40) or explicitly dismissed with documented rationale (`eth_estimateL1Fee` determinism). The disabled-entry audit confirms exactly one `enabled: false` entry (`trace`), fully ledgered with positive evidence. No new defects were found in this independent final-pass cross-check against ETH1, optimism.json, base.json, monad.json, and avalanche_c.json.
