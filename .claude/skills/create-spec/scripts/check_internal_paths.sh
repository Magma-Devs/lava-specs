#!/usr/bin/env bash
# check_internal_paths.sh — guard for chains that serve several API surfaces at
# different URL sub-paths (TON's /v2 + /v3, AVAX's /P + /X, MONERO's /json_rpc,
# STRK's /rpc/v0_x).
#
# `collection_data.internal_path` is the sub-path an upstream serves that
# collection at. The router uses it to pick which node-url to dial — NOT to
# match the request. Three things go wrong when that is misunderstood, and this
# catches all three.
#
# Usage:
#   check_internal_paths.sh <spec.json> [more.json ...]          # strict (default)
#   check_internal_paths.sh --warn <spec.json> [more.json ...]   # never blocks
#
# ERRORS (exit 1 in strict mode)
#
#   NAME_CARRIES_PATH   An api name repeats its collection's internal_path
#                       ("/v2/getMasterchainInfo" inside the "/v2" collection).
#                       The name is what a client sends and what the router
#                       matches on; the path is how the router picks the url.
#                       Baking the path into the name means NOTHING matches —
#                       smart-router answers `Not Implemented` and never reaches
#                       an upstream.
#
#   LABEL_AS_PATH       An ENABLED collection whose internal_path is neither ""
#                       nor a "/..." path. The field doubles as a plain label on
#                       DISABLED inheritance-ingredient collections (STRK's
#                       "HTTP-ONLY" / "WS-ONLY"), which is fine — but an enabled
#                       one is appended to a node-url, and `https://host` +
#                       `HTTP-ONLY` is not an address.
#
# WARNINGS (reported, never block)
#
#   AMBIGUOUS_REST_NAME The same (api name, connection type) under two REST
#                       internal paths. The router's REST lookup is keyed by
#                       name + connection type with NO internal path, so one
#                       collection wins and the other is unreachable through the
#                       router. TON has two of these on purpose (/estimateFee,
#                       /runGetMethod exist in both toncenter v2 and tonindex
#                       v3) — an accepted cost, not a defect, but the spec
#                       author has to make that call knowingly.
#
#   AMBIGUOUS_REST_SHAPE  Two REST api names that differ only inside their
#                       {placeholders}. The router compiles a name to a pattern
#                       and the placeholder identifier is erased in the process
#                       — /bech32/{address_bytes} and /bech32/{address_string}
#                       both become /bech32/[^/\s]*, so they key the SAME entry
#                       and the one declared later silently replaces the other.
#                       A path can only ever resolve to one of them, so the
#                       shadowed name is documentation of an api the router
#                       cannot reach. Upstream still serves both — the router
#                       forwards the path it was given — so this costs the
#                       shadowed name's own compute units and block parsing,
#                       not the request.
set -euo pipefail

WARN=0
if [[ "${1:-}" == "--warn" ]]; then WARN=1; shift; fi
if [[ $# -eq 0 ]]; then
  echo "usage: $0 [--warn] <spec.json> [more.json ...]" >&2
  exit 2
fi

errors=0
warnings=0

for f in "$@"; do
  # Fail closed on unparseable input — a malformed file must never read as a
  # clean pass (same reasoning as check_unused_fields.sh).
  if ! jq empty "$f" 2>/dev/null; then
    echo "INVALID_JSON | $f" >&2
    echo "RESULT: FAIL (invalid JSON: $f)"
    exit 2
  fi

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "$line"
    case "$line" in
      AMBIGUOUS_REST_NAME*|AMBIGUOUS_REST_SHAPE*) warnings=$((warnings + 1)) ;;
      *)                    errors=$((errors + 1)) ;;
    esac
  done < <(jq -r --arg f "$f" '
    def collections: .proposal.specs[]? as $s
      | $s.api_collections[]? as $c
      | { index: $s.index, coll: $c, cd: $c.collection_data,
          path: ($c.collection_data.internal_path // ""),
          # NOT `.enabled // true`: the `//` operator takes the right side
          # when the left is false OR null, so that reads every DISABLED
          # collection as enabled — precisely the STRK/SOLANA ingredient case
          # this rule has to leave alone.
          enabled: ($c.enabled != false) };

    # ── ERROR: the path baked into the api name ──────────────────────────────
    ( collections
      | select(.path != "")
      | . as $ctx
      | .coll.apis[]?
      | select(.name | startswith($ctx.path))
      | "NAME_CARRIES_PATH | \($f) | \($ctx.index) | \($ctx.cd.api_interface) | internal_path=\($ctx.path) | api=\(.name)"
    ),

    # ── ERROR: a label where a url path belongs ──────────────────────────────
    ( collections
      | select(.enabled and .path != "" and (.path | startswith("/") | not))
      | "LABEL_AS_PATH | \($f) | \(.index) | \(.cd.api_interface) | internal_path=\(.path) | enabled collections need \"\" or a \"/...\" path"
    ),

    # ── WARNING: one REST name reachable under only one of its paths ─────────
    ( [ collections
        | select(.enabled and .cd.api_interface == "rest")
        | . as $ctx
        | .coll.apis[]?
        | select(.enabled != false)
        | { index: $ctx.index, type: ($ctx.cd.type // ""), name: .name, path: $ctx.path }
      ]
      | group_by([.index, .type, .name])
      | .[]
      | select(length > 1)
      | "AMBIGUOUS_REST_NAME | \($f) | \(.[0].index) | \(.[0].type) \(.[0].name) | declared under \([.[].path] | sort | join(", ")) | the router reaches only one"
    ),

    # ── WARNING: two names that compile to one pattern ───────────────────────
    # Grouped on the name with every {placeholder} flattened, which is what the
    # the name -> pattern transform does. Names that are outright equal are
    # AMBIGUOUS_REST_NAME above, so they are excluded here rather than reported
    # twice.
    ( [ collections
        | select(.enabled and .cd.api_interface == "rest")
        | . as $ctx
        | .coll.apis[]?
        | select(.enabled != false)
        | { index: $ctx.index, type: ($ctx.cd.type // ""), name: .name,
            shape: (.name | gsub("\\{[^}]*\\}"; "{}")) }
      ]
      | group_by([.index, .type, .shape])
      | .[]
      | select(length > 1)
      | select([.[].name] | unique | length > 1)
      | "AMBIGUOUS_REST_SHAPE | \($f) | \(.[0].index) | \(.[0].type) | \([.[].name] | sort | join("  ~  ")) | one pattern, the last one declared wins"
    )
  ' "$f")
done

if [[ "$errors" -gt 0 ]]; then
  if [[ "$WARN" == 1 ]]; then
    echo "RESULT: PASS (warn mode — $errors error(s), $warnings warning(s) reported, not blocking)"
    exit 0
  fi
  echo "RESULT: FAIL ($errors error(s), $warnings warning(s))"
  exit 1
fi
echo "RESULT: PASS ($warnings warning(s), no errors)"
exit 0
