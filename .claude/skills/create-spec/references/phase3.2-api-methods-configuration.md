# Phase 3.2: Configure Each API Method

**Objective**: Create accurate configuration for every API

**For Each API Method, Define**:

### 1. Basic Properties
```json
{
  "name": "method_name",
  "enabled": true,
  "compute_units": 10
}
```

`compute_units` is the ONLY CU input — there is no `extra_compute_units` field (it was removed from the model).

**Compute Units Guidelines**:

Align with established specs (ETH1, TENDERMINT) for consistency across the Lava network. When in doubt, use these reference values:

| Category | CU | Reference | Examples |
|----------|-----|-----------|----------|
| Simple reads (no block param) | 10 | ETH1, TENDERMINT | chainId, blockNumber, version |
| Block/transaction queries | 20 | ETH1 | getBlockByNumber, getBlockByHash, getBalance, getTransactionReceipt |
| Transaction submission (stateful) | 10 | ETH1, TENDERMINT | sendRawTransaction, broadcast_tx_sync/commit |
| Complex queries | 60-100 | ETH1 | getLogs (80), estimateGas (100) |
| Traces / debug | 100-200 | ETH1 | debug_traceBlock (100-200) |
| Block traces | 200-500 | ETH1 | debug_traceBlockByNumber (500) |
| Subscriptions | 1000 | ETH1, TENDERMINT | eth_subscribe, subscribe |
| Heavy ops (full scan) | 500-5000 | ETH1 | txpool_content (5000), gettxoutsetinfo (500) |

**Key principles**:
- **Transaction submission** = 10 CU (both ETH1 and TENDERMINT use 10 for sendRawTransaction/broadcast_tx)
- **Block queries** = 20 CU in ETH1; TENDERMINT uses 10 for most block ops — prefer 20 for block-heavy chains
- **Mempool/mempool-like** = 20 CU for list queries; 60-80 for complex range queries (getLogs equivalent)
- **Benchmark when uncertain** — runtime <10ms → 10 CU; 10-50ms → 20 CU; 50-200ms → 60-100 CU; >200ms → 100+

### 2. Block Parsing
**Identify Block Reference Location**:

**No block parameter** (e.g., `eth_chainId`):
```json
{
  "block_parsing": {
    "parser_arg": [""],
    "parser_func": "EMPTY"
  }
}
```

**Uses "latest" implicitly** (e.g., `eth_blockNumber`):
```json
{
  "block_parsing": {
    "parser_arg": ["latest"],
    "parser_func": "DEFAULT"
  }
}
```

**Block in specific argument position** (e.g., `eth_getBlockByNumber` - position 0):
```json
{
  "block_parsing": {
    "parser_arg": ["0"],
    "parser_func": "PARSE_BY_ARG"
  }
}
```

**Block in later position** (e.g., `eth_getBalance` - address at 0, block at 1):
```json
{
  "block_parsing": {
    "parser_arg": ["1"],
    "parser_func": "PARSE_BY_ARG"
  }
}
```

**Block in nested object** (e.g., `eth_getLogs` with `toBlock` field):
```json
{
  "block_parsing": {
    "parser_arg": ["0", "toBlock"],
    "parser_func": "PARSE_CANONICAL"
  }
}
```

**Block in dictionary or array** (e.g., StarkNet style):
```json
{
  "block_parsing": {
    "parser_arg": ["block_number", ":", "1"],
    "parser_func": "PARSE_DICTIONARY_OR_ORDERED",
    "default_value": "latest"
  }
}
```

### REST API Block Parsing Conventions

REST APIs handle block parsing differently from JSON-RPC. In JSON-RPC, block references are in `params[]` and can be extracted with `PARSE_BY_ARG`. In REST APIs, block references are typically in URL path segments (e.g., `/blocks/{height}`), which standard parsers cannot extract from the path template.

**The dominant pattern (~90% of REST endpoints) is `DEFAULT`:**
```json
{
  "block_parsing": {
    "parser_arg": ["latest"],
    "parser_func": "DEFAULT"
  }
}
```

