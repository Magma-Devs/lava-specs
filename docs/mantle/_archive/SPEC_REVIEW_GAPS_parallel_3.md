# Spec Review: Mantle (MANTLE / MANTLET) — Gap Report

**Spec file**: `mantle.json`
**Reviewer**: parallel reviewer #3
**Inputs**: `mantle.json`, sibling specs in this repo (`ethereum.json`/ETH1, `optimism.json`, `base.json`, `blast.json`, `worldchain.json`, `manta_pacific.json`, `scroll.json`, `arbitrum.json`, `monad.json`, `avalanche_c.json`, `ronin.json`), `docs/mantle/METHOD_PROBE_REPORT.md`, `docs/mantle/DISABLED_JUSTIFICATIONS.md`. No API-docs path and no credentials path were supplied for this run.

## Scope note (not a severity-rated gap)

No third-party API documentation was supplied for this pass, so a docs-vs-spec endpoint diff (Phase 3 of the guide) could not be performed directly. This is substantially mitigated by `docs/mantle/METHOD_PROBE_REPORT.md`, which live-probed 61 of 63 enabled base-collection methods against two real Mantle upstreams (`rpc.mantle.xyz`, `mantle-rpc.publicnode.com`) plus a WebSocket upstream, and separately verified `GET_BLOCKNUM`, `GET_BLOCK_BY_NUM`, `GET_EARLIEST_BLOCK`/pruning, chain-id, trustless-rpc, and the archive extension on both mainnet and testnet. That gives method-level empirical coverage roughly equivalent to what a docs diff would provide, so this limitation is not treated as a deployment blocker.

## Findings

None. No CRITICAL, MEDIUM, or MINOR defects were identified in this review pass.

## Verification performed

The following areas were independently checked against sibling specs and the probe report, beyond the items already settled/excluded per the review brief (deposit amount, `blocks_in_finalization_proof=1`, gateway-whitelist `-32601` results, the disabled `trace` add-on and its justification, and the inherited-then-locally-redefined `GET_EARLIEST_BLOCK`/pruning pattern):

- **JSON validity**: `mantle.json` parses cleanly with `jq`; no duplicate API names within any collection.
- **Network parameters**: `average_block_time=2000`, `block_distance_for_finalized_data=1`, `allowed_block_lag_for_qos_sync=5`, `reliability_threshold=268435455`, `data_reliability_enabled=true` on both MANTLE and MANTLET — all match `base.json`'s mainnet values exactly (the closest production-gold OP-Stack single-sequencer L2), and the probe report confirms 0% empirical block-time drift on both mainnet and testnet.
- **Chain-id verification**: `0x1388` (5000) mainnet / `0x138b` (5003) testnet — both confirmed live in the probe report against real upstreams.
- **Archive extension + pruning**: `rule.block=90000` / `latest_distance=90000` overrides ETH1's default (127/128) and matches the `monad.json` production-gold pattern exactly (same field, same value pattern for a chain with a large full-node retention window); confirmed live via probe (`pruning: OK 2/2` mainnet, `OK 1/1` testnet; `archive` extension probe: PASS).
- **Custom (non-ETH1) API additions** — confirmed none of the 9 chain-specific methods (`eth_getBlockRange`, `rollup_getInfo`, `rollup_gasPrices`, `eth_estimateL1Fee`, `eth_blobBaseFee`, `eth_getRawTransactionByHash`, `eth_getRawTransactionByBlockHashAndIndex`, `eth_getRawTransactionByBlockNumberAndIndex`, `eth_simulateV1`) already exist in ETH1 (no accidental redundant overrides), and each was cross-checked for CU / `block_parsing` / `category` consistency:
  - `eth_getBlockRange`, `rollup_getInfo`, `rollup_gasPrices` — CU, `block_parsing`, and `category` are byte-for-byte identical to `optimism.json`'s production-gold configuration.
  - `eth_getRawTransactionByHash` (CU 20), `eth_getRawTransactionByBlockHashAndIndex` (CU 10, `DEFAULT`), `eth_getRawTransactionByBlockNumberAndIndex` (CU 10, `PARSE_BY_ARG` position 0), `eth_blobBaseFee` (CU 10, `DEFAULT`) — identical to both `avalanche_c.json` and `ronin.json`, and CU values mirror ETH1's non-raw counterparts (`eth_getTransactionByHash`=20, `eth_getTransactionByBlockHashAndIndex`/`ByBlockNumberAndIndex`=10) exactly.
  - `eth_simulateV1` — block reference correctly placed at argument position 1 (`PARSE_BY_ARG ["1"]`), matching the real `eth_simulateV1(payload, blockNumberOrTag)` signature; CU 20 is in line with ETH1's `eth_call`/`eth_getBalance` pricing for comparable single-block-state reads.
- **Collection inheritance**: verified via the differentiator rules in the guide (Step 3.1a) that `debug` and `bundler` are correctly left undefined in `mantle.json` (full automatic inheritance from ETH1, matching the same pattern used by every sibling OP-Stack spec checked — `base`, `optimism`, `blast`, `worldchain`, `arbitrum`, `scroll`, `manta_pacific` all leave these two add-ons undefined too); `trace`'s `collection_data` in `mantle.json` matches ETH1's trace `collection_data` on all four differentiator fields, so the override correctly takes effect.
- **Testnet (MANTLET) inheritance**: `MANTLET` imports `MANTLE` and only overrides the `chain-id` verification's `expected_value` (parse_directive correctly omitted so it inherits from the parent chain), consistent with the merge semantics in Step 3.1a; pruning, archive, and the custom rollup APIs are all correctly inherited unchanged and were independently confirmed live in the probe report's testnet verification pass.
- **Economic parameters**: `min_stake_provider` (5000 LAVA), `shares=1` — identical across every sibling OP-Stack spec checked (base, optimism, worldchain, blast, scroll, arbitrum).
- **WARN/WARN-DISAGREEMENT items in the probe report** (`eth_getBlockRange`, `net_peerCount`, `rpc_modules` upstream disagreement; `eth_getFilterLogs` non-sticky-routing artifact; `eth_signTransaction` no-unlocked-account; `eth_simulateV1` deposit-tx DA-footprint constraint) were all reviewed and determined to be upstream/architectural/gateway-whitelist characteristics rather than spec misconfigurations — none require a spec change, and none of the sibling OP-Stack specs disable the corresponding inherited ETH1 methods either.

## Summary

- Endpoints reviewed: 63 enabled base-collection methods (all inherited-from-ETH1 plus the 9 Mantle-specific additions), plus the disabled `trace` add-on collection.
- Gaps found: 0 CRITICAL, 0 MEDIUM, 0 MINOR.
- Verdict: **Ready for deployment.** The spec's custom API configuration, network parameters, inheritance structure, and disabled-collection justification all track established production-gold patterns (`base.json`, `optimism.json`, `monad.json`, `avalanche_c.json`, `ronin.json`) closely, and every parse directive / verification / extension claim in this review is corroborated by the live probe report on real Mantle mainnet and testnet upstreams.
