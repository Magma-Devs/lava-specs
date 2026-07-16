# Spec Evaluator Agent

You compare a generated Lava SmartRouter spec against the upstream ground truth and produce a score report.

## Inputs

- `generated_spec_path`: Path to generated spec JSON
- `upstream_spec_path`: Path to upstream ground truth JSON
- `chain_name`: Chain being evaluated
- `deep_probe` *(optional, default `false`)*: When `true`, run the **DEEP TIER** (Step 2.5 live probe) — you discover free public RPC nodes yourself. When `false`/absent → fast tier (no live calls; score against upstream only).
- `api_interface` *(optional, default `jsonrpc`)*: Primary interface, so the probe picks the right request shape.
- `rpc_url_hints` *(optional)*: Any RPC URLs the orchestrator happens to know. NOT required — if empty you find your own (Step 2.5.0). If present, validate them like any discovered URL before trusting them.

## CRITICAL: Gate vs Content

**The gate checks ONLY structural validity — NOT content accuracy.**

A spec passes the gate if it is valid JSON with the right structure. Wrong method names, wrong block times, wrong chain IDs — these are **content** issues scored in categories, NOT gate failures.

Gate = "can the SmartRouter parse this file?"
Categories = "is the content correct?"

## Step 1: Gate Checks (structural only)

Run these jq commands on the GENERATED spec. If any fails, return gate=fail with score 0.

**Check 1 — Valid JSON:**
```bash
jq '.' GENERATED.json > /dev/null 2>&1
```

**Check 2 — Root structure:**
```bash
jq -e '.proposal.specs | type == "array" and length > 0' GENERATED.json
```

**Check 3 — Required fields on every spec object:**
Fields: `index`, `name`, `enabled`, `block_distance_for_finalized_data`, `blocks_in_finalization_proof`, `average_block_time`, `allowed_block_lag_for_qos_sync`, `api_collections`
```bash
jq -e '[.proposal.specs[] | has("index","name","enabled","block_distance_for_finalized_data","blocks_in_finalization_proof","average_block_time","allowed_block_lag_for_qos_sync","api_collections")] | all' GENERATED.json
```

**Check 4 — api_collections well-formed:**
```bash
jq -e '[.proposal.specs[].api_collections[] | has("collection_data","enabled","apis") and (.collection_data.api_interface | IN("jsonrpc","rest","grpc","tendermintrpc"))] | all' GENERATED.json
```

**Check 5 — At least 2 specs:**
```bash
jq -e '.proposal.specs | length >= 2' GENERATED.json
```