This is correct for most REST endpoints because the real block extraction logic lives in the **parse directives** (`GET_BLOCKNUM`, `GET_BLOCK_BY_NUM`), not in per-endpoint `block_parsing`.

**When to use each parser in REST specs:**

| Endpoint Type | Parser | Example |
|---------------|--------|---------|
| Returns current chain state | `DEFAULT` | `/accounts/{address}`, `/pools`, `/blocks/latest` |
| Historical data by hash/ID | `DEFAULT` | `/txs/{hash}`, `/blocks/{hash_or_number}` |
| Block/height explicitly in path | `DEFAULT` or `PARSE_DICTIONARY_OR_ORDERED` | `/blocks/by_height/{block_height}` |
| Static/immutable data | `EMPTY` | `/genesis` (never changes) |
| Pure computation, no chain state | `EMPTY` | `/utils/addresses/xpub/{xpub}/{role}/{index}` |
| Mempool/pending data | `DEFAULT` | `/mempool`, `/mempool/{hash}` |

**When `PARSE_DICTIONARY_OR_ORDERED` is used in REST:**

Some REST specs extract block numbers from URL path parameters. This is done by treating path segments as ordered arguments:

```json
// Aptos: /blocks/by_height/{block_height}
{
  "block_parsing": {
    "parser_arg": ["block_height", "=", "0"],
    "parser_func": "PARSE_DICTIONARY_OR_ORDERED"
  }
}
```

**When `PARSE_CANONICAL` is used in REST (response-based):**

Some REST specs extract block information from the response body rather than the request:

```json
// Stellar: /ledgers/{sequence}
{
  "block_parsing": {
    "parser_arg": ["0", "sequence"],
    "parser_func": "PARSE_CANONICAL"
  }
}
```

**Key insight:** For REST APIs, parse directives do the heavy lifting for block tracking. Per-endpoint `block_parsing` primarily tells Lava whether to associate the request with the latest block (`DEFAULT`) or no block at all (`EMPTY`).

### 3. Category Classification
**Determine API Characteristics**:

```json
{
  "category": {
    "deterministic": true,
    "stateful": 0,
    "hanging_api": false
  }
}
```

**Guidelines**:

**`deterministic: true`** - Use when:
- API returns same result for same block
- Examples: getBlock, getBalance, call (at specific block)
- Enables data reliability checks

**`deterministic: false`** - Use when:
- Result varies between calls
- Examples: getAccounts, mining, syncing, pending transactions

> **Subscriptions are NOT a `category` flag.** A method is a subscription because its collection has a `SUBSCRIBE`/`UNSUBSCRIBE` parse directive whose `api_name` is that method (see `phase3.4-parse-directives-and-extensions.md`). Do NOT emit `category.subscription` or `category.local` — both fields were removed from the model.

**`stateful: 1`** - Use ONLY when the API **submits** a transaction or otherwise modifies chain state. Read-only helpers that prepare, simulate, or inspect transactions are **not** stateful even if they take a transaction-shaped argument.

| Method (Ethereum-family) | Stateful? | Why |
|---|---|---|
| `eth_sendRawTransaction`, `eth_sendTransaction`, `eth_sendRawTransactionSync` | `1` | Submits/broadcasts a tx |
| `eth_fillTransaction` | `0` | Read-only — populates missing fields, returns the encoded tx; no submission |
| `eth_call`, `eth_estimateGas`, `eth_simulateV1` | `0` | Pure simulation, no state change |
| `debug_traceCall` | `0` | Trace simulation only |

**Common mistake:** marking `eth_fillTransaction` (and similar `*_fill*` / `*_prepare*` helpers) as `stateful: 1` because the name suggests a tx flow. Always check the method's **effect**, not its argument shape — read the chain's docs for whether the call broadcasts.

Note: Use integer 1, not boolean.

**`hanging_api: true`** - Use when the API waits for a new block / tx receipt before returning (often paired with `stateful: 1` for synchronous tx submission).

