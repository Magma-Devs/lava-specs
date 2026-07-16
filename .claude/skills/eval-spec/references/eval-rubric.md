# Eval Rubric for Lava Spec Scoring

This rubric defines how to score a generated Lava spec JSON against upstream ground truth. An evaluator agent reads this to determine scoring rules and failure conditions.

## 1. Gate (Pass/Fail)

A spec that fails ANY gate check scores 0. Gate checks run in order and stop at the first failure:

### Gate 1: Valid JSON

**Check:** The spec is valid JSON.

```bash
jq '.' <spec>.json > /dev/null 2>&1
```

**Pass condition:** Exit code 0 (no jq parse errors).

**Failure report:** `gate: fail | reason: Invalid JSON syntax`

---

### Gate 2: Root Structure

**Check:** The root contains `.proposal.specs` as a non-empty array.

```bash
jq -e '.proposal.specs | type == "array" and length > 0' <spec>.json
```

**Pass condition:** Command outputs `true`.

**Failure report:** `gate: fail | reason: Missing or empty .proposal.specs array`

---

### Gate 3: Required Spec Fields

**Check:** Every object in `.proposal.specs[]` has ALL of these fields:
- `index`
- `name`
- `enabled`
- `block_distance_for_finalized_data`
- `blocks_in_finalization_proof`
- `average_block_time`
- `allowed_block_lag_for_qos_sync`
- `api_collections`

```bash
jq -e '[.proposal.specs[] | 
  (has("index") and has("name") and has("enabled") and 
   has("block_distance_for_finalized_data") and has("blocks_in_finalization_proof") and 
   has("average_block_time") and has("allowed_block_lag_for_qos_sync") and 
   has("api_collections"))
] | all' <spec>.json
```

**Pass condition:** Command outputs `true`.

**Failure report:** `gate: fail | reason: Spec at index N missing required field(s): <field list>`

---

### Gate 4: API Collections Well-Formed

**Check:** Each collection in `.proposal.specs[].api_collections[]` has `collection_data` with:
- `api_interface` (one of: `jsonrpc`, `rest`, `grpc`, `tendermintrpc`)
- `enabled` (boolean)
- `apis` (array)

```bash
jq -e '[.proposal.specs[].api_collections[] | 
  (has("collection_data") and 
   .collection_data | (has("api_interface") and ((.api_interface | IN("jsonrpc", "rest", "grpc", "tendermintrpc")) or .api_interface == null) and 
   has("enabled") and (.enabled | type == "boolean") and 
   has("apis") and (.apis | type == "array")))
] | all' <spec>.json
```

**Pass condition:** Command outputs `true`.

**Failure report:** `gate: fail | reason: Collection malformed at spec index N: collection <collection_name> missing or invalid collection_data fields`

---

### Gate 5: Mainnet + Testnet

**Check:** At least 2 specs exist (mainnet + testnet minimum).

```bash
jq -e '.proposal.specs | length >= 2' <spec>.json
```

**Pass condition:** Command outputs `true`.

**Failure report:** `gate: fail | reason: Must have at least 2 specs (mainnet + testnet), found: N`

---

### Gate 6: No Removed Fields

**Check:** No spec object, api, or proposal envelope carries a field removed in the spec field-level cleanup (smart-router #218). The generated spec must emit ONLY active fields — the canonical shape is `{ "proposal": { "specs": [ ... ] } }` with no proposal title/description and no top-level deposit. Emitting any removed field is a hard failure, not a content deduction.

Removed fields that MUST be absent:
- spec-level: `min_stake_provider`, `providers_types`, `contributor`, `contributor_percentage`, `shares`, `identity`, `block_last_updated`, `reliability_threshold`, `data_reliability_enabled`
- proposal envelope: `proposal.title`, `proposal.description`, top-level `deposit`
- api-level: `extra_compute_units`, `category.local`, `category.subscription`

```bash
jq -e '[
  (.proposal | has("title")),
  (.proposal | has("description")),
  has("deposit"),
  (.proposal.specs[]? | has("min_stake_provider","providers_types","contributor","contributor_percentage","shares","identity","block_last_updated","reliability_threshold","data_reliability_enabled")),
  (.proposal.specs[]?.api_collections[]?.apis[]? | has("extra_compute_units")),
  (.proposal.specs[]?.api_collections[]?.apis[]?.category? | select(type == "object") | has("local","subscription"))
] | any | not' <spec>.json
```

**Pass condition:** Command outputs `true` (no removed field present anywhere in the spec).

**List the offending fields for the failure report:**

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
] | unique' <spec>.json
```

**Failure report:** `gate: fail | reason: Spec contains removed field(s) — must be absent per smart-router #218: <field list>`

---

## 2. Category Scoring (5 Categories, 0–100 Each)

### Category 1: Parse Directives (Weight: 25%)

**What to compare:** Function tags, templates, result parsing logic, and API name associations in parse_directives.

