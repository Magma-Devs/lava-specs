#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/check_verifications.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

OUT=$("$SCRIPT" "$DIR/fixtures/verifications_good.json")
F=$(echo "$OUT" | awk '/^=== FAIL/{f=1;next} /^=== /{f=0} f && NF' | wc -l)
[ "$F" -eq 0 ] || fail "good: FAIL rows=$F, want 0"
echo "good: OK"

set +e; OUT=$("$SCRIPT" "$DIR/fixtures/verifications_bad.json"); RC=$?; set -e
[ "$RC" -eq 1 ] || fail "bad: exit=$RC, want 1"
F=$(echo "$OUT" | awk '/^=== FAIL/{f=1;next} /^=== /{f=0} f && NF' | wc -l)
[ "$F" -ge 3 ] || fail "bad: FAIL rows=$F, want >=3"
echo "bad: OK"

section() { echo "$1" | awk -v s="=== $2 ===" '$0==s{f=1;next} /^=== /{f=0} f && NF'; }

# Severity is checked on every value, against where its check sits (MAG-3950).
OUT=$("$SCRIPT" "$DIR/fixtures/verifications_severity_good.json")
F=$(section "$OUT" FAIL | wc -l)
[ "$F" -eq 0 ] || fail "severity good: FAIL rows=$F, want 0"
for want in \
  "SEVCHAIN/jsonrpc/chain-id|values[0] severity=Fail (default for a basic check)" \
  "SEVCHAIN/jsonrpc/pruning|values[0] severity=Fail (default for a basic check)" \
  "SEVCHAIN/jsonrpc/pruning|values[1] extension archive severity=PartialFail (default for an add-on or extension check)" \
  "SEVCHAIN/jsonrpc/archive-explicit|values[0] extension archive severity=PartialFail" \
  "SEVCHAIN/jsonrpc/tokens|values[0] severity=Warning" \
  "SEVCHAIN/jsonrpc/enabled|values[0] add-on debug severity=PartialFail (default for an add-on or extension check)"; do
  section "$OUT" PASS | grep -qxF "$want" || fail "severity good: no PASS row '$want'"
done
section "$OUT" INFO | grep -qF "SEVCHAIN/jsonrpc/mandatory|values[0] add-on debug severity=Fail makes debug mandatory" \
  || fail "severity good: an explicit Fail on an add-on check has no INFO row"
echo "severity good: OK"

set +e; OUT=$("$SCRIPT" "$DIR/fixtures/verifications_severity_bad.json"); RC=$?; set -e
[ "$RC" -eq 1 ] || fail "severity bad: exit=$RC, want 1"
for want in \
  "SEVBAD/jsonrpc/basic-partial|values[0] severity=PartialFail on a basic check" \
  "SEVBAD/jsonrpc/stopped|values[0] severity invalid (Stop), expected Warning|Fail|PartialFail" \
  "SEVBAD/jsonrpc/second-value|values[1] extension archive severity invalid (Critical)"; do
  section "$OUT" FAIL | grep -qF "$want" || fail "severity bad: no FAIL row '$want'"
done
echo "severity bad: OK"

echo "ALL TESTS PASSED"
