# Mantle — Phase 10 Fix List (consolidated from 3 parallel reviewers + probe)

Reviewer tallies: R1 = 0C/1M/1m · R2 = 0C/0M/0m · R3 = 0C/0M/0m. **0 CRITICAL.**

## Applied fixes (CRITICAL + MEDIUM)

- **mantle.json:186 — `eth_simulateV1` compute_units 20 → 40** (gap: MEDIUM, "eth_simulateV1 underpriced").
  Rationale: `eth_simulateV1` is a multi-call / multi-block simulate — the cu-semantic simulate band is 40–60, and ETH1 prices the same-class `eth_estimateGas` at 100. It was derived from `eth_call` (cu=20), which under-prices its actual cost. Bumped to 40 (band floor, 2× eth_call) — the minimal defensible correction. No sibling declares `eth_simulateV1`, so no precedent to match.

## Dropped (MINOR — not processed per Phase 10)

- **`eth_estimateL1Fee` `deterministic: false`** (MINOR, "worth double-checking intent"). Left as-is: an L1-fee ESTIMATE varies with live L1 base-fee / GasPriceOracle state, so `deterministic: false` is defensible. Not a correctness issue.

## Disable-suggestions stripped: 0

No reviewer suggested disabling anything on probe-error grounds (the probe -32601s were pre-flagged as gateway-whitelist artifacts). Nothing to strip.

## Watch-list (carried to PR body — need a paid/dedicated Mantle node to re-test)

- `eth_estimateL1Fee`, `rollup_getInfo`, `rollup_gasPrices` — the 3 Mantle-declared custom methods returned `-32601` on the public gateways (which enforce a method whitelist). `eth_estimateL1Fee` is confirmed-current by Mantle's own SDK gas-estimation tutorial; `rollup_*` carry a post-Arsia currency caveat. Retained enabled per the free-tier disable rule (probe -32601 ≠ positive evidence of absence); matches optimism.json which keeps rollup_* enabled.
- Inherited legacy methods (`eth_coinbase`, `eth_sign`, `eth_mining`, `eth_getWork`, `eth_hashrate`, `eth_protocolVersion`, `eth_compileLLL`, `eth_getCompilers`) — `-32601` on gateways; retained inherited-enabled (ETH1 defaults; no positive evidence to disable).
- `debug`, `bundler` add-ons — NOT_TESTABLE on public gateways; need a debug-enabled / bundler node to verify.
