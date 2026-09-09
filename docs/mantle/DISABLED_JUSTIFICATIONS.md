# Mantle (MANTLE / MANTLET) — Disabled Inheritance Justifications

Every `enabled: false` entry in `mantle.json` (methods, add-ons, or collections that
override an inherited-enabled ETH1 default) must have a positive-evidence row here.
Runtime probe results (`-32601`, HTTP 501/404/5xx, timeout) are NOT sufficient evidence.

| name | evidence-type | source | quote / justification |
|---|---|---|---|
| `trace` (add-on collection) | docs-explicit / client-source | https://docs.mantle.xyz (JSON-RPC method reference) + op-geth source (github.com/ethereum-optimism/op-geth — no `eth/tracers/parity` Parity `trace_*` namespace) | op-geth (Mantle's execution client) does not implement the Parity `trace_*` namespace. Zero `trace_*` methods documented across all 6 providers surveyed (QuickNode, MetaMask, dRPC, Dwellir, Blast, Mantle official). Positive evidence of absence — the inherited ETH1 `trace` add-on is disabled as a stub (`enabled: false`, `apis: []`). The `debug` namespace (op-geth-native) is retained enabled. |