When `hanging_api: true`, the relay timeout is computed as `max(1s, CU * 100ms) + averageBlockTime * 2`, **unless `timeout_ms` is set** — in which case `timeout_ms` replaces the CU-based portion. On fast chains (`average_block_time` < 1s), the hanging-bonus alone is too small a buffer to wait for tx finality, and relying on the CU-derived default is fragile.

**Rule:** when you set `hanging_api: true`, also set an explicit `timeout_ms` that reflects how long the upstream node may legitimately block:

```json
{
  "name": "eth_sendRawTransactionSync",
  "compute_units": 100,
  "timeout_ms": 10000,
  "category": {
    "deterministic": false,
    "stateful": 1,
    "hanging_api": true
  }
}
```

Examples: `eth_sendTransaction` (waits for confirmation), `eth_sendRawTransactionSync` on Monad, `broadcast_tx_commit` on Cosmos, Bitcoin's `sendrawtransaction`.

### 3.5 Node-operator controls must never ship enabled in a base collection

> ⛔ **Before enabling a method, ask what it acts on: the chain, or the node?**
> A method that mutates the *node* — its view of consensus, its peers, its
> mining, its keys — is an operator control, not a relay. Never `enabled: true`
> in a collection with `add_on: ""`.

The distinction is not "does it write". `sendrawtransaction` writes, and it is a
perfectly good relay: it submits to the *chain*, every node converges, and the
effect is the caller's own. An operator control changes one node's behaviour and
leaves it changed — so the damage is never scoped to the caller. The provider
then serves the mutated state to **every consumer paired with it**, and the
chain-tracker sees a provider that has stopped behaving.

`add_on: ""` is what makes it baseline: there is no opt-in boundary a provider
can decline, and importing specs inherit the whole collection through
`CombineCollections`. A method behind a *named* add-on is a different situation —
the provider chose to serve it.

**The classes, and why each one bites:**

| class | examples | what a consumer gets |
|---|---|---|
| consensus view | `finalizeblock`, `parkblock`, `invalidateblock`, `reconsiderblock`, `preciousblock`, `debug_setHead` | moves or pins the provider's idea of the real chain |
| peering | `addnode`, `disconnectnode`, `setban`, `admin_addPeer`, `admin_removePeer` | isolates the node so its tip goes stale — no consensus tampering needed |
| lifecycle | `stop`, `admin_stopHTTP`, `admin_stopWS`, `admin_stopRPC` | turns off the surface the provider is paid to serve |
| mining | `miner_start`, `miner_stop`, `miner_setEtherbase` | redirects rewards, or halts block production |
| keys | the whole `personal_*` namespace | accounts and signing **on the provider's node** |
| regtest mining | `generate`, `generatetoaddress`, `setgenerate` | fabricates blocks; harmless on regtest, which is not what a mainnet spec serves |

**Worked example — measured, not argued.** `bch.json` served BCHN's
`parkblock` / `unparkblock` / `finalizeblock` from `BCH`'s base collection,
enabled, at 10 CU (MAG-3644). Reproduced on BCHN 29.1.0 with two peered regtest
nodes:

- `parkblock` on the tip does **nothing** — the node logs `Unpark chain up to
  block … as it has accumulated enough PoW` and carries on. Auto-unparking makes
  it self-healing on the most-work chain.
- `finalizeblock` on the tip **strands the node permanently.** The provider held
  at height 11 while the network reached 20, rejecting every honest header with
  `bad-header-finalization (code 259)` — and scoring its peers as misbehaving
  until it banned them. One unauthenticated relay call, and the provider
  partitions itself from the network until an operator intervenes.

Two lessons. First, the severity lives in the *mechanism*, so check it rather
than reasoning from the method name — the obvious-looking candidate was the
harmless one. Second, this reached `main` and two review passes missed it; it
was only caught when a reviewer was bumped to `opus`. Do not rely on review.

**Do not use a probe to decide this.** A vendor gateway (Tatum, Blockdaemon)
whitelists methods and answers `-32601`, and geth has deprecated `personal_*`
entirely — so a probe looks clean while a self-hosted node serves the method
happily. Per the free-tier rule a gateway's `-32601` is not evidence for
disabling, and the converse holds too: it is not evidence of safety. The
evidence is what the method does on a node that implements it.