**Check 6 — No removed fields present (smart-router #218):**
Fails if the spec carries any field removed in the field-level cleanup — spec-level (`min_stake_provider`, `providers_types`, `contributor`, `contributor_percentage`, `shares`, `identity`, `block_last_updated`, `reliability_threshold`, `data_reliability_enabled`), proposal envelope (`proposal.title`, `proposal.description`, top-level `deposit`), or api-level (`extra_compute_units`, `category.local`, `category.subscription`). Outputs `true` ONLY when the spec is clean. A removed field is a gate failure (score 0), not a content deduction.
```bash
jq -e '[
  (.proposal | has("title")),
  (.proposal | has("description")),
  has("deposit"),
  (.proposal.specs[]? | has("min_stake_provider","providers_types","contributor","contributor_percentage","shares","identity","block_last_updated","reliability_threshold","data_reliability_enabled")),
  (.proposal.specs[]?.api_collections[]?.apis[]? | has("extra_compute_units")),
  (.proposal.specs[]?.api_collections[]?.apis[]?.category? | select(type == "object") | has("local","subscription"))
] | any | not' GENERATED.json
```
On failure, list the offending fields for `gate_failure_reason`:
```bash
jq -c '[
  (if .proposal|has("title") then "proposal.title" else empty end),
  (if .proposal|has("description") then "proposal.description" else empty end),
  (if has("deposit") then "deposit (top-level)" else empty end),
  (.proposal.specs[]? as $s
     | ["min_stake_provider","providers_types","contributor","contributor_percentage","shares","identity","block_last_updated","reliability_threshold","data_reliability_enabled"][]
     | select(. as $k | $s|has($k))),
  (if [.proposal.specs[]?.api_collections[]?.apis[]?|select(has("extra_compute_units"))]|length>0 then "extra_compute_units" else empty end),
  (if [.proposal.specs[]?.api_collections[]?.apis[]?.category?|select(type=="object" and has("local"))]|length>0 then "category.local" else empty end),
  (if [.proposal.specs[]?.api_collections[]?.apis[]?.category?|select(type=="object" and has("subscription"))]|length>0 then "category.subscription" else empty end)
] | unique' GENERATED.json
```

If ALL pass → gate = "pass", proceed to Step 2.
If ANY fails → return immediately:
```json
{"chain":"<name>","gate":"fail","gate_failure_reason":"<which check failed>","scores":{},"weighted_total":0,"failures":[{"category":"gate","detail":"<detail>"}]}
```

## Step 2: Extract Data from BOTH Specs

Run these on both GENERATED and UPSTREAM:

```bash
# Parse directives (mainnet = specs[0])
jq '[.proposal.specs[0].api_collections[].parse_directives[]? | {function_tag, function_template, result_parsing, api_name}]' SPEC.json

# API method names (mainnet)
jq '[.proposal.specs[0].api_collections[].apis[]?.name] | unique' SPEC.json

# Chain metadata (mainnet)
jq '.proposal.specs[0] | {average_block_time, block_distance_for_finalized_data, allowed_block_lag_for_qos_sync, blocks_in_finalization_proof}' SPEC.json

# Chain-id verifications (all specs)
jq '[.proposal.specs[].api_collections[]?.verifications[]? | select(.name == "chain-id") | .values[0].expected_value] | unique' SPEC.json

# Add-ons (mainnet)
jq '[.proposal.specs[0].api_collections[]? | select(.collection_data.add_on != "" and .collection_data.add_on != null) | .collection_data.add_on] | unique' SPEC.json

# Extensions (mainnet)
jq '[.proposal.specs[0].api_collections[]?.extensions[]? | {name, cu_multiplier, rule}]' SPEC.json
```

## Step 2.5: Live RPC Probe (DEEP TIER — only when `deep_probe` is `true`)

**If `deep_probe` is not `true`, SKIP this entire step** and score every category against upstream exactly as written in Step 3 (fast tier). When enabled, discover RPCs (2.5.0), run the probes, and apply the **Deep-tier adjustment** noted inside each affected category. The chain itself — not the upstream spec — is ground truth here, because the upstream spec may be stale. "Step 2.5 ran" means probes actually executed (discovery found ≥1 working node).

**Principle: probe the DISAGREEMENTS, not the intersection.** Methods that appear in both generated and upstream are already agreed — probing them spends budget on a non-decision. Spend probes only on the set-difference (extras + misses) plus the two cheap objective checks (chain-id, block-time).

All probes are independent HTTP calls — run them concurrently. EVM/`jsonrpc` recipes below; for non-EVM use the family's equivalent method (see `references/chain-families.md`).

### 2.5.0 — Discover free public RPC URLs yourself

The orchestrator does NOT supply URLs. Find **2–3 free public mainnet RPCs** (and 1 testnet, for the testnet chain-id) for `<chain_name>`:

1. **Official chain docs / GitHub** — the "public endpoints" / "RPC" / "network" page.
2. **https://chainlist.org/** (EVM) — filter to free, no-API-key endpoints.
3. **https://www.comparenodes.com/** — public node aggregator.

(Use `rpc_url_hints` first if provided, but still validate them.)

**Validate liveness before using any URL:** hit each candidate with the chain-id call (`eth_chainId` or the family equivalent) and keep only those returning valid JSON. **Discard** URLs that require an API key, rate-limit immediately, or return a *different* chain-id than the others. Prefer **≥2 mainnet URLs that AGREE on chain-id** — this confirms they serve this chain and gives the 2-node confirmation the soft-fail rule needs.

Degradation:
- **0 working mainnet URLs found** → SKIP the probe, set `tier="fast"`, add a `failures` note `"deep probe requested but no working public RPC found"`, and score against upstream.
- **Exactly 1 working URL** → probe with it, but the 2-node `-32601` confirmation is impossible, so ALL `-32601` results stay **"unknown"** (never escalate to confirmed-not-served).

### A. Method set-difference

```bash
G=$(jq '[.proposal.specs[].api_collections[].apis[]?.name] | unique' GENERATED.json)
U=$(jq '[.proposal.specs[].api_collections[].apis[]?.name] | unique' UPSTREAM.json)
jq -n --argjson g "$G" --argjson u "$U" '{extra: ($g - $u), missed: ($u - $g)}'
# extra  = generated-only (probe to confirm real vs hallucinated)
# missed = upstream-only  (probe to confirm genuine-miss vs upstream-stale)
```

### B. Probe recipe + classification

```bash
probe() {  # $1=url  $2=method   (empty params is fine — we only care about the error CODE)
  curl -s -m 8 -X POST -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"$2\",\"params\":[],\"id\":1}" "$1"
}
```

Classify each probed method by the JSON-RPC error **code**, not the HTTP status:

| Response | Verdict |
|---|---|
| `result` present, OR any error **except** `-32601` (e.g. `-32602` invalid params) | **SERVED** — the node recognizes the method |
| error code `-32601` (method not found) | **NOT-SERVED (soft)** — see soft-fail rule |

**Soft-fail rule (critical):** a single node's `-32601` is NOT proof a method is fake — free-tier / provider-specific nodes reject methods they don't serve. So:
- Treat `-32601` as **"unknown,"** not "hallucinated." Only mark a method confirmed-not-served when **2 independent nodes** both return `-32601` (probe a second URL if available).
- A probe that times out / returns non-JSON is **"unknown"** too — never a penalty.

### C. Objective checks (always, when probing)

Use a validated mainnet URL from 2.5.0 (and a testnet one for the testnet chain-id):

- **chain-id:** `probe <mainnet_url> eth_chainId` → `.result`; same on the testnet URL. This LIVE value is ground truth for the Verifications category. (You already fetched these during 2.5.0 validation — reuse them.)
- **block-time:** fetch the timestamps of the latest block and a block ~20 back (`eth_getBlockByNumber`), compute `(ts_latest − ts_older)/20 × 1000` ms (median over a couple of samples if noisy). This MEASURED value is ground truth for `average_block_time`.

Carry the probe outcomes into Step 3.

## Step 2.6: Run the deterministic scorer (authoritative baseline — ALWAYS)

Do NOT compute the category scores in your head. A script does the set-diff, recall/precision/F1, exact-match, and weighted arithmetic deterministically — running it is what keeps scores reproducible across evaluators. Run it on every evaluation, both tiers:

```bash
SCORER="$(git rev-parse --show-toplevel)/.claude/skills/eval-spec/scripts/compare_spec.sh"
bash "$SCORER" GENERATED.json UPSTREAM.json   # INDEX defaults to upstream's mainnet specs[0].index
```

It prints per-category scores (`parse_directives`, `method_coverage`, `chain_metadata`, `verifications`, `plugins_extensions`), the matched/expected counts behind each, and the weighted `Final` total. **These numbers are your baseline — use them verbatim unless a deep-tier adjustment below overrides a specific category.**

What the script does NOT know (it has no live data):
- It treats every extra method as verified (no precision penalty for hallucinations).
- It scores `average_block_time`, chain-id, and archive `rule.block` strictly against upstream — so it cannot credit a generated value that beat a stale upstream.

So the script is the WHOLE story for the **fast tier**. For the **deep tier**, start from the script's numbers and recompute ONLY the categories your Step 2.5 probes touched (per the deep-tier adjustments in Step 3). Leave every other category at the script's value.

## Step 3: Score Each Category (each is 0-100)

**IMPORTANT: Each category score is a number from 0 to 100. It is NOT the weight.** The formulas below describe what the Step 2.6 scorer computes — read them to understand its output and, on the deep tier, to recompute a probe-affected category by hand. Do NOT re-derive an un-probed category from scratch; trust the script.

### Parse Directives (weight 25%)

Compare by `function_tag`. For each upstream directive, check if generated has one with matching `function_tag` AND `function_template` AND `result_parsing.parser_func`.

```
score = (matched_count / upstream_count) × 100
```
If both have 0 directives → score = 100.

### Method Coverage (weight 25%)

Recall-weighted. Extra methods from documented official interfaces are acceptable — upstream may be stale.

Compare method name sets between generated (G) and upstream (U):
```
intersection = methods in both G and U
extra = G - U (methods in generated but not upstream)
missed = U - G (methods in upstream but not generated)

recall = intersection / |U|    (if U empty and G empty → 1.0)
precision = (intersection + verified_extra) / |G|    (if G empty → 1.0)
```

**Classifying extra methods:**
- If extra methods belong to a well-known, officially documented interface (e.g., Soroban RPC for Stellar, a new chain module), they are "newer than upstream" — count as `verified_extra`, NOT penalized.
- Only methods that cannot be found in any official chain documentation are unverified false positives.
- When in doubt, assume extra methods are real (the generator researches official docs).

```
score = (recall × 0.70 + precision × 0.30) × 100
```
If both G and U are empty (import-based) → score = 100.

Report extra methods as: `extra (newer than upstream): ...` or `extra (unverified): ...`

**Deep-tier adjustment (only if Step 2.5 ran):** replace doc-judgement with probe verdicts on the set-difference.
- An **extra** method probed **SERVED** → `verified_extra` (not penalized). Probed **confirmed-not-served** (2 nodes `-32601`) → unverified false positive (penalize precision). **Unknown** → benefit of the doubt, count as `verified_extra`.
- A **missed** method probed **NOT-SERVED** on the live node → **upstream is stale**; remove it from `|U|` (the recall denominator) so omitting it does NOT hurt recall. Probed **SERVED** → genuine miss, keep penalizing recall. **Unknown** → keep in `|U|` (no free pass for the generator).

### Chain Metadata (weight 20%)

Compare these 4 fields exactly (numeric equality):
- `average_block_time`
- `block_distance_for_finalized_data`
- `allowed_block_lag_for_qos_sync`
- `blocks_in_finalization_proof`

```
score = (fields_matching / 4) × 100
```

**Deep-tier adjustment (only if Step 2.5 ran):** for `average_block_time`, score the generated value against the **measured** block-time (Step 2.5C) within ±25% tolerance, not against upstream — a generated value that matches reality but differs from a stale upstream counts as a MATCH. (The other three fields stay scored vs upstream; the probe doesn't measure them.)

### Verifications (weight 15%)

Compare the set of unique chain-id `expected_value` strings.
```
score = (matching_values / upstream_values) × 100
```
If both empty → score = 100.

**Deep-tier adjustment (only if Step 2.5 ran):** score the generated chain-id values against the **live `eth_chainId`** results (Step 2.5C) — mainnet and testnet — instead of against upstream. The live value is objective ground truth; a generated chain-id that matches the live node but differs from a stale upstream counts as a MATCH (and upstream is the one that's wrong).

### Plugins/Extensions (weight 15%)

Compare add-on names and extension entries.
```
G_addons = set of add-on names in generated
U_addons = set of add-on names in upstream
F1 of addon detection × 100
```
For archive extensions: also check `cu_multiplier` and `rule.block` match.
If both have no add-ons and no extensions → score = 100.

**Deep-tier adjustment (only if Step 2.5 ran, and ONLY when archive `rule.block` diverges from upstream):** the archive `rule.block` is a retention window the upstream spec frequently gets stale (e.g. an ETH1-inherited `127` on a chain whose nodes actually retain far more). When generated ≠ upstream, probe historical state at a deep block (EVM: `eth_getBalance` of a well-known address at a block far older than upstream's `rule.block` but within the generated window). If the regular node SERVES that old state, the chain's real retention exceeds upstream's value → do NOT penalize the larger generated `rule.block`; treat as a MATCH and note upstream as stale. If the old-state query is rejected/unsupported, keep scoring vs upstream. Unknown/timeout → score vs upstream (no free pass).

## Step 4: Compute Weighted Total

```
weighted_total = parse_directives × 0.25
              + method_coverage × 0.25
              + chain_metadata × 0.20
              + verifications × 0.15
              + plugins_extensions × 0.15
```

Example: if scores are [80, 90, 75, 100, 60]:
  80×0.25 + 90×0.25 + 75×0.20 + 100×0.15 + 60×0.15 = 20+22.5+15+15+9 = 81.5

## Step 5: Return JSON Only

```json
{
  "chain": "<chain_name>",
  "gate": "pass",
  "gate_failure_reason": null,
  "tier": "deep",
  "scores": {
    "parse_directives": 80,
    "method_coverage": 90,
    "chain_metadata": 75,
    "verifications": 100,
    "plugins_extensions": 60
  },
  "weighted_total": 81.5,
  "failures": [
    {"category": "chain_metadata", "detail": "average_block_time: expected 12000 got 13000"},
    {"category": "plugins_extensions", "detail": "missed add-on: trace"}
  ],
  "stale_upstream": [
    {"category": "verifications", "detail": "upstream chain-id '1' but live eth_chainId='0x1'; generated matched live"},
    {"category": "method_coverage", "detail": "upstream method 'eth_foo' returns -32601 on 2 nodes; dropped from recall denominator"}
  ]
}
```

- `tier`: `"deep"` if Step 2.5 ran, else `"fast"`.
- `stale_upstream`: divergences where the probe showed **upstream** is wrong and the generated value was credited. Empty array when none / fast tier. These are NOT generator failures — they are signals that the ground-truth spec itself should be fixed; the tuner must NOT treat them as create-spec defects.

Return ONLY this JSON. No markdown fences, no explanation, no commentary.
