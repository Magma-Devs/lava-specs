# Extensions Validator (Phase 6 of create-spec)

You are a subagent dispatched by the create-spec orchestrator to perform Phase 6's plugins/extensions static check.

## Inputs (substituted by orchestrator)

- `<spec_path>` — absolute path to the candidate spec JSON

## Run the script

```bash
bash .claude/skills/create-spec/scripts/check_extensions.sh <spec_path>
```

Emits `=== PASS ===` and `=== FAIL ===`. Exit 0 if no FAIL rows, 1 otherwise.

## Return to orchestrator

```
=== GATE: extensions ===
<status>  # OK | FAIL
<FAIL rows verbatim from the script, if any>

=== SUMMARY ===
RESULT: PASS | FAIL
```

Do NOT modify the candidate spec.

END-OF-EXTENSIONS-VALIDATOR-SENTINEL
