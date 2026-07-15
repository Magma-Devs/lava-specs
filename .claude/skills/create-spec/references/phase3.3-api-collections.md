# Phase 3.3: Create API Collections

**Objective**: Group APIs by interface and add-on type

**IMPORTANT NOTE:** If you are importing from another spec (e.g., ETH1), you do NOT need to define collections that you want to inherit as-is. Review Step 3.1a to understand automatic vs override inheritance before creating collections.

**When to Define Collections:**
- You need to add chain-specific APIs to the main collection
- You need to override/customize inherited APIs (change CU, disable APIs, etc.)
- You need to create a new chain-specific add-on (e.g., Arbitrum's `arbtrace`)
- You are NOT importing from another spec (must define everything)

**When NOT to Define Collections:**
- You want to inherit all APIs from parent spec unchanged (e.g., debug, trace from ETH1)
- The parent spec already has what you need

**Basic Structure**:
```json
{
  "api_collections": [
    {
      "enabled": true,
      "collection_data": {
        "api_interface": "jsonrpc",
        "internal_path": "",
        "type": "POST",
        "add_on": ""
      },
      "apis": [ /* API definitions */ ],
      "headers": [],
      "inheritance_apis": [],
      "parse_directives": [ /* See Step 3.4 */ ],
      "verifications": [ /* See Step 2.3 */ ],
      "extensions": [ /* See Step 3.5 */ ]
    }
  ]
}
```

**Multiple Collections Pattern** (Only for base specs like ETH1, or when customizing):
```json
{
  "api_collections": [
    {
      "enabled": true,
      "collection_data": {
        "api_interface": "jsonrpc",
        "internal_path": "",
        "type": "POST",
        "add_on": ""
      },
      "apis": [ /* Standard APIs */ ]
    },
    {
      "enabled": true,
      "collection_data": {
        "api_interface": "jsonrpc",
        "internal_path": "",
        "type": "POST",
        "add_on": "debug"
      },
      "apis": [ /* Debug APIs */ ]
    },
    {
      "enabled": true,
      "collection_data": {
        "api_interface": "jsonrpc",
        "internal_path": "",
        "type": "POST",
        "add_on": "trace"
      },
      "apis": [ /* Trace APIs */ ]
    }
  ]
}
```

**⚠️ NOTE:** If you're inheriting from ETH1 and want debug/trace as-is, **DO NOT** define debug/trace collections. They'll be inherited automatically. Only define them if you need to customize.

**Example: Inheriting Chain (Most Common)**
```json
{
  "index": "FANTOM",
  "imports": ["ETH1"],  // Gets ALL ETH1 collections automatically
  "api_collections": [
    {
      "enabled": true,
      "collection_data": {
        "api_interface": "jsonrpc",
        "internal_path": "",
        "type": "POST",
        "add_on": ""  // Only defining main collection with Fantom-specific APIs
      },
      "apis": [
        {"name": "ftm_currentEpoch", ...},
        {"name": "dag_getEvent", ...}
        // ETH1's standard APIs (eth_*) are inherited and merged here
      ]
    },
    {
      "enabled": true,
      "collection_data": {
        "api_interface": "jsonrpc",
        "internal_path": "",
        "type": "POST",
        "add_on": "trace"  // Defining trace to ADD Fantom-specific trace APIs
      },
      "apis": [
        {"name": "trace_get", ...}  // Fantom-specific
        // ETH1's trace APIs are ALSO inherited and merged here
      ]
    }
    // NO debug collection defined = inherits ALL debug APIs from ETH1 automatically
  ]
}
```

**Version-Specific Collections** (e.g., StarkNet):
```json
{
  "api_collections": [
    {
      "enabled": true,
      "collection_data": {
        "api_interface": "jsonrpc",
        "internal_path": "/rpc/v0_8",
        "type": "POST",
        "add_on": ""
      },
      "inheritance_apis": [
        {
          "api_interface": "jsonrpc",
          "internal_path": "",
          "type": "POST",
          "add_on": ""
        }
      ]
    },
    {
      "enabled": true,
      "collection_data": {
        "api_interface": "jsonrpc",
        "internal_path": "/rpc/v0_9",
        "type": "POST",
        "add_on": ""
      },
      "inheritance_apis": [
        {
          "api_interface": "jsonrpc",
          "internal_path": "",
          "type": "POST",
          "add_on": ""
        }
      ]
    }
  ]
}
```

## Step 3.3a: Configure Headers
**Objective**: Define how HTTP headers are handled between clients, Lava, and providers

Headers are configured at the collection level. Each header has a `name`, a `kind` that controls its behavior, and an optional `value`.

### Header Kinds Reference

| Kind | Direction | Purpose | Example |
|------|-----------|---------|---------|
| `pass_send` | Client → Provider | Forward a client header to the provider unchanged | API keys, auth tokens |
| `pass_override` | Lava → Provider | Set a fixed header value, ignoring the client's value | Content-type for POST |
| `pass_both` | Bidirectional | Forward to provider AND read from response into metadata | Block height tracking (Cosmos gRPC) |
| `pass_reply` | Provider → Client | Pass a response header back to the client | Ledger version (Aptos) |
| `pass_ignore` | — | Explicitly ignore this header | Legacy/deprecated headers |

### Authentication Headers

When wrapping APIs that require authentication (third-party providers, or any endpoint requiring an API key), use `pass_send` to forward the client's credentials:

```json
{
  "headers": [
    {"name": "project_id", "kind": "pass_send"}
  ]
}
```

The consumer includes the header in their request, and Lava forwards it to the provider. Lava does not store or interpret the value.

**Real-world examples:**
- **Cardano/Blockfrost**: `project_id` with `pass_send`

### Content-Type Headers

For REST POST collections, use `pass_override` to set the required content-type:

```json
{
  "headers": [
    {"name": "content-type", "kind": "pass_override", "value": "application/cbor"}
  ]
}
```

**Real-world examples:**
- **Cardano/Blockfrost**: `application/cbor` for transaction submission
- **Stellar**: `application/x-www-form-urlencoded` for POST endpoints

### Mixed Content-Type Handling (IMPORTANT)

A `pass_override` for content-type applies to **ALL endpoints in that collection**. If different POST endpoints require different content-types, you have two options:

**Option A: Separate collections** (recommended) — put endpoints with different content-types in separate POST collections with different `add_on` values:
```json
{
  "api_collections": [
    {
      "collection_data": {"type": "POST", "add_on": ""},
      "headers": [{"name": "content-type", "kind": "pass_override", "value": "application/cbor"}],
      "apis": [{"name": "/tx/submit", ...}]
    },
    {
      "collection_data": {"type": "POST", "add_on": "evaluate"},
      "headers": [{"name": "content-type", "kind": "pass_override", "value": "application/json"}],
      "apis": [{"name": "/utils/txs/evaluate/utxos", ...}]
    }
  ]
}
```

**Option B: Use `pass_send`** — let the client set the content-type themselves instead of overriding it. Only use this if you trust consumers to set the correct value.

**Common mistake:** Applying a blanket `pass_override` for content-type across a POST collection when one endpoint requires a different content-type. This silently breaks that endpoint.

### Response Headers

Use `pass_reply` to forward provider response headers back to the client. This is useful when the provider includes chain-state metadata in response headers:

```json
{
  "headers": [
    {"name": "x-aptos-block-height", "kind": "pass_reply"},
    {"name": "x-aptos-ledger-version", "kind": "pass_reply"},
    {"name": "x-aptos-ledger-timestampusec", "kind": "pass_ignore"}
  ]
}
```

### Block Height Metadata Headers

For gRPC APIs (especially Cosmos SDK chains), use `pass_both` with `SET_LATEST_IN_METADATA` to track block height through response headers:

```json
{
  "headers": [
    {
      "name": "x-cosmos-block-height",
      "kind": "pass_both",
      "function_tag": "SET_LATEST_IN_METADATA"
    }
  ]
}
```

## Step 3.3b: Handling Disabled and Deprecated APIs
**Objective**: Correctly exclude or disable APIs that should not be served

### Excluding APIs Entirely

Do NOT include an API in the spec if:
- It is **deprecated** by the API provider (use the non-deprecated replacement)
- It is **platform-specific** and not chain data (health checks, usage metrics, admin endpoints)
- It is served on a **different server/domain** (e.g., IPFS endpoints on `ipfs.blockfrost.io`)
- It is a **duplicate/alias** of another included endpoint

### Disabling Inherited APIs

When importing from a parent spec, you may need to disable specific APIs that don't work on your chain. Define the collection and set `"enabled": false` on individual APIs:

```json
// Evmos pattern: disable specific debug APIs that don't work
{
  "collection_data": {"api_interface": "jsonrpc", "type": "POST", "add_on": "debug"},
  "apis": [
    {"name": "debug_getRawBlock", "enabled": false, "compute_units": 1},
    {"name": "debug_getRawHeader", "enabled": false, "compute_units": 1},
    {"name": "debug_traceCall", "enabled": false, "compute_units": 1}
    // All other debug APIs inherited from ETH1 as-is
  ]
}
```

### Disabling Entire Add-on Collections

If your chain doesn't support an entire add-on category (e.g., trace, bundler), disable the whole collection:

```json
// Celo pattern: disable entire inherited collections
{
  "enabled": false,
  "collection_data": {"api_interface": "jsonrpc", "type": "POST", "add_on": "trace"},
  "apis": []
},
{
  "enabled": false,
  "collection_data": {"api_interface": "jsonrpc", "type": "POST", "add_on": "bundler"},
  "apis": []
}
```

### Replacing Inherited Collections with Custom Paths

If your chain uses a different RPC path than the parent, disable inherited collections and define new ones:

```json
// Avalanche C-Chain pattern: replace parent collections with custom path
{
  "enabled": false,
  "collection_data": {"api_interface": "jsonrpc", "type": "POST", "add_on": ""}
  // Disables parent's main collection
},
{
  "enabled": true,
  "collection_data": {"api_interface": "jsonrpc", "internal_path": "/C/rpc", "type": "POST", "add_on": ""},
  "apis": [/* Chain-specific APIs */]
}
```

---

## Appended from SPEC_GUIDE.md §Mixed Content-Type Handling & SET_LATEST_IN_METADATA (lines 1063-1165)

#### Step 3.3a: Configure Headers
**Objective**: Define how HTTP headers are handled between clients, Lava, and providers

Headers are configured at the collection level. Each header has a `name`, a `kind` that controls its behavior, and an optional `value`.

##### Header Kinds Reference

| Kind | Direction | Purpose | Example |
|------|-----------|---------|---------|
| `pass_send` | Client → Provider | Forward a client header to the provider unchanged | API keys, auth tokens |
| `pass_override` | Lava → Provider | Set a fixed header value, ignoring the client's value | Content-type for POST |
| `pass_both` | Bidirectional | Forward to provider AND read from response into metadata | Block height tracking (Cosmos gRPC) |
| `pass_reply` | Provider → Client | Pass a response header back to the client | Ledger version (Aptos) |
| `pass_ignore` | — | Explicitly ignore this header | Legacy/deprecated headers |

##### Authentication Headers

When wrapping APIs that require authentication (third-party providers, or any endpoint requiring an API key), use `pass_send` to forward the client's credentials:

```json
{
  "headers": [
    {"name": "project_id", "kind": "pass_send"}
  ]
}
```

The consumer includes the header in their request, and Lava forwards it to the provider. Lava does not store or interpret the value.

**Real-world examples:**
- **Cardano/Blockfrost**: `project_id` with `pass_send`

##### Content-Type Headers

For REST POST collections, use `pass_override` to set the required content-type:

```json
{
  "headers": [
    {"name": "content-type", "kind": "pass_override", "value": "application/cbor"}
  ]
}
```

**Real-world examples:**
- **Cardano/Blockfrost**: `application/cbor` for transaction submission
- **Stellar**: `application/x-www-form-urlencoded` for POST endpoints

##### Mixed Content-Type Handling (IMPORTANT)

A `pass_override` for content-type applies to **ALL endpoints in that collection**. If different POST endpoints require different content-types, you have two options:

**Option A: Separate collections** (recommended) — put endpoints with different content-types in separate POST collections with different `add_on` values:
```json
{
  "api_collections": [
    {
      "collection_data": {"type": "POST", "add_on": ""},
      "headers": [{"name": "content-type", "kind": "pass_override", "value": "application/cbor"}],
      "apis": [{"name": "/tx/submit", ...}]
    },
    {
      "collection_data": {"type": "POST", "add_on": "evaluate"},
      "headers": [{"name": "content-type", "kind": "pass_override", "value": "application/json"}],
      "apis": [{"name": "/utils/txs/evaluate/utxos", ...}]
    }
  ]
}
```

**Option B: Use `pass_send`** — let the client set the content-type themselves instead of overriding it. Only use this if you trust consumers to set the correct value.

**Common mistake:** Applying a blanket `pass_override` for content-type across a POST collection when one endpoint requires a different content-type. This silently breaks that endpoint.

##### Response Headers

Use `pass_reply` to forward provider response headers back to the client. This is useful when the provider includes chain-state metadata in response headers:

```json
{
  "headers": [
    {"name": "x-aptos-block-height", "kind": "pass_reply"},
    {"name": "x-aptos-ledger-version", "kind": "pass_reply"},
    {"name": "x-aptos-ledger-timestampusec", "kind": "pass_ignore"}
  ]
}
```

##### Block Height Metadata Headers

For gRPC APIs (especially Cosmos SDK chains), use `pass_both` with `SET_LATEST_IN_METADATA` to track block height through response headers:

```json
{
  "headers": [
    {
      "name": "x-cosmos-block-height",
      "kind": "pass_both",
      "function_tag": "SET_LATEST_IN_METADATA"
    }
  ]
}
```

---

## Appended from SPEC_GUIDE.md §`enabled: false` Foot-Gun (lines 1167-1229)

#### Step 3.3b: Handling Disabled and Deprecated APIs
**Objective**: Correctly exclude or disable APIs that should not be served

##### Excluding APIs Entirely

Do NOT include an API in the spec if:
- It is **deprecated** by the API provider (use the non-deprecated replacement)
- It is **platform-specific** and not chain data (health checks, usage metrics, admin endpoints)
- It is served on a **different server/domain** (e.g., IPFS endpoints on `ipfs.blockfrost.io`)
- It is a **duplicate/alias** of another included endpoint

##### Disabling Inherited APIs

When importing from a parent spec, you may need to disable specific APIs that don't work on your chain. Define the collection and set `"enabled": false` on individual APIs:

```json
// Evmos pattern: disable specific debug APIs that don't work
{
  "collection_data": {"api_interface": "jsonrpc", "type": "POST", "add_on": "debug"},
  "apis": [
    {"name": "debug_getRawBlock", "enabled": false, "compute_units": 1},
    {"name": "debug_getRawHeader", "enabled": false, "compute_units": 1},
    {"name": "debug_traceCall", "enabled": false, "compute_units": 1}
    // All other debug APIs inherited from ETH1 as-is
  ]
}
```

##### Disabling Entire Add-on Collections

If your chain doesn't support an entire add-on category (e.g., trace, bundler), disable the whole collection:

```json
// Celo pattern: disable entire inherited collections
{
  "enabled": false,
  "collection_data": {"api_interface": "jsonrpc", "type": "POST", "add_on": "trace"},
  "apis": []
},
{
  "enabled": false,
  "collection_data": {"api_interface": "jsonrpc", "type": "POST", "add_on": "bundler"},
  "apis": []
}
```

##### Replacing Inherited Collections with Custom Paths

If your chain uses a different RPC path than the parent, disable inherited collections and define new ones:

```json
// Avalanche C-Chain pattern: replace parent collections with custom path
{
  "enabled": false,
  "collection_data": {"api_interface": "jsonrpc", "type": "POST", "add_on": ""}
  // Disables parent's main collection
},
{
  "enabled": true,
  "collection_data": {"api_interface": "jsonrpc", "internal_path": "/C/rpc", "type": "POST", "add_on": ""},
  "apis": [/* Chain-specific APIs */]
}
```

END-OF-PHASE3.3-SENTINEL