**Extract from generated spec:**

```bash
jq '[.proposal.specs[0].api_collections[].parse_directives[] | 
  {function_tag, function_template, result_parsing, api_name}]' <generated>.json
```

**Extract from upstream spec:**

```bash
jq '[.proposal.specs[0].api_collections[].parse_directives[] | 
  {function_tag, function_template, result_parsing, api_name}]' <upstream>.json
```

**Scoring formula:**

- Count total expected directives in upstream.
- Count matched directives (same function_tag, function_template, result_parsing fields) in generated.
- If upstream has 0 directives (import-based spec), score 100 if generated also has 0; otherwise score 0.
- Otherwise: `score = (matched / expected) × 100`

**Failure report format:**

```
parse_directives: <score> — <detail>
  detail: "missed GET_BLOCK_BY_NUM (wrong function_template: expected '...' got '...')"
  detail: "extra directive: CUSTOM_METHOD (not in upstream)"
```

---

### Category 2: Method Coverage (Weight: 25%)

**What to compare:** API method names across all collections (union of methods in mainnet + testnet specs).

**Extract from generated spec:**

```bash
jq '[.proposal.specs[].api_collections[].apis[].name]' <generated>.json
```

**Extract from upstream spec:**

```bash
jq '[.proposal.specs[].api_collections[].apis[].name]' <upstream>.json
```

**Scoring formula:**

Recall-weighted scoring. Extra methods from documented official interfaces are acceptable — the upstream spec may be stale. Only truly hallucinated methods (not found in any official documentation) penalize precision.

Let:
- `G` = set of generated method names
- `U` = set of upstream method names
- `intersection` = `|G ∩ U|`
- `extra` = `G - U` (methods in generated but not upstream)
- `missed` = `U - G` (methods in upstream but not generated)

**Recall (weight 70%):** How many upstream methods were found.
- `recall` = `intersection / |U|` (if `|U| > 0`, else 1.0 if `|G| == 0`)

**Precision (weight 30%):** Are extra methods real or hallucinated?
- Extra methods from a documented, officially supported interface (e.g., Soroban RPC for Stellar, a new chain module) are **not penalized** — classify them as "newer than upstream" in the report.
- Only methods that cannot be verified against any official documentation count as false positives.
- `precision` = `(intersection + verified_extra) / |G|` (if `|G| > 0`, else 1.0)
- When in doubt, assume extra methods are real (benefit of the doubt — the generator researches official docs).

**Combined score:**
- `score = (recall × 0.70 + precision × 0.30) × 100`
- If both `G` and `U` are empty (import-based), score 100

**Failure report format:**

```
method_coverage: <score> — recall=<R> precision=<P>
  missed: eth_getProof, eth_blockNumber, ...
  extra (newer than upstream): getLatestLedger, getEvents, ...  ← not penalized
  extra (unverified): fake_method, ...  ← penalized
```

---

### Category 3: Chain Metadata (Weight: 20%)

**What to compare:** Four critical fields in the first spec (`specs[0]`):
- `average_block_time`
- `block_distance_for_finalized_data`
- `allowed_block_lag_for_qos_sync`
- `blocks_in_finalization_proof`

**Extract from generated spec:**

```bash
jq '.proposal.specs[0] | 
  {average_block_time, block_distance_for_finalized_data, allowed_block_lag_for_qos_sync, blocks_in_finalization_proof}' <generated>.json
```

**Extract from upstream spec:**

```bash
jq '.proposal.specs[0] | 
  {average_block_time, block_distance_for_finalized_data, allowed_block_lag_for_qos_sync, blocks_in_finalization_proof}' <upstream>.json
```

**Scoring formula:**

- Exact match only (value equality).
- Count matched fields (0–4).
- `score = (matched / 4) × 100`

**Failure report format:**

```
chain_metadata: <score> — <detail>
  detail: "average_block_time: expected 12000 got 13000"
  detail: "block_distance_for_finalized_data: expected 256 got 0"
```

---

### Category 4: Verifications (Weight: 15%)

**What to compare:** Verification entries, specifically chain-id expected values (mainnet + testnet) and pruning directives if present in upstream.

**Extract chain-id values from generated:**

```bash
jq '[.proposal.specs[].api_collections[].verifications[] | 
  select(.name == "chain-id") | .values[0].expected_value] | unique' <generated>.json
```

**Extract chain-id values from upstream:**

```bash
jq '[.proposal.specs[].api_collections[].verifications[] | 
  select(.name == "chain-id") | .values[0].expected_value] | unique' <upstream>.json
```

**Extract pruning directives from upstream (if any):**

```bash
jq '[.proposal.specs[].api_collections[].verifications[] | 
  select(.name == "pruning")]' <upstream>.json
```

**Scoring formula:**