**The gate:**

```bash
bash .claude/skills/create-spec/scripts/check_node_admin_rpcs.sh <chain>.json
```

Runs per changed spec in `spec_guards.yml`. Resolve a finding by **disabling**
(`enabled: false` plus a positive-evidence row in the PR body's justification
table) or by **gating** it behind a named `add_on`. A third option,
`node_admin_baseline.txt`, exists only for pre-existing exposure being fixed
under its own ticket — a row there is a debt record, and adding one for a new
finding defeats the gate.

Deliberately **out of scope**: `submitblock` / `submitblocklight`. Block
submission changes *chain* state, not the node's view of it, and is arguably
legitimate for a mining consumer. Its `stateful` / `deterministic` typing is a
separate question, handled by the method-schema gate.

### 4. Optional Advanced Configuration

**Timeout for slow operations**:
```json
{
  "timeout_ms": 20000
}
```

**Custom parsing for specific fields**:
```json
{
  "parsers": [
    {
      "parse_path": ".params.[0].fromBlock",
      "parse_type": "BLOCK_EARLIEST"
    },
    {
      "parse_path": ".params.[0].toBlock",
      "parse_type": "BLOCK_LATEST"
    }
  ]
}
```

---

## Appended from SPEC_GUIDE.md §REST API Block-Parsing Narrative (lines 779-834)

##### REST API Block Parsing Conventions

REST APIs handle block parsing differently from JSON-RPC. In JSON-RPC, block references are in `params[]` and can be extracted with `PARSE_BY_ARG`. In REST APIs, block references are typically in URL path segments (e.g., `/blocks/{height}`), which standard parsers cannot extract from the path template.

**The dominant pattern (~90% of REST endpoints) is `DEFAULT`:**
```json
{
  "block_parsing": {
    "parser_arg": ["latest"],
    "parser_func": "DEFAULT"
  }
}
```

This is correct for most REST endpoints because the real block extraction logic lives in the **parse directives** (`GET_BLOCKNUM`, `GET_BLOCK_BY_NUM`), not in per-endpoint `block_parsing`.

**When to use each parser in REST specs:**

| Endpoint Type | Parser | Example |
|---------------|--------|---------|
| Returns current chain state | `DEFAULT` | `/accounts/{address}`, `/pools`, `/blocks/latest` |
| Historical data by hash/ID | `DEFAULT` | `/txs/{hash}`, `/blocks/{hash_or_number}` |
| Block/height explicitly in path | `DEFAULT` or `PARSE_DICTIONARY_OR_ORDERED` | `/blocks/by_height/{block_height}` |
| Static/immutable data | `EMPTY` | `/genesis` (never changes) |
| Pure computation, no chain state | `EMPTY` | `/utils/addresses/xpub/{xpub}/{role}/{index}` |
| Mempool/pending data | `DEFAULT` | `/mempool`, `/mempool/{hash}` |

**When `PARSE_DICTIONARY_OR_ORDERED` is used in REST:**

Some REST specs extract block numbers from URL path parameters. This is done by treating path segments as ordered arguments:

```json
// Aptos: /blocks/by_height/{block_height}
{
  "block_parsing": {
    "parser_arg": ["block_height", "=", "0"],
    "parser_func": "PARSE_DICTIONARY_OR_ORDERED"
  }
}
```

**When `PARSE_CANONICAL` is used in REST (response-based):**

Some REST specs extract block information from the response body rather than the request:

```json
// Stellar: /ledgers/{sequence}
{
  "block_parsing": {
    "parser_arg": ["0", "sequence"],
    "parser_func": "PARSE_CANONICAL"
  }
}
```

**Key insight:** For REST APIs, parse directives do the heavy lifting for block tracking. Per-endpoint `block_parsing` primarily tells Lava whether to associate the request with the latest block (`DEFAULT`) or no block at all (`EMPTY`).

END-OF-PHASE3.2-SENTINEL
