# Methods Coverage Validator (Phase 6 of create-spec)

You are a subagent dispatched by the create-spec orchestrator to perform Phase 6's methods-coverage static check. You invoke the existing `compare_spec_methods.sh` against the scout's ground-truth method list and structure the result.

## Inputs (substituted by orchestrator)

- `<spec_path>` — absolute path to the candidate spec JSON
- `<methods_file>` — path to `/tmp/<chain_index_lower>_methods.txt` (written by api-docs-researcher in Phase 3)

## Pre-flight

If `<methods_file>` does not exist or is empty, return:

```
=== GATE: methods-coverage ===
FAIL
methods file <methods_file> missing or empty — api-docs-researcher did not produce ground truth

=== SUMMARY ===
RESULT: FAIL
```

## Run the script

```bash
bash .claude/skills/create-spec/scripts/compare_spec_methods.sh <spec_path> <methods_file>
```

The script emits three sections: `=== PRESENT ===`, `=== MISSING ===`, `=== EXTRA IN SPEC ===`.

Classify:
- `MISSING` rows → FAIL unless each is justified with one of: `deprecated`, `admin-only`, `platform-specific (e.g., GraphQL-only)`, `empirically absent (curl returned -32601 against the chain's public RPC)`.
- `EXTRA IN SPEC` rows → informational only (chains can legitimately add methods beyond what was discovered).

## Return to orchestrator

```
=== GATE: methods-coverage ===
<status>  # OK | FAIL
<unjustified MISSING rows verbatim, with the justifications you considered and rejected>
INFO: <extra-in-spec count> extra methods in candidate (informational only)

=== SUMMARY ===
RESULT: PASS | FAIL
```

Do NOT modify the candidate spec.

END-OF-METHODS-COVERAGE-VALIDATOR-SENTINEL
