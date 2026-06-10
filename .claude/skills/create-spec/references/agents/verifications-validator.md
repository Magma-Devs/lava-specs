# Verifications Validator (Phase 6 of create-spec)

You are a subagent dispatched by the create-spec orchestrator to perform Phase 6's verifications static check.

## Inputs (substituted by orchestrator)

- `<spec_path>` — absolute path to the candidate spec JSON

## Run the script

```bash
bash .claude/skills/create-spec/scripts/check_verifications.sh <spec_path>
```

The script emits three sections: `=== PASS ===`, `=== FAIL ===`, `=== INFO ===`. Exit 0 if no FAIL rows, 1 otherwise.

`INFO` rows (e.g., `expected_value is wildcard '*'`) are not failures — they indicate the verification uses a wildcard placeholder which is legitimate for verification types like `pruning` where the field's content doesn't need to match a specific value. Include them in your report for transparency, but they do NOT cause `RESULT: FAIL`.

## Return to orchestrator

```
=== GATE: verifications ===
<status>  # OK | FAIL
<FAIL rows verbatim from the script, if any>
<INFO rows verbatim from the script, if any (clearly labeled "INFO")>

=== SUMMARY ===
RESULT: PASS | FAIL
```

Do NOT modify the candidate spec.

END-OF-VERIFICATIONS-VALIDATOR-SENTINEL