- Count expected verifications (chain-id entries + pruning if in upstream).
- Count matched verifications in generated (same name and expected_value).
- If upstream has 0 verifications, score 100 if generated also has 0; otherwise score 0.
- Otherwise: `score = (matched / expected) × 100`

**Failure report format:**

```
verifications: <score> — <detail>
  detail: "mainnet chain-id: expected '0x1' got '1'"
  detail: "testnet chain-id: missing"
  detail: "pruning: not found in generated spec"
```

---

### Category 5: Plugins/Extensions (Weight: 15%)

**What to compare:** Add-on collections and extensions array entries (cu_multiplier, rule fields).

**Extract add-ons from generated:**

```bash
jq '[.proposal.specs[0].api_collections[] | 
  select(.collection_data.add_on != null and .collection_data.add_on != "") | 
  .collection_data.add_on] | unique' <generated>.json
```

**Extract add-ons from upstream:**

```bash
jq '[.proposal.specs[0].api_collections[] | 
  select(.collection_data.add_on != null and .collection_data.add_on != "") | 
  .collection_data.add_on] | unique' <upstream>.json
```

**Extract extensions from generated:**

```bash
jq '[.proposal.specs[0].api_collections[].extensions[] | 
  {name, cu_multiplier, rule}]' <generated>.json
```

**Extract extensions from upstream:**

```bash
jq '[.proposal.specs[0].api_collections[].extensions[] | 
  {name, cu_multiplier, rule}]' <upstream>.json
```

**Scoring formula:**

- Detect matched add-ons and extensions using F1 score (same logic as method coverage).
- For archive extensions: cu_multiplier and rule.block must match exactly.
- If both upstream and generated have 0 add-ons and 0 extensions, score 100.
- If upstream has values but generated has 0, score 0.
- Otherwise: `score = F1(detected add-ons + extensions) × 100`

**Failure report format:**

```
plugins_extensions: <score> — <detail>
  detail: "missed add-on: trace"
  detail: "archive cu_multiplier: expected 5 got 3"
  detail: "extension rule.block: expected 10 got 20"
```

---

## 3. Final Score Calculation

Combine gate status and category scores using weighted average:

```
if gate != "pass":
  spec_score = 0
else:
  spec_score = (
    parse_directives × 0.25 +
    method_coverage × 0.25 +
    chain_metadata × 0.20 +
    verifications × 0.15 +
    plugins_extensions × 0.15
  )

batch_score = mean([spec_score for each of the 7 specs])
```

Note: A spec set may contain more than 2 specs (mainnet, testnet, and additional networks). Score all of them and average.

---

## 4. Output Format

The evaluator outputs a JSON report for each spec and a summary for the batch:

### Per-Spec Report

```json
{
  "spec_name": "<name>",
  "index": <0-6>,
  "gate": "pass|fail",
  "gate_failure_reason": "<reason if failed, null if passed>",
  "scores": {
    "parse_directives": <0-100>,
    "method_coverage": <0-100>,
    "chain_metadata": <0-100>,
    "verifications": <0-100>,
    "plugins_extensions": <0-100>
  },
  "weighted_total": <0-100>,
  "failures": [
    {
      "category": "parse_directives|method_coverage|chain_metadata|verifications|plugins_extensions",
      "detail": "<specific failure message>"
    }
  ]
}
```

### Batch Summary Report

```json
{
  "batch_name": "<spec set name or file>",
  "specs_evaluated": <count>,
  "specs_passed_gate": <count>,
  "batch_score": <0-100>,
  "spec_reports": [
    {
      "spec_name": "<name>",
      "index": <0-6>,
      "weighted_total": <0-100>
    }
  ],
  "summary": {
    "pass_rate": "<percent>",
    "avg_category_scores": {
      "parse_directives": <0-100>,
      "method_coverage": <0-100>,
      "chain_metadata": <0-100>,
      "verifications": <0-100>,
      "plugins_extensions": <0-100>
    },
    "common_failures": [
      {
        "category": "<name>",
        "count": <N>,
        "examples": ["<detail1>", "<detail2>"]
      }
    ]
  }
}
```

---

## Notes for Evaluator Implementation

1. **Import-based specs:** Some upstream specs use imports (e.g., importing parse_directives from a shared file). Treat empty arrays as passing if the generated spec also has empty arrays for those sections.

2. **Null vs missing:** Distinguish between `null` and missing fields. A field with `null` value is different from an absent field — check the gate carefully.

3. **String matching:** Field comparisons are case-sensitive and exact. Whitespace in function_template must match exactly.

4. **Mainnet/testnet detection:** Use spec name or index convention. Typically index 0 = mainnet, index 1 = testnet. If naming is ambiguous, report which spec was compared in failures.

5. **Rounding:** Round final scores to nearest integer (0–100). Round intermediate percentages (precision, recall) to 2 decimal places for reporting.

6. **Early termination:** If gate fails, stop category evaluation and report gate failure only. Do not compute category scores.
