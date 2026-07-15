# Verifications Validator (Phase 6 of create-spec)

You are a subagent dispatched by the create-spec orchestrator to perform Phase 6's verifications static check.

## Inputs (substituted by orchestrator)

- `<spec_path>` — absolute path to the candidate spec JSON

## Run the script

```bash
bash .claude/skills/create-spec/scripts/check_verifications.sh <spec_path>
```

The script emits three sections: `=== PASS ===`, `=== FAIL ===`, `=== INFO ===`. Exit 0 if no FAIL rows, 1 otherwise.

`INFO` rows are not failures. EXCEPTION — archive-tier `pruning`: an `expected_value` of `"*"` (or any non-base-10-integer) on a verification whose `function_tag` is `GET_BLOCK_BY_NUM` with no `latest_distance` is a **RESULT: FAIL** — the router parses it as an integer and excludes the archive provider at boot. A wildcard remains legitimate INFO for other verification fields and other `function_tag` paths. Include all INFO rows in your report for transparency.

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
