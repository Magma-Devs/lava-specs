# Mantle (MANTLE / MANTLET) — Spec Review Gaps

Reviewed: `mantle.json` against `ETH1` (ethereum.json), sibling OP-Stack L2 specs
(`optimism.json`, `base.json`), and production golds with the same disabled-trace
pattern (`monad.json`, `avalanche_c.json`, `celo.json`).

Inputs: no `--api-docs` and no `--credentials` provided for this run. This review
relies on the spec, sibling specs, `docs/mantle/METHOD_PROBE_REPORT.md`, and
`docs/mantle/DISABLED_JUSTIFICATIONS.md`.

## Summary

No CRITICAL or MEDIUM gaps found. No MINOR gaps found either — the spec's
chain-specific additions (`eth_getBlockRange`, `rollup_getInfo`, `rollup_gasPrices`,
`eth_estimateL1Fee`, `eth_blobBaseFee`, the raw-transaction trio, `eth_simulateV1`)
all cross-check cleanly against ETH1's analogous methods and/or `optimism.json`'s
existing production pattern for CU, `block_parsing`, and `category` fields.

**Total findings: 0 CRITICAL, 0 MEDIUM, 0 MINOR.**

## Review Limitation

No `--api-docs` path was supplied for this run, so API *completeness* (are there
Mantle/op-geth methods that exist on the live node but are absent from the spec)
could not be verified against an authoritative source list. This review instead
relied on structural comparison to ETH1 and sibling OP-Stack specs plus the
empirical method probe. This is a constraint on the review, not a defect in the
spec — recorded here for the record, not counted in the tally.

## Items Considered and Dismissed (with rationale)

To make this review auditable, each area a probe-driven review would typically
flag is listed below with why it was dismissed rather than silently dropped.

| Area | Probe/finding | Disposition | Rationale |
|---|---|---|---|
| `eth_coinbase`, `eth_compileLLL`, `eth_getCompilers`, `eth_getWork`, `eth_hashrate`, `eth_mining`, `eth_protocolVersion`, `eth_sign` | FAIL (`-32601`, inherited from ETH1) | Not a finding | Gateway whitelist artifact per settled decision (c); no positive evidence (docs/client-source) that op-geth lacks them |
| `eth_estimateL1Fee`, `rollup_gasPrices`, `rollup_getInfo` | FAIL (`-32601` on both mainnet upstreams) | Not a finding | Same gateway-whitelist rule explicitly named in settled decision (c); these are Mantle-defined methods, kept enabled absent docs-explicit or client-source evidence of removal |
| `eth_getBlockRange`, `net_peerCount`, `rpc_modules` | WARN-DISAGREEMENT (whitelist split between the two upstreams) | Not a finding | Weaker than a universal FAIL — at least one upstream (`publicnode.com`) fully supports each; router-level pass depends on upstream selection, not a spec defect |
| `eth_getFilterLogs` | WARN (`-32000 filter not found`) | Not a finding | Architectural characteristic of non-sticky multi-upstream routing (filter state created on one upstream, queried on another), not a parse/spec defect |
| `eth_signTransaction`, `eth_simulateV1` | WARN (`-32000`, various) | Not a finding | No unlocked account on public infra / OP-Stack deposit-tx DA-footprint requirement — both are application-level node constraints, not routing or spec defects; method reachable and routed correctly |
| `debug` add-on | NOT_TESTABLE (`debug_traceBlockByNumber` → `-32601` on both) | Not a finding | Gateway whitelist artifact; `debug` (op-geth-native) correctly left enabled per DISABLED_JUSTIFICATIONS.md |
| `bundler` add-on | NOT_TESTABLE (no public ERC-4337 bundler endpoint found) | Not a finding | Inherited-enabled from ETH1 with no positive evidence of absence; consistent with settled decision (c) |
| `trace` add-on | EXCLUDED (`enabled:false`, not probed by design) | Not a finding | Positive evidence disable (op-geth lacks Parity `trace_*` namespace) documented in DISABLED_JUSTIFICATIONS.md; `verifications:[]`/`extensions:[]` shape matches celo.json's identical disabled-trace pattern exactly |
| `deposit` | `"10000000ulava"` | Not a finding | Settled decision (a) |
| `blocks_in_finalization_proof: 1` | Finality-typed | Not a finding | Settled decision (b); matches `optimism.json`/`base.json` mainnet (both `1`) for this OP-Stack single-sequencer ZK-proof L2 |
| Local `GET_EARLIEST_BLOCK` directive, no verifications on disabled `trace` | Byte-identical to ETH1's inherited `GET_EARLIEST_BLOCK`; empty verifications/extensions on disabled trace | Not a finding | Settled decision (e); matches MONAD/avalanche_c/celo production pattern |
| `eth_estimateL1Fee` marked `deterministic:false` | Differs from ETH1's `eth_gasPrice` (`deterministic:true`) | Not a finding | `false` is the conservative/correct choice for a live fee-estimate node suggestion; ETH1's `eth_gasPrice:true` is the outlier here, not Mantle's classification |
| CU values: `eth_getBlockRange`=10, raw-tx trio=20/10/10, `eth_simulateV1`=20, `eth_blobBaseFee`=10 | New chain-specific additions (not present in ETH1) | Not a finding | Cross-checked directly against ETH1's non-raw analogs (`eth_getTransactionByHash`=20, `...ByBlockHashAndIndex`=10, `...ByBlockNumberAndIndex`=10, `eth_call`=20) and `optimism.json`'s existing `eth_getBlockRange`=10/`rollup_*`=10 — all consistent |
| `eth_simulateV1` block parsing (`PARSE_BY_ARG` position `1`) | New addition | Not a finding | Matches the method's real signature (`[payload, blockNumberOrHash]`) — block ref is the second positional argument |
| Network parameters (`average_block_time`=2000, `allowed_block_lag_for_qos_sync`=5, `block_distance_for_finalized_data`=1) | Probe-confirmed empirical block time = 2000ms (0% drift, both networks) | Not a finding | `allowed_block_lag_for_qos_sync` = 10000/2000 = 5 exactly matches formula; `block_distance_for_finalized_data`=1 matches `optimism.json`/`base.json` |
| Archive extension (`rule.block:90000`) / pruning (`latest_distance:90000`) | Probe-confirmed OK 2/2 mainnet, 1/1 testnet | Not a finding | Internally consistent (both use 90000) and empirically verified live |
| MANTLET testnet spec | Only overrides `chain-id`; empty `apis`/`headers`/`parse_directives` | Not a finding | Correct automatic-inheritance pattern per Step 3.1a — inherits pruning/archive/GET_EARLIEST_BLOCK/trace-disable from MANTLE unchanged; testnet chain-id `0x138b` probe-confirmed live |

## Conclusion

The spec is ready for deployment as reviewed. No fixes required. The one caveat
is the review-limitation noted above (no API docs supplied for this pass), which
does not block deployment but means a follow-up pass with official Mantle/op-geth
RPC documentation would be worthwhile to confirm full API-surface completeness.
