# Spec Review Gaps — Mantle (MANTLE / MANTLET)

**Reviewer index:** 1
**Spec file:** `mantle.json`
**API docs path:** none provided
**Credentials path:** none provided (no live testing performed by this reviewer; relied on `docs/mantle/METHOD_PROBE_REPORT.md` for live-node evidence)

## Scope & Method

This review reads `mantle.json` against:
- `.claude/skills/review-spec/SPEC_GUIDE.md` (full guide, read start to finish)
- `docs/mantle/METHOD_PROBE_REPORT.md` (live router/probe evidence)
- `docs/mantle/DISABLED_JUSTIFICATIONS.md` (positive-evidence log for disabled inheritance)
- Sibling gold specs in the repo (`ethereum.json`/ETH1, `optimism.json`/OPTM, `avalanche_c.json`, `monad.json`, `celo.json`, `ronin.json`) for pattern/precedent comparison
- External docs (web search) to independently confirm that Mantle's non-standard methods (`eth_estimateL1Fee`, `rollup_gasPrices`, `rollup_getInfo`) are real, documented Mantle RPC methods and not hallucinated — confirmed via Dwellir's Mantle RPC docs, which list exactly these three under "L2-Specific Methods" and no others.

No API-docs path or credentials path was supplied for this run, so Phase 3 (doc-diff API completeness) and Phase 9 (fresh live testing) were done via the probe report + external doc cross-check instead of a full OpenAPI diff or new live calls.

## Settled items (not re-reported per task instructions)

The following were confirmed consistent with the mandated decisions and are *not* listed as findings: `deposit` = `10000000ulava`; `blocks_in_finalization_proof` = `1` (fast/instant OP-Stack finality, matches `optimism.json`); disabling of methods purely on `-32601` from the whitelisted public gateways; the `trace` add-on disable (positive evidence in `DISABLED_JUSTIFICATIONS.md`); the disabled `trace` collection's empty verifications and the locally-declared `GET_EARLIEST_BLOCK` directive (both match production golds MONAD/avalanche_c/celo).

## Probe report FAIL/WARN walkthrough (Step 4, mainnet)

Every non-PASS classification in `METHOD_PROBE_REPORT.md` was checked against the "positive evidence required to disable" rule. None warrant a spec change:

| Method(s) | Probe verdict | Why not a spec defect |
|---|---|---|
| `eth_coinbase`, `eth_compileLLL`, `eth_getCompilers`, `eth_getWork`, `eth_hashrate`, `eth_mining`, `eth_protocolVersion`, `eth_sign` | FAIL (`-32601`) | Inherited ETH1 legacy/PoW-era methods. `-32601` here is the confirmed public-gateway whitelist artifact, not evidence of node-client absence. No docs state these are removed on op-geth. Left enabled (inherited), consistent with how `optimism.json`/`base.json` also leave them inherited rather than disabling. |
| `eth_estimateL1Fee`, `rollup_gasPrices`, `rollup_getInfo` | FAIL (`-32601`) | Same whitelist artifact — confirmed both are legitimate, documented Mantle L2-specific methods (Dwellir Mantle docs, "L2-Specific Methods" section) and correctly `enabled: true` in the spec's main collection. Values match the `optimism.json` gold for `rollup_gasPrices`/`rollup_getInfo` exactly. |
| `eth_getBlockRange`, `net_peerCount`, `rpc_modules` | WARN-DISAGREEMENT | One public upstream (`rpc.mantle.xyz`) enforces the whitelist and rejects; the other (`publicnode.com`) fully supports. This is a per-upstream gateway policy difference, not a spec/parser defect — router-level behavior depends on upstream selection, unrelated to spec correctness. |
| `eth_getFilterLogs` | WARN (`-32000 filter not found`) | Architectural: router is not session-affine across multiple upstreams, so a filter created on one upstream isn't visible on another. Not a spec-level defect. |
| `eth_signTransaction` | WARN (`-32000`) | No unlocked account on public infra — expected for any remote/public node, not a routing or spec defect. |
| `eth_simulateV1` | WARN (`-32000 missing deposit transaction`) | OP-Stack-specific application constraint (requires deposit-tx context); method is reachable and routed correctly. Not a defect (see CU finding below for an unrelated, separate concern about this same method). |

