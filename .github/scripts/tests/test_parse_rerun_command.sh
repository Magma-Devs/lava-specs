#!/usr/bin/env bash
# Unit tests for parse_rerun_command.sh. Exit non-zero on any failure.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/parse_rerun_command.sh"
fail=0
check() { # $1=label  $2=expected substring  $3=actual
  if printf '%s' "$3" | grep -qF -- "$2"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"; echo "    want substring: $2"; echo "    got: $3"; fail=1
  fi
}
expect_exit() { # $1=label $2=want-code $3=actual-code
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 (want exit $2 got $3)"; fail=1; fi
}

# 1. /rerun-probe with a raw https url
out="$(ALLOWED_SECRETS="" bash "$SCRIPT" "/rerun-probe mainnet=https://a.example/rpc")"
check "probe -> phase 8"      "START_PHASE=8"                 "$out"
check "probe -> is command"   "IS_COMMAND=true"              "$out"
check "probe -> mainnet url"  "MAINNET_URLS=https://a.example/rpc" "$out"

# 2. comma list + testnet + trailing hint text
out="$(ALLOWED_SECRETS="" bash "$SCRIPT" "/rerun-probe mainnet=https://a,https://b testnet=https://t archive node please")"
check "two mainnet urls" "MAINNET_URLS=https://a,https://b" "$out"
check "testnet url"      "TESTNET_URLS=https://t"           "$out"
check "hints captured"   "HINTS=archive node please"        "$out"

# 3. use=SECRET resolves from env when allow-listed
out="$(ALLOWED_SECRETS="PAID_RPC_1" PAID_RPC_1="https://paid/v3/KEY" bash "$SCRIPT" "/rerun-probe mainnet=use=PAID_RPC_1")"
check "secret resolved" "MAINNET_URLS=https://paid/v3/KEY" "$out"

# 4. use=SECRET not in allow-list -> exit 2
ALLOWED_SECRETS="" PAID_RPC_1="x" bash "$SCRIPT" "/rerun-probe mainnet=use=PAID_RPC_1" >/dev/null 2>&1
expect_exit "secret not allow-listed -> exit 2" 2 "$?"

# 5. non-command body -> IS_COMMAND=false, exit 0
out="$(bash "$SCRIPT" "thanks, looks good")"; code=$?
check "non-command -> false" "IS_COMMAND=false" "$out"
expect_exit "non-command -> exit 0" 0 "$code"

# 6. named commands map to a single phase (START==END)
for pair in "rerun-review 9" "rerun-fix 10" "rerun-final 11"; do
  set -- $pair
  out="$(bash "$SCRIPT" "/$1")"
  check "/$1 -> start phase $2" "START_PHASE=$2" "$out"
  check "/$1 -> end phase $2 (single)" "END_PHASE=$2" "$out"
done

# 7. /rerun-from with explicit phase, and a bad phase
out="$(bash "$SCRIPT" "/rerun-from 10")"; check "rerun-from 10" "START_PHASE=10" "$out"
bash "$SCRIPT" "/rerun-from 99" >/dev/null 2>&1; expect_exit "rerun-from 99 -> exit 2" 2 "$?"

# 8. multi-line body (real PR comments have newlines) still parses
out="$(ALLOWED_SECRETS="" bash "$SCRIPT" "$(printf '/rerun-probe mainnet=https://a\n\nplease use archive')")"
check "multiline -> phase 8"   "START_PHASE=8"               "$out"
check "multiline -> url"        "MAINNET_URLS=https://a"      "$out"
check "multiline -> hints"      "HINTS=please use archive"    "$out"

# 9. glob chars in a hint do not expand to filenames
out="$(ALLOWED_SECRETS="" bash "$SCRIPT" "/rerun-review look at * and ?")"
check "glob not expanded" "HINTS=look at * and ?" "$out"

# 10. testnet use=SECRET resolves symmetrically to mainnet
out="$(ALLOWED_SECRETS="PAID_RPC_2" PAID_RPC_2="https://paid-t/rpc" bash "$SCRIPT" "/rerun-probe testnet=use=PAID_RPC_2")"
check "testnet secret resolved" "TESTNET_URLS=https://paid-t/rpc" "$out"

# 11. single-phase commands run EXACTLY one phase
out="$(bash "$SCRIPT" "/rerun-probe")"
check "probe -> start 8" "START_PHASE=8" "$out"
check "probe -> end 8 (single phase)" "END_PHASE=8" "$out"

# 12. /rerun-from runs from N to the END of the pipeline (END=12)
out="$(bash "$SCRIPT" "/rerun-from 9")"
check "from 9 -> start 9"  "START_PHASE=9"  "$out"
check "from 9 -> end 12"   "END_PHASE=12"   "$out"

exit $fail
