# Phase 3.1: Determine Inheritance

**Objective**: Decide if the spec should inherit from existing specs

**Decision Tree**:
- EVM-compatible chain? → Consider inheriting from `ETH1`
- Cosmos SDK chain? → Consider inheriting from `COSMOSSDK` or specific version
- Specialized version of existing chain? → Inherit from parent

**If Inheriting**:
```json
{
  "index": "POLYGON",
  "imports": ["ETH1"],
  "api_collections": [
    {
      "collection_data": {
        "api_interface": "jsonrpc",
        "internal_path": "",
        "type": "POST",
        "add_on": ""
      },
      "apis": [
        // Only chain-specific APIs here
      ]
    }
  ]
}
```

**If Not Inheriting**:
```json
{
  "index": "NEWCHAIN",
  "api_collections": [
    {
      "collection_data": {
        "api_interface": "jsonrpc",
        "internal_path": "",
        "type": "POST",
        "add_on": ""
      },
      "apis": [
        // All APIs must be defined here
      ]
    }
  ]
}
```

## Step 3.1a: Understanding Collection Inheritance (CRITICAL)
**Objective**: Understand exactly how spec inheritance works at the collection level

This is one of the most important concepts for creating specs efficiently. Inheritance happens at the **API Collection** level, not just at the spec level.

### How Collection Matching Works

Collections are matched by their `CollectionData`, which consists of:

```json
{
  "api_interface": "jsonrpc",  // Must match
  "internal_path": "",          // Must match
  "type": "POST",               // Must match
  "add_on": "debug"             // Must match - THIS IS KEY
}
```

Two collections are considered "the same" only if **ALL FOUR** fields match exactly. The `add_on` field is particularly important for understanding inheritance.

### Two Inheritance Scenarios

**Scenario A: Automatic Inheritance (Collection NOT Defined in Child)**

When you import a spec (e.g., `"imports": ["ETH1"]`) but **DO NOT** define a matching collection in your child spec:

```json
{
  "index": "BASE",
  "imports": ["ETH1"],
  "api_collections": [
    {
      "collection_data": {
        "api_interface": "jsonrpc",
        "internal_path": "",
        "type": "POST",
        "add_on": ""  // Only defining main collection
      },
      "apis": [/* chain-specific APIs */]
    }
    // NO debug collection defined
    // NO trace collection defined
  ]
}
```

**What happens:**
- ETH1's main collection (`add_on: ""`) is merged with your main collection
- ETH1's debug collection (`add_on: "debug"`) is **automatically appended entirely**
- ETH1's trace collection (`add_on: "trace"`) is **automatically appended entirely**
- ETH1's bundler collection is **automatically appended entirely**

**Result:** Your spec has ALL collections from ETH1 plus your custom APIs.

**Implementation:** This happens in `x/spec/types/spec.go` in the `CombineCollections` function. Collections from parent that don't have a matching `CollectionData` in the child are appended as-is.

**Scenario B: Override Inheritance (Collection Defined in Child)**

When you import a spec and **DO** define a matching collection:

```json
{
  "index": "EVMOS",
  "imports": ["ETH1"],
  "api_collections": [
    {
      "collection_data": {
        "api_interface": "jsonrpc",
        "internal_path": "",
        "type": "POST",
        "add_on": "debug"  // EXPLICITLY DEFINING debug collection
      },
      "apis": [
        {
          "name": "debug_getRawBlock",
          "enabled": false  // Overriding to disable
        },
        {
          "name": "debug_traceTransaction",
          "compute_units": 150,  // Overriding CU
          "enabled": true
        }
      ],
      "verifications": [
        /* Custom verifications */
      ]
    }
  ]
}
```

**What happens:**
- ETH1's debug collection APIs are inherited
- Your explicitly defined APIs **override** the inherited ones (matched by `name`)
- APIs you don't mention are still inherited with ETH1's configuration
- Headers, parse directives, extensions, and verifications are **merged** (not overridden) — see below

