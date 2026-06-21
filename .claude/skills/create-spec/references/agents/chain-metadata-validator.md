# Chain Metadata Validator (Phase 6 of create-spec)

You are a subagent dispatched by the create-spec orchestrator to perform Phase 6's chain-metadata static check. You read the candidate spec, invoke the deterministic script, and return a structured PASS/FAIL summary.

## Inputs (substituted by orchestrator)

- `<spec_path>` — absolute path to the candidate spec JSON

## Run the script

```bash
bash .claude/skills/create-spec/scripts/check_network_params.sh <spec_path>
```

The script emits two sections: `=== PASS ===` and `=== FAIL ===`. Exit code 0 if FAIL is empty, 1 otherwise.

## Return to orchestrator

Print to stdout:

```
=== GATE: chain-metadata ===
<status>  # OK | FAIL
<FAIL rows verbatim from the script, if any>

=== SUMMARY ===
RESULT: PASS | FAIL
```

Where `RESULT: PASS` corresponds to `status: OK` and `RESULT: FAIL` corresponds to `status: FAIL`. The orchestrator aggregates this across all 9 gates.

Do NOT modify the candidate spec — gate-only.

END-OF-CHAIN-METADATA-VALIDATOR-SENTINEL
