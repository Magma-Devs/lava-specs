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
