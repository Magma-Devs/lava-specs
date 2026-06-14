#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/resolve_endpoints.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
check() { if printf '%s' "$3" | grep -qF -- "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; echo "  want: $2"; echo "  got: $3"; fail=1; fi; }

# pr_body fixture with a machine-readable ENDPOINTS block
cat > "$TMP/pr_body.md" <<'EOF'
## New chain spec: Iota
<!-- ENDPOINTS
mainnet: https://body-main/rpc
testnet: https://body-test/rpc
-->
body text
EOF

# 1. comment override wins over pr_body
out="$(COMMENT_MAINNET="https://cli-main" COMMENT_TESTNET="" PR_BODY_FILE="$TMP/pr_body.md" bash "$SCRIPT")"
check "comment source"     "ENDPOINT_SOURCE=comment"          "$out"
check "comment mainnet"     "MAINNET_URLS=https://cli-main"    "$out"

# 2. no comment -> pr_body block used
out="$(COMMENT_MAINNET="" COMMENT_TESTNET="" PR_BODY_FILE="$TMP/pr_body.md" bash "$SCRIPT")"
check "pr_body source"      "ENDPOINT_SOURCE=pr_body"          "$out"
check "pr_body mainnet"     "MAINNET_URLS=https://body-main/rpc" "$out"
check "pr_body testnet"     "TESTNET_URLS=https://body-test/rpc" "$out"

# 3. no comment, no parseable block -> self_research
echo "no endpoints here" > "$TMP/empty.md"
out="$(COMMENT_MAINNET="" COMMENT_TESTNET="" PR_BODY_FILE="$TMP/empty.md" bash "$SCRIPT")"
check "self_research source" "ENDPOINT_SOURCE=self_research"   "$out"

# 4. CRLF PR body (GitHub API delivers \r\n) -> no carriage return in the URL
printf '## chain\r\n<!-- ENDPOINTS\r\nmainnet: https://crlf-main/rpc\r\ntestnet: https://crlf-test/rpc\r\n-->\r\nbody\r\n' > "$TMP/crlf.md"
out="$(COMMENT_MAINNET="" COMMENT_TESTNET="" PR_BODY_FILE="$TMP/crlf.md" bash "$SCRIPT")"
check "crlf mainnet clean" "MAINNET_URLS=https://crlf-main/rpc" "$out"
check "crlf testnet clean" "TESTNET_URLS=https://crlf-test/rpc" "$out"
# the resolved line must not contain a carriage return
if printf '%s' "$out" | grep -q $'\r'; then echo "FAIL - carriage return leaked"; fail=1; else echo "ok   - no carriage return leaked"; fi

exit $fail