**Testnet:** the single WARN (intermittent `result:null` on near-head `eth_getBlockByNumber` over the Tenderly ws gateway) is explained as read-after-write replica lag, reproduced/explained via a direct manual call — not a parser/directive defect. `GET_BLOCKNUM`/`GET_BLOCK_BY_NUM`/chain-id/pruning/trustless-rpc all verified OK.

No FAIL/WARN in the probe report corresponds to an actual spec defect.

## Findings

### 1. `eth_simulateV1` compute_units likely underpriced relative to its actual cost (MEDIUM)

- **File/line:** `mantle.json`, the `eth_simulateV1` API entry (main `add_on: ""` collection), `compute_units: 20`.
- **Evidence:** The spec guide's CU table classifies "Complex queries" (e.g., `eth_estimateGas`, `getLogs`) at 60–100 CU, and `ethereum.json` prices `eth_estimateGas` at 100 CU for a single call. `eth_simulateV1`'s payload (`blockStateCalls`) can bundle an arbitrary number of simulated blocks, each containing an arbitrary number of calls, in a single request — structurally it can execute far more compute than one `eth_call`/`eth_estimateGas` invocation, yet it is priced at 20 CU, the "block/transaction query" tier (the same tier as a plain `eth_getBlockByHash`). No sibling spec defines this method, so there is no direct gold precedent to defer to.
- **Impact:** Underpriced heavy-compute endpoints let consumers extract disproportionate provider compute for minimal CU cost — an economic/DoS-adjacent risk flagged explicitly in the guide's "Common Pitfalls" (#4, Unrealistic CU Values → economic imbalance). This does not break correctness or block deployment, but should be benchmarked/raised before wide provider adoption, likely into the 60–100 CU range (or higher, with `timeout_ms`, if multi-block simulation payloads are expected to be large in practice).

### 2. `eth_estimateL1Fee` marked `deterministic: false` — worth double-checking intent (MINOR)

- **File/line:** `mantle.json`, the `eth_estimateL1Fee` API entry, `category.deterministic: false`.
- **Evidence:** This method computes a fee estimate from `"latest"` state (`DEFAULT` block parsing), structurally identical in shape to `eth_estimateGas`, which ETH1 marks `deterministic: true`, and to `rollup_gasPrices` (same collection, same "current L1/L2 price" semantics), which is marked `deterministic: true` in both `mantle.json` and the `optimism.json` gold. Precedent is genuinely mixed, though: ETH1's `eth_maxPriorityFeePerGas` — arguably the closer analog ("suggest a fee from current volatile conditions" rather than "return a value pinned to chain state") — is also `deterministic: false`. So this isn't a clear-cut inconsistency, just an judgment call that could reasonably go either way.
- **Impact:** If `false` is the correct choice, no action needed — it's the conservative direction (worst case, the API is simply excluded from cross-provider data-reliability checks; it can't cause a false-positive fraud flag). Worth a quick sanity check that this was a deliberate choice given the mixed sibling precedent, rather than an oversight, before shipping.

## Summary

- **Endpoints reviewed:** 63 enabled base-collection (`jsonrpc`, no add-on) methods on mainnet (54 inherited from ETH1 unchanged + 9 Mantle-specific additions: `eth_getBlockRange`, `rollup_getInfo`, `rollup_gasPrices`, `eth_estimateL1Fee`, `eth_blobBaseFee`, `eth_getRawTransactionByHash`, `eth_getRawTransactionByBlockHashAndIndex`, `eth_getRawTransactionByBlockNumberAndIndex`, `eth_simulateV1`), plus the inherited `debug` (11 APIs) and `bundler` (5 APIs) add-on collections (left enabled/inherited unchanged, consistent with `optimism.json`/`base.json`/`arbitrum.json` — the other OP-Stack chains in this repo — rather than `avalanche_c.json`/`monad.json`/`celo.json`, which explicitly disable `bundler`), and the disabled `trace` collection (8 APIs, justified). Testnet (`MANTLET`) inherits all of the above via `imports: ["MANTLE"]` and overrides only `chain-id`.
- **Gaps found:** 0 CRITICAL, 1 MEDIUM, 1 MINOR.
- **Deployment readiness:** Ready for deployment. Neither finding blocks governance submission; the MEDIUM (CU pricing on `eth_simulateV1`) is worth a benchmark pass before/soon after providers adopt it, and the MINOR (determinism flag) is a one-line sanity check, not a correctness issue.
