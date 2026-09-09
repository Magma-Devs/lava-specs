# Audit of the five specs flagged by `check_parent_duplication.sh`

Follow-up to `SPEC_INHERITANCE_AUDIT_2026-09.md`. Each spec declares ≥10 methods
a base spec owns without importing that base. The guard cannot tell a bug from a
justified exception, so each was probed.

**Result: 2 fixed, 1 audited-no-change, 2 blocked on unreachable endpoints.**

| spec | flagged as | verdict |
|---|---|---|
| HYPERLIQUID | 24 ETH1 methods, no import | stays standalone — **1 missing method added** |
| TRX | 42 ETH1 methods, no import | stays standalone — **4 over-advertised disabled, 2 missing added** |
| THORCHAIN | 42 COSMOSSDK methods, imports only TENDERMINT | audited, no change |
| CANTO | 30 ETHERMINT methods, no ETHERMINT import | **blocked** — no reachable REST endpoint |
| VECHAIN | 38 ETH1 methods, no import | **blocked** — no reachable JSON-RPC endpoint |

## The rule applied

Same as the Frontier-parachain decision: probe the endpoint, then decide.
Importing a base is right when the chain serves most of that base's surface,
because the import buys canonical definitions and future fixes for the price of
a few disables. It is wrong when the chain contradicts the base more than it
agrees with it — that is not inheritance, it is negation, and the disable list
becomes the spec.

## HYPERLIQUID — standalone, one real bug fixed

Probed `https://rpc.hyperliquid.xyz/evm` against all 54 ETH1 base methods:

- **serves 25 of 54 (46%)** — under half. Importing ETH1 would need **29
  `enabled: false` entries**, more disables than served methods. Not inheritance.
- Its 27 declared methods are **accurate**: zero declared-but-unserved.
- 3 are chain-specific (`eth_bigBlockGasPrice`, `eth_getSystemTxsByBlockHash`,
  `eth_getSystemTxsByBlockNumber`) and have no ETH1 equivalent.

**Bug found and fixed: `eth_sendRawTransaction` was served but never declared.**
Transactions could not be broadcast through Lava on Hyperliquid at all. Added
with ETH1's canonical definition.

One cosmetic difference from ETH1 was left alone: `web3_clientVersion` uses
`EMPTY` block-parsing where ETH1 uses `DEFAULT ["latest"]`. The method takes no
parameters, so `EMPTY` is the more defensible of the two; since the spec does not
inherit, nothing forces them to agree.

## TRX — standalone, four over-advertised methods disabled

Probed `https://api.trongrid.io/jsonrpc`, then re-probed each suspect method with
valid parameters to be sure `-32601` meant absent rather than malformed:

```
eth_sendRawTransaction    -32601  the method eth_sendRawTransaction does not exist/is not available
eth_getTransactionCount   -32601  the method eth_getTransactionCount does not exist/is not available
eth_feeHistory            -32601  method not found
eth_maxPriorityFeePerGas  -32601  method not found
eth_getProof              -32601  method not found
eth_hashrate              SERVED  0x0
eth_mining                SERVED  false
```

- **serves 39 of 54 (72%)** — enough that importing ETH1 is arguable, but
  rejected: Tron's `eth_*` is a **compatibility shim over a non-EVM chain**
  (TVM, its own address format, balances in sun). Inheriting ETH1's canonical
  definitions would assert an equivalence that does not hold at the semantic
  level, and no probe can check semantics — only presence.
- **4 methods were declared and enabled but return `-32601`**: `eth_feeHistory`,
  `eth_getProof`, `eth_getTransactionCount`, `eth_maxPriorityFeePerGas`. Every
  relay to them fails and costs the serving provider QoS. Now `enabled: false`.
  (`eth_sendRawTransaction` was already correctly disabled.)
- **2 methods are served but were undeclared**: `eth_hashrate`, `eth_mining`.
  Added.

Served surface: 158 → 156.

Limitation: TronGrid is one provider. A self-hosted Tron full node run with
`--jsonrpc` may expose more; the disables should be re-checked against a second
operator before anyone concludes the methods are unavailable network-wide.

## THORCHAIN — audited, no change

Compared offline against COSMOSSDK, normalising for proto zero-values written
out explicitly (`"default_value": ""`, `"hanging_api": false`), which the raw
comparison counts as differences:

- 42 shared paths: **38 semantically identical**, 4 genuinely different
  (`/cosmos/tx/v1beta1/{txs,decode,encode}` and one more differ in `category`).
- Importing COSMOSSDK would deduplicate those 42 — but would also **add 205
  endpoints Thorchain has never been probed for**. Thorchain runs a heavily
  customised module set behind its own `/thorchain/*` surface.

Deduplicating 42 at the cost of advertising 205 unverified endpoints is the
mistake this audit exists to prevent. Left unchanged; revisit when someone
probes the 205 against a live `thornode`.

## CANTO and VECHAIN — blocked, not skipped

Neither could be probed from this environment:

```
canto-rest.publicnode.com          no response
api.canto.silentvalidator.com      no response
canto-api.polkachu.com             no response
canto.api.m.stavr.tech             502 Bad Gateway

rpc-mainnet.vechain.energy         Cloudflare challenge
mainnet.vechain.org                no response
vethor-node.vechain.com            no response
rpc.vechain.energy                 no response
mainnet.veblocks.net               no response
```

What is known offline, and what each still needs:

**CANTO** — 30 shared keys with ETHERMINT, of which **29 are byte-identical**.
Importing is very close to pure deduplication. The one difference is
`/ethermint/evm/v1/trace_tx` (CU 10 vs ETHERMINT's 20), which would stay as an
override. The blocker is the **8 methods CANTO would gain** — the
`virtual_frontier_*` bank-contract endpoints, an Evmos-specific extension Canto
may not implement. Probe those 8; disable any that return an error; then import.

**VECHAIN** — 38 ETH1 methods declared. VeChain is not an EVM chain; its
Ethereum JSON-RPC is a proxy layer over the Thor REST API, so it is the same
class as TRX and the expected outcome is *stays standalone, fix accuracy*. Needs
the full 54-method probe against a working endpoint (an API key for
`vechain.energy` would do it) before anything changes.

## Ledger entries to add when the guard's branch merges

`spec-inheritance-exceptions.txt` lives on `fix/substrate-evm-eth1-inheritance`,
so these cannot be added from this branch. Add them after it merges, or the
guard will keep flagging specs that were audited and found correct:

```
HYPERLIQUID UNIMPORTED ETH1       # serves 25/54 ETH1 methods; importing needs 29 disables. Probed 2026-09-09
TRX         UNIMPORTED ETH1       # eth_* is a compat shim over a non-EVM chain; semantics differ. Probed 2026-09-09
THORCHAIN   UNIMPORTED COSMOSSDK  # importing dedups 42 but advertises 205 unprobed endpoints
```

CANTO and VECHAIN get **no** ledger line — they are unresolved, and the guard
should keep failing on them until someone probes them.
