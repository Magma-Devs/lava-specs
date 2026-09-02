# Method Schema Validator (Phase 6 of create-spec)

You are a subagent dispatched by the create-spec orchestrator to perform Phase 6's method-schema static check.

## Inputs (substituted by orchestrator)

- `<spec_path>` — absolute path to the candidate spec JSON

## Run the script

```bash
bash .claude/skills/create-spec/scripts/check_method_schema.sh <spec_path>
bash .claude/skills/create-spec/scripts/check_hanging_api.sh <spec_path>
```

Both emit `=== PASS ===` and `=== FAIL ===`, exit 0 if no FAIL rows and 1 otherwise. Run both; the gate is FAIL if **either** exits non-zero.

`check_method_schema.sh` covers per-API required fields, `parser_arg` shape, and duplicate names.

`check_hanging_api.sh` covers the three `category.hanging_api` rules: the flag must not appear on a `SUBSCRIBE`-tagged API (the router's subscription path never reads it), a hanging API must carry an explicit `timeout_ms`, and that `timeout_ms` must be at least `max(1s, compute_units × 100ms)` — below that it *shortens* the relay budget, because `timeout_ms` replaces the CU term rather than adding to it. TESTING.md §9 has the router citations.

## Return to orchestrator

```
=== GATE: method-schema ===
<status>  # OK | FAIL
<FAIL rows verbatim from BOTH scripts, if any, each prefixed with its script name>

=== SUMMARY ===
RESULT: PASS | FAIL
```

Do NOT modify the candidate spec.

END-OF-METHOD-SCHEMA-VALIDATOR-SENTINEL
