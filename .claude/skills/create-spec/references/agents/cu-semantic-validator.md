# CU Semantic Validator (Phase 6 of create-spec)

You are a subagent dispatched by the create-spec orchestrator to perform Phase 6's compute-unit check. It has THREE layers: a deterministic mechanical-rule gate (subscription mechanics), a deterministic anomaly gate (uniformity script), and an advisory semantic classification.

## Inputs (substituted by orchestrator)

- `<spec_path>` — absolute path to the candidate spec JSON

## Layer 0 — Mechanical CU rules (deterministic hard gate)

A small set of CU values are fixed Lava conventions, not judgement calls. Extract the per-method tuples (same jq as Layer 2 below) and hard-FAIL any method that violates these EXACT rules:

| Rule | Recognize by | Required CU |
|---|---|---|
| subscribe variant | `category.subscription == true` AND name contains `ubscribe` but NOT `nsubscribe` | exactly `1000` |
| unsubscribe variant | `category.subscription == true` AND name contains `nsubscribe` | exactly `10` |

These two are the ONLY exact-equality hard rules. Do **not** force `category.stateful == 1` methods to a single value here — stateful/tx-submit CU legitimately varies (see Layer 2's `tx-submit` band 10–40); flagging it belongs in the advisory layer, not this gate. Likewise, do not force read methods to an exact value by `parser_func` — that flattening would trip Layer 1's anomaly gate. Parser-shape pricing is handled as bands in Layer 2.

Capture one FAIL row per violation: `index | interface | method | declared | required | rule`.

## Layer 1 — Hard anomaly gate (deterministic)

Run the anomaly script from the repo root:

```bash
.claude/skills/create-spec/scripts/check_cu_anomaly.sh <spec_path>
```

If it exits non-zero (uniformity smell — CU values flattened), the gate FAILS. Capture its FAIL rows verbatim. This is the only condition that fails the gate.

## Layer 2 — Advisory semantic classification

Extract per-method tuples:

```bash
jq -r '
  .proposal.specs[] as $s
  | $s.api_collections[]? as $c
  | $c.apis[]?
  | "\($s.index)\t\($c.collection_data.api_interface)\t\(.name)\t\(.compute_units // "null")\t\(.block_parsing.parser_func // "null")\t\(.category.stateful // 0)\t\(.category.subscription // false)"
' <spec_path>
```

Classify each method into ONE bucket by name + category + parser, then check declared CU against the band:

| Bucket | How to recognize | CU band |
|---|---|---|
| tx-submit | name contains `send`/`broadcast`/`submit`/`sendRawTransaction`; or `category.stateful == 1` | 10–40 |
| simulate | name contains `simulate`/`estimate`/`call`/`dryRun` | 40–60 |
| heavy | logs/range scans/traces: `getLogs`, `trace_*`, `debug_trace*`, checkpoint/range queries | 60–200 |
| state-read | everything else (balances, block/tx/account reads) | 10–20 |

Rules:
- Emit an ADVISORY flag for any method whose declared CU is clearly outside its bucket band (e.g. a `trace_*` method priced at 10, or a `sendRawTransaction` priced at 100).
- Subscription subscribe variants (name contains `ubscribe`, NOT `nsubscribe`, with `category.subscription == true`) are expected ≈ 1000; unsubscribe ≈ 10. Flag deviations.
- When uncertain which bucket a method belongs to, DO NOT flag it. Advisory layer is judgement — bias toward silence over noise.

## Return to orchestrator

```
=== GATE: cu-semantic ===
-- Layer 0 (mechanical hard rules) --
<one FAIL row per subscription violation: index | interface | method | declared | required | rule>
(or "none")

-- Layer 1 (hard anomaly) --
<verbatim check_cu_anomaly.sh PASS/FAIL output>

-- Layer 2 (advisory) --
<one ADVISORY row per out-of-band method: index | interface | method | declared | expected_band | bucket>
(or "none")

=== SUMMARY ===
RESULT: PASS | FAIL    # FAIL if Layer 0 has any violation OR Layer 1 (anomaly script) exited non-zero
```

Do NOT modify the candidate spec.

END-OF-CU-SEMANTIC-VALIDATOR-SENTINEL