**Result:** You have control over specific APIs while still inheriting most of the collection.

**Implementation:** This happens in `x/spec/types/api_collection.go` in the `InheritAllFields` and `CombineWithOthers` functions.

### Non-API Field Merge Behavior (IMPORTANT)

All collection fields use **merge semantics**, not override semantics. This is implemented in `CombineUnique()` (`x/spec/types/combinable.go`). Each field type has a `Differeniator()` that determines how items are matched:

| Field | Merge? | Differentiator | Conflict Behavior |
|-------|--------|----------------|-------------------|
| **APIs** | Yes | `Name` | Child version wins |
| **Headers** | Yes | `Name` | Child version wins |
| **ParseDirectives** | Yes | `FunctionTag` (+ `ApiName` for SUBSCRIBE/UNSUBSCRIBE) | Child version wins |
| **Extensions** | Yes | `Name` | Child version wins |
| **Verifications** | Yes (special) | `Name` | Child inherits parent's `ParseDirective` if its own is nil; `Values` are merged by `Extension` field |

**Key implication: Empty arrays inherit everything.** If the child defines `"headers": []`, all parent headers are still inherited because the empty map has no conflicts. This means:

```json
// This child collection DOES inherit parent's headers, parse_directives, etc.
{
  "collection_data": {"api_interface": "rest", "type": "POST", "add_on": ""},
  "apis": [],
  "headers": [],           // ← Parent headers are MERGED in (not lost)
  "parse_directives": [],  // ← Parent directives are MERGED in
  "extensions": [],        // ← Parent extensions are MERGED in
  "verifications": []      // ← Parent verifications are MERGED in
}
```

**Verification special case:** When a child defines a verification with the same `name` as a parent but with `ParseDirective: null`, the child inherits the parent's `ParseDirective` and merges `Values` (child values take precedence when the `Extension` field matches). This is why testnet specs can override just the `expected_value` of a chain-id verification:

```json
// Child testnet spec — inherits ParseDirective from parent, overrides expected_value
{
  "name": "chain-id",
  "values": [{"expected_value": "1"}]  // Parent's ParseDirective is adopted automatically
}
```

### Practical Examples

**Example 1: Base Chain (Full Automatic Inheritance)**
```bash
# Base only defines main collection
# Result: Gets debug, trace, and bundler add-ons for FREE from ETH1
```

**Example 2: Arbitrum (Custom Add-on + Automatic Inheritance)**
```json
{
  "imports": ["ETH1"],
  "api_collections": [
    {
      "collection_data": {"add_on": ""},
      "apis": [/* custom APIs */]
    },
    {
      "collection_data": {"add_on": "arbtrace"},  // Arbitrum-specific
      "apis": [/* arb_trace APIs */]
    }
    // NO debug defined - gets ETH1's debug automatically
    // NO trace defined - gets ETH1's trace automatically
  ]
}
```

**Example 3: Evmos (Selective Disabling)**
```json
{
  "imports": ["ETH1"],
  "api_collections": [
    {
      "collection_data": {"add_on": "debug"},
      "apis": [
        {"name": "debug_getRawBlock", "enabled": false},
        {"name": "debug_traceTransaction", "enabled": false}
        // All other debug APIs inherited as-is from ETH1
      ]
    }
  ]
}
```
Why? Some debug APIs don't work on Evmos, so they explicitly disable them.

### Decision Matrix: Should You Define a Collection?

| Scenario | Action | Example |
|----------|--------|---------|
| You want ALL parent APIs unchanged | DON'T define the collection | Base importing ETH1 debug |
| You want to disable specific APIs | DEFINE the collection with `enabled: false` | Evmos disabling debug APIs |
| You want to change CU values | DEFINE the collection with custom CU | Optimized chain |
| You want custom verifications | DEFINE the collection with custom verifications | Chain-specific checks |
| You want a chain-specific add-on | DEFINE a NEW collection with unique `add_on` | Arbitrum's arbtrace |
| You want to add new APIs to existing add-on | DEFINE the collection with additional APIs | Fantom's trace APIs |

