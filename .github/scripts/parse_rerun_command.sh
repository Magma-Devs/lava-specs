#!/usr/bin/env bash
# Parse a PR comment body for a /rerun-* command.
# Usage: parse_rerun_command.sh "<comment body>"   (or body on stdin)
# Emits KEY=VALUE lines on stdout. Resolves `use=SECRET` tokens against the
# space-separated allow-list in $ALLOWED_SECRETS, reading the value from the
# same-named environment variable. Exit 2 on a malformed command/secret.
set -uo pipefail
set -f  # no globbing — we word-split untrusted comment tokens

body="${1:-$(cat)}"
body_flat="$(printf '%s' "$body" | tr '\n' ' ')"
IFS= read -r first_line <<<"$body" || true
cmd="$(printf '%s' "$first_line" | awk '{print $1}')"

emit() { printf '%s=%s\n' "$1" "$2"; }

# Named commands re-run EXACTLY one phase (START==END). Only /rerun-from runs
# from the given phase through the end of the pipeline (END=12, the summary).
case "$cmd" in
  /rerun-probe)  start=8;  end=8 ;;
  /rerun-review) start=9;  end=9 ;;
  /rerun-fix)    start=10; end=10 ;;
  /rerun-final)  start=11; end=11 ;;
  /rerun-from)
    start="$(printf '%s' "$first_line" | awk '{print $2}')"
    case "$start" in
      8|9|10|11) ;;
      *) echo "ERROR: /rerun-from needs a phase in {8,9,10,11}, got '$start'" >&2; exit 2 ;;
    esac
    end=12 ;;
  *)
    emit IS_COMMAND false
    exit 0 ;;
esac

emit IS_COMMAND true
emit START_PHASE "$start"
emit END_PHASE "$end"

resolve_token() { # echo resolved URL for one token (raw url | use=NAME)
  local tok="$1" name val
  case "$tok" in
    use=*)
      name="${tok#use=}"
      printf '%s' "$name" | grep -qE '^[A-Z0-9_]+$' || { echo "ERROR: bad secret name '$name'" >&2; return 2; }
      case " ${ALLOWED_SECRETS:-} " in
        *" $name "*) ;;
        *) echo "ERROR: secret '$name' not in ALLOWED_SECRETS" >&2; return 2 ;;
      esac
      val="$(eval "printf '%s' \"\${$name:-}\"")"
      [ -n "$val" ] || { echo "ERROR: secret '$name' is empty/unset" >&2; return 2; }
      printf '%s' "$val" ;;
    http://*|https://*|ws://*|wss://*) printf '%s' "$tok" ;;
    *) echo "ERROR: token '$tok' is neither a url nor use=SECRET" >&2; return 2 ;;
  esac
}

collect() { # $1 = key (mainnet|testnet) -> comma-joined resolved urls
  local key="$1" out="" t v
  for t in $body_flat; do
    case "$t" in
      ${key}=*)
        v="$(resolve_token "${t#${key}=}")" || return 2
        out="${out:+$out,}$v" ;;
    esac
  done
  printf '%s' "$out"
}

# Validate tokens before emitting, so exit 2 propagates to the whole script
mainnet_urls="$(collect mainnet)" || exit 2
testnet_urls="$(collect testnet)" || exit 2

emit MAINNET_URLS "$mainnet_urls"
emit TESTNET_URLS "$testnet_urls"

hints="$(printf '%s' "$body_flat" \
  | sed -E 's#/rerun-(probe|review|fix|final)##; s#/rerun-from[[:space:]]+[0-9]+##' \
  | sed -E 's#(mainnet|testnet)=[^[:space:]]+##g' \
  | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
emit HINTS "$hints"