### Inheritance Audit (MANDATORY before writing the spec)

Inheriting "for free" is a foot-gun: ETH1 inherits ~50 main-collection methods, and your chain may not support all of them (e.g. uncle methods on a BFT chain, filter API on a chain that uses subscriptions, AA / mining / signing on an unhosted RPC). Methods that are inherited but unsupported will be served, fail upstream, and degrade provider QoS — silently — until users notice.

**You must produce an explicit diff between parent collection methods and the chain's documented API list, then disable the methods that don't apply.** Do this BEFORE writing the spec, not after the user reports it.

Concrete procedure:

```bash
# 1. List parent collection methods (per add_on)
jq -r '.proposal.specs[0].api_collections[] | select(.collection_data.add_on == "") | .apis[].name' \
    specs/mainnet-1/specs/<parent>.json | sort > /tmp/parent_main.txt

jq -r '.proposal.specs[0].api_collections[] | select(.collection_data.add_on == "debug") | .apis[].name' \
    specs/mainnet-1/specs/<parent>.json | sort > /tmp/parent_debug.txt

# 2. From the chain's official JSON-RPC docs, write the supported method list to a file:
#    /tmp/chain_supported.txt  (one method per line, sorted)

# 3. Diff: methods to disable = parent ∖ chain_supported
comm -23 /tmp/parent_main.txt /tmp/chain_supported.txt
```

For each method in the diff, decide:

| Reason method isn't supported | Action |
|---|---|
| Chain explicitly documents it as unsupported | Disable with `enabled: false` |
| Method is for a feature the chain doesn't have (uncles in BFT, PoW work, AA bundler, key management, filter API on a subscription-based chain) | Disable |
| Method is in the parent but **not in the chain's docs**, including standard utilities (`net_listening`, `net_peerCount`, `web3_sha3`, `rpc_modules`, `eth_protocolVersion`) | **Probe live RPC** — many strict implementations reject everything not in their published list, even "trivial" ones. See probe procedure below. |
| Method requires WebSocket (`eth_subscribe`, `eth_unsubscribe`) and the chain documents WS support | Keep — HTTP probe will return `-32601`, that's expected. Verify the chain's WS endpoint supports it instead. |
| Method belongs to an inherited add-on (`bundler`, `trace`, etc.) the chain's docs don't list | Disable the **whole add-on collection** in the child by defining it with `"enabled": false` and `"apis": []` (see "Disabling an inherited add-on collection" below). Don't bother per-method. |

**Empirical probe — required for any "kept" method that isn't explicitly in the chain's docs.** Don't trust the heuristic that "standard methods are always supported." Probe each candidate against the chain's public RPC:

```bash
URL=https://<chain-public-rpc>
for m in eth_protocolVersion net_listening net_peerCount rpc_modules web3_sha3; do
    case "$m" in
        web3_sha3) params='["0x68656c6c6f"]' ;;
        *)         params='[]' ;;
    esac
    resp=$(curl -s -m 8 -X POST -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"$m\",\"params\":$params,\"id\":1}" "$URL")
    printf "%-25s  %s\n" "$m" "$resp"
done
```

If the response is `{"error":{"code":-32601,...}}`, the method is **not supported** — disable it. If it returns a `result`, keep it inherited.

When disabling, use the parent's CU value (so the spec validator accepts the override):

```json
{ "name": "eth_getUncleCountByBlockHash", "compute_units": 20, "enabled": false }
```

Show **both** the docs-vs-parent diff AND the empirical probe results in your response so the user can sanity-check before you commit.

### Disabling an inherited add-on collection

If the chain doesn't support an entire inherited add-on (e.g. ETH1's `bundler` or `trace` on a chain whose docs don't list those methods), define the collection in the child with `enabled: false` and an empty `apis: []`:

```json
{
  "enabled": false,
  "collection_data": {
    "api_interface": "jsonrpc",
    "internal_path": "",
    "type": "POST",
    "add_on": "trace"
  },
  "apis": []
}
```

This works because [x/spec/types/expand.go:81-92](x/spec/types/expand.go#L81-L92) routes the child collection through `InheritAllFields` (parent APIs get merged INTO the child collection), but the child's `Enabled: false` flag is **preserved** through the merge. At runtime, [protocol/chainlib/base_chain_parser.go:536](protocol/chainlib/base_chain_parser.go#L536) and the keeper queries skip disabled collections entirely.

**Don't** disable each method individually for this case — that's only needed when you want to keep the collection enabled and turn off specific methods within it (e.g. the `debug` collection pattern, where some methods work and some don't).

> ⚠️ Collection-level `enabled: false` only works because the child **defines** the matching `CollectionData`. If you omit the collection entirely, the parent's enabled version is appended via [`CombineCollections`](x/spec/types/spec.go#L202) and the add-on stays active. So "delete the collection from the child" ≠ "disable it" — you must explicitly define the disabled stub.

### Inherited Extensions & Verifications Audit (per-chain calibration)

Inheritance carries `extensions` and `verifications` from the parent **as-is**. Several of those values are calibrated to the parent's block timing and pruning model and **become wrong silently** when the child's chain is much faster (or has a different pruning policy).

The two ETH1-inherited values that almost always need recalibration on fast chains:

**1. `archive` extension `rule.block`** — distance (in blocks) from latest at which a request is routed to archive providers. ETH1 inherits `127`, calibrated for 12s blocks (~25 minutes). On a 400ms-block chain, 127 blocks is ~50 seconds — practically every read older than a minute would route to archive, defeating the regular pruned tier.

**2. `pruning` verification `latest_distance`** — minimum number of blocks a non-archive provider must retain (verified via `GET_EARLIEST_BLOCK`). ETH1 inherits `128`. A non-archive Monad node typically retains hours/days of blocks, but the verification only requires ~51s of history — too lax to mean anything.

**Rule of thumb:** if `average_block_time < 6000ms` AND you `imports: ["ETH1"]`, you must explicitly override the main collection to set chain-appropriate `extensions[archive].rule.block` and `verifications[pruning].values[0].latest_distance`. Pick values that map to a meaningful **time window**, not a block count copied from ETH1.

Reference points for `archive.rule.block` (≈ time window before requests route to archive):

| Chain | block_time | archive rule | ≈ time window |
|---|---|---|---|
| Ethereum (ETH1) | 12000ms | 127 | ~25 min |
| Avalanche-C | 2000ms | 127 | ~4 min |
| Aptos | 250ms | 427500 | ~30 hours |

Pick a value such that `block * average_block_time` is on the order of **tens of minutes to hours**, matching how long a typical pruned node on the target chain actually retains state.

**How to override** when child inherits parent's main collection — define the main collection in the child and supply your own `extensions` and `verifications` block (these merge by `name`, so the inherited entries are replaced, not appended):

```json
{
  "imports": ["ETH1"],
  "api_collections": [
    {
      "collection_data": {"api_interface": "jsonrpc", "type": "POST", "add_on": ""},
      "apis": [/* chain-specific APIs */],
      "verifications": [
        {"name": "chain-id", "values": [{"expected_value": "0x8f"}]},
        {
          "name": "pruning",
          "parse_directive": {"function_tag": "GET_EARLIEST_BLOCK"},
          "values": [
            {"latest_distance": 7200},       // ← chain-appropriate, not 128
            {"extension": "archive", "expected_value": "0x0"}
          ]
        }
      ],
      "extensions": [
        {"name": "archive", "cu_multiplier": 5, "rule": {"block": 7200}}  // ← chain-appropriate
      ]
    }
  ]
}
```

If you cannot determine a chain-appropriate value from docs, **ask the user** (or measure the chain's actual pruning depth via `eth_getBlockByNumber("earliest")` against a known non-archive node) — do not silently inherit the ETH1 value.

### Chain-specific methods audit (additions, not just removals)

The Inheritance Audit above checks for parent methods to **disable**. Equally important: the chain may add **new methods** that the parent doesn't have, and inheriting alone won't bring those in. Common categories of additions:

- `admin_*` — node management/monitoring (e.g. Monad's `admin_ethCallStatistics`)
- `txpool_*` — chain-specific mempool views (e.g. `txpool_statusByAddress`, `txpool_statusByHash`)
- Sync variants of standard methods (e.g. `eth_sendRawTransactionSync`)
- Chain-renamed parent methods (e.g. some chains expose `eth_getBlockReceipts` only)

Procedure: read the chain's full JSON-RPC reference page end-to-end and diff the listed method names against the parent's method list **plus** the methods you've already added to the child. Anything in the chain's docs that's not in either set is a missing entry — add it.

### Common Mistakes to Avoid

❌ **MISTAKE 1:** Manually copying all debug APIs when you just want them as-is
```json
// DON'T DO THIS if you want ETH1's debug unchanged:
{
  "collection_data": {"add_on": "debug"},
  "apis": [
    {"name": "debug_traceBlock", "compute_units": 20, ...},
    {"name": "debug_traceTransaction", "compute_units": 100, ...},
    // ... manually copying all 11 APIs
  ]
}
// Just omit the collection entirely and inherit automatically!
```

❌ **MISTAKE 2:** Thinking inheritance is all-or-nothing
```
Inheritance is per-collection based on CollectionData matching!
```

❌ **MISTAKE 3:** Not understanding that `add_on` field determines collection identity
```json
// These are DIFFERENT collections (won't merge):
{"add_on": ""}      // Main collection
{"add_on": "debug"} // Debug collection
{"add_on": "trace"} // Trace collection
```

✅ **BEST PRACTICE:** Only define collections when you need to customize them. Let automatic inheritance handle the rest.

### Implementation Reference

For those interested in the code:

1. **Collection Matching:** `proto/lavanet/lava/spec/api_collection.proto` defines `CollectionData`
2. **Inheritance Logic:** `x/spec/types/expand.go` - `DoExpandSpec` function (lines 13-101)
3. **Collection Combining:** `x/spec/types/spec.go` - `CombineCollections` function (lines 202-243)
4. **API Merging:** `x/spec/types/api_collection.go` - `InheritAllFields` and `CombineWithOthers` functions
5. **Combinable Interface:** `x/spec/types/combinable.go` - defines how APIs, headers, verifications, etc. are merged

**Algorithm Summary:**
1. Parse parent specs recursively (DFS)
2. Group parent collections by `CollectionData` (including `add_on`)
3. For each child collection: merge with matching parent collections
4. For leftover parent collections (no match in child): append entirely to child spec

---

## Appended from SPEC_GUIDE.md §Collection Inheritance Mechanics (lines 438-677)


#### Step 3.1a: Understanding Collection Inheritance (CRITICAL)
**Objective**: Understand exactly how spec inheritance works at the collection level

This is one of the most important concepts for creating specs efficiently. Inheritance happens at the **API Collection** level, not just at the spec level.

##### How Collection Matching Works

Collections are matched by their `CollectionData`, which consists of:

```json
{
  "api_interface": "jsonrpc",  // Must match
  "internal_path": "",          // Must match
  "type": "POST",               // Must match
  "add_on": "debug"             // Must match - THIS IS KEY
}
```

Two collections are considered "the same" only if **ALL FOUR** fields match exactly. The `add_on` field is particularly important for understanding inheritance.

##### Two Inheritance Scenarios

**Scenario A: Automatic Inheritance (Collection NOT Defined in Child)**

When you import a spec (e.g., `"imports": ["ETH1"]`) but **DO NOT** define a matching collection in your child spec:

```json
{
  "index": "BASE",
  "imports": ["ETH1"],
  "api_collections": [
    {
      "collection_data": {
        "api_interface": "jsonrpc",
        "internal_path": "",
        "type": "POST",
        "add_on": ""  // Only defining main collection
      },
      "apis": [/* chain-specific APIs */]
    }
    // NO debug collection defined
    // NO trace collection defined
  ]
}
```

**What happens:**
- ETH1's main collection (`add_on: ""`) is merged with your main collection
- ETH1's debug collection (`add_on: "debug"`) is **automatically appended entirely**
- ETH1's trace collection (`add_on: "trace"`) is **automatically appended entirely**
- ETH1's bundler collection is **automatically appended entirely**

**Result:** Your spec has ALL collections from ETH1 plus your custom APIs.

**Implementation:** This happens in `x/spec/types/spec.go` in the `CombineCollections` function. Collections from parent that don't have a matching `CollectionData` in the child are appended as-is.

**Scenario B: Override Inheritance (Collection Defined in Child)**

When you import a spec and **DO** define a matching collection:

```json
{
  "index": "EVMOS",
  "imports": ["ETH1"],
  "api_collections": [
    {
      "collection_data": {
        "api_interface": "jsonrpc",
        "internal_path": "",
        "type": "POST",
        "add_on": "debug"  // EXPLICITLY DEFINING debug collection
      },
      "apis": [
        {
          "name": "debug_getRawBlock",
          "enabled": false  // Overriding to disable
        },
        {
          "name": "debug_traceTransaction",
          "compute_units": 150,  // Overriding CU
          "enabled": true
        }
      ],
      "verifications": [
        /* Custom verifications */
      ]
    }
  ]
}
```

**What happens:**
- ETH1's debug collection APIs are inherited
- Your explicitly defined APIs **override** the inherited ones (matched by `name`)
- APIs you don't mention are still inherited with ETH1's configuration
- Headers, parse directives, extensions, and verifications are **merged** (not overridden) — see below

**Result:** You have control over specific APIs while still inheriting most of the collection.

**Implementation:** This happens in `x/spec/types/api_collection.go` in the `InheritAllFields` and `CombineWithOthers` functions.

##### Non-API Field Merge Behavior (IMPORTANT)

All collection fields use **merge semantics**, not override semantics. This is implemented in `CombineUnique()` (`x/spec/types/combinable.go`). Each field type has a `Differeniator()` that determines how items are matched:

| Field | Merge? | Differentiator | Conflict Behavior |
|-------|--------|----------------|-------------------|
| **APIs** | Yes | `Name` | Child version wins |
| **Headers** | Yes | `Name` | Child version wins |
| **ParseDirectives** | Yes | `FunctionTag` (+ `ApiName` for SUBSCRIBE/UNSUBSCRIBE) | Child version wins |
| **Extensions** | Yes | `Name` | Child version wins |
| **Verifications** | Yes (special) | `Name` | Child inherits parent's `ParseDirective` if its own is nil; `Values` are merged by `Extension` field |

**Key implication: Empty arrays inherit everything.** If the child defines `"headers": []`, all parent headers are still inherited because the empty map has no conflicts. This means:

```json
// This child collection DOES inherit parent's headers, parse_directives, etc.
{
  "collection_data": {"api_interface": "rest", "type": "POST", "add_on": ""},
  "apis": [],
  "headers": [],           // ← Parent headers are MERGED in (not lost)
  "parse_directives": [],  // ← Parent directives are MERGED in
  "extensions": [],        // ← Parent extensions are MERGED in
  "verifications": []      // ← Parent verifications are MERGED in
}
```

**Verification special case:** When a child defines a verification with the same `name` as a parent but with `ParseDirective: null`, the child inherits the parent's `ParseDirective` and merges `Values` (child values take precedence when the `Extension` field matches). This is why testnet specs can override just the `expected_value` of a chain-id verification:

```json
// Child testnet spec — inherits ParseDirective from parent, overrides expected_value
{
  "name": "chain-id",
  "values": [{"expected_value": "1"}]  // Parent's ParseDirective is adopted automatically
}
```

##### Practical Examples

**Example 1: Base Chain (Full Automatic Inheritance)**
```bash
# Base only defines main collection
# Result: Gets debug, trace, and bundler add-ons for FREE from ETH1
```

**Example 2: Arbitrum (Custom Add-on + Automatic Inheritance)**
```json
{
  "imports": ["ETH1"],
  "api_collections": [
    {
      "collection_data": {"add_on": ""},
      "apis": [/* custom APIs */]
    },
    {
      "collection_data": {"add_on": "arbtrace"},  // Arbitrum-specific
      "apis": [/* arb_trace APIs */]
    }
    // NO debug defined - gets ETH1's debug automatically
    // NO trace defined - gets ETH1's trace automatically
  ]
}
```

**Example 3: Evmos (Selective Disabling)**
```json
{
  "imports": ["ETH1"],
  "api_collections": [
    {
      "collection_data": {"add_on": "debug"},
      "apis": [
        {"name": "debug_getRawBlock", "enabled": false},
        {"name": "debug_traceTransaction", "enabled": false}
        // All other debug APIs inherited as-is from ETH1
      ]
    }
  ]
}
```
Why? Some debug APIs don't work on Evmos, so they explicitly disable them.

##### Decision Matrix: Should You Define a Collection?

| Scenario | Action | Example |
|----------|--------|---------|
| You want ALL parent APIs unchanged | DON'T define the collection | Base importing ETH1 debug |
| You want to disable specific APIs | DEFINE the collection with `enabled: false` | Evmos disabling debug APIs |
| You want to change CU values | DEFINE the collection with custom CU | Optimized chain |
| You want custom verifications | DEFINE the collection with custom verifications | Chain-specific checks |
| You want a chain-specific add-on | DEFINE a NEW collection with unique `add_on` | Arbitrum's arbtrace |
| You want to add new APIs to existing add-on | DEFINE the collection with additional APIs | Fantom's trace APIs |

##### Common Mistakes to Avoid

❌ **MISTAKE 1:** Manually copying all debug APIs when you just want them as-is
```json
// DON'T DO THIS if you want ETH1's debug unchanged:
{
  "collection_data": {"add_on": "debug"},
  "apis": [
    {"name": "debug_traceBlock", "compute_units": 20, ...},
    {"name": "debug_traceTransaction", "compute_units": 100, ...},
    // ... manually copying all 11 APIs
  ]
}
// Just omit the collection entirely and inherit automatically!
```

❌ **MISTAKE 2:** Thinking inheritance is all-or-nothing
```
Inheritance is per-collection based on CollectionData matching!
```

❌ **MISTAKE 3:** Not understanding that `add_on` field determines collection identity
```json
// These are DIFFERENT collections (won't merge):
{"add_on": ""}      // Main collection
{"add_on": "debug"} // Debug collection
{"add_on": "trace"} // Trace collection
```

✅ **BEST PRACTICE:** Only define collections when you need to customize them. Let automatic inheritance handle the rest.

##### Implementation Reference

For those interested in the code:

1. **Collection Matching:** `proto/lavanet/lava/spec/api_collection.proto` defines `CollectionData`
2. **Inheritance Logic:** `x/spec/types/expand.go` - `DoExpandSpec` function (lines 13-101)
3. **Collection Combining:** `x/spec/types/spec.go` - `CombineCollections` function (lines 202-243)
4. **API Merging:** `x/spec/types/api_collection.go` - `InheritAllFields` and `CombineWithOthers` functions
5. **Combinable Interface:** `x/spec/types/combinable.go` - defines how APIs, headers, verifications, etc. are merged

**Algorithm Summary:**
1. Parse parent specs recursively (DFS)
2. Group parent collections by `CollectionData` (including `add_on`)
3. For each child collection: merge with matching parent collections
4. For leftover parent collections (no match in child): append entirely to child spec

END-OF-PHASE3.1-SENTINEL
