# chain_identity.jq — which specs can tell a node of their own chain apart from
# a node of another chain in the catalogue. Driven by check_chain_identity.sh.
#
# Input: `jq -n -r -f chain_identity.jq <root>/*.json` (every spec file, in the
# order the router walks them). Output: tab-separated rows, listed at the bottom.
#
# Why it re-implements import expansion: a spec's checks are mostly INHERITED
# (BCH and most testnets carry their parent's chain-id request and override only
# the expected value), so reading the declared JSON alone misses most of them.
# The router's rules are mirrored from smart-router types/spec — DoExpandSpec
# (expand.go), CombineCollections (spec.go), Expand / CombineWithOthers
# (api_collection.go) and Verification.Overwrite (combinable.go) — for
# verifications only. That is all this guard reads.
#
# Mode `expand` (--arg mode expand) prints every effective verification value
# instead, in the shape the router-side harness prints, so the two can be
# diffed. That is how this file is checked against the router; see
# test_check_chain_identity.sh for the semantics pinned by fixtures. On main at
# 1a12b8c the whole catalogue matched the router row for row (2,098 values).
#
# One router behaviour is NOT mirrored: Go merges *Verification pointers, so a
# values-only override in a collection that an EARLIER collection of the same
# spec already took through inheritance_apis also reaches that earlier
# collection, by aliasing. No spec does that today, and the fixtures avoid it;
# if one ever does, the expand-mode comparison against the router shows it.

def cdkey: "\(.api_interface // "")|\(.internal_path // "")|\(.type // "")|\(.add_on // "")";
def ckey: .collection_data | cdkey;
# Go's CollectionData.String(): the sort key CombineCollections orders by.
def cdstring: .collection_data
  | "{apiInterface:\(.api_interface // "") internalPath:\(.internal_path // "") type:\(.type // "") addOn:\(.add_on // "")}";

# CombineWithOthers, verification part. The child's own names are taken BEFORE
# merging; a parent verification whose name the child lacks is appended, and
# one the child has is ignored unless the child's copy has no parse_directive,
# in which case it borrows the parent's directive and the parent's values for
# any extension it does not set itself (Verification.Overwrite).
def combine($others; $with_disabled; $overwrite):
  ((.verifications // []) | map(.name)) as $names
  | reduce ($others[] | select((.enabled // false) or $with_disabled) | (.verifications // [])[]) as $m (.;
      ($names | index($m.name)) as $i
      | if $i == null then
          .verifications = ((.verifications // []) + [$m])
        elif $overwrite and (.verifications[$i].parse_directive == null) and ($m.parse_directive != null) then
          ([.verifications[$i].values[]? | .extension // ""]) as $exts
          | .verifications[$i].parse_directive = $m.parse_directive
          | .verifications[$i].values = ((.verifications[$i].values // [])
              + [ $m.values[]? | select((.extension // "") as $e | ($exts | index($e)) == null) ])
        else . end);

# Expand: resolve the inheritance_apis of the collection at $pos, depth first,
# against the spec's OWN collections (disabled ones included). Mutates the
# referenced collections the way the router does, so a later collection that
# inherits from an already-expanded one sees the expanded content.
def expand_internal($pos; $deps):
  (.[$pos] | ckey) as $self
  | (.[$pos].inheritance_apis // []) as $inh
  | .[$pos].inheritance_apis = []
  | reduce $inh[] as $k ({cols: ., rel: []};
      ($k | cdkey) as $kk
      | if (($deps + [$self]) | index($kk)) != null then error("circular inheritance_apis: \($kk)") else . end
      | ([.cols[] | ckey] | indices($kk) | last) as $xi
      | if $xi == null then error("inheritance_apis names a collection the spec does not declare: \($kk)") else . end
      | .cols = (.cols | expand_internal($xi; $deps + [$self]))
      | .rel += [.cols[$xi]])
  | .rel as $rel
  | .cols
  | .[$pos] = (.[$pos] | combine($rel; true; true));

# One spec, imports resolved recursively (DoExpandSpec).
def expand_spec($map; $idx):
  ($map[$idx] // error("imported spec unknown: \($idx)")) as $s
  | [ ($s.imports // [])[] as $imp | expand_spec($map; $imp) ] as $parents
  | [ $parents[] | (.api_collections // [])[] | select(.enabled == true) ] as $pcols
  | ($s.api_collections // []) as $own
  | (reduce range(0; $own | length) as $i ($own;
        expand_internal($i; [])
        | (.[$i] | ckey) as $k
        | .[$i] = (.[$i] | combine([ $pcols[] | select(ckey == $k) ]; false; true)))) as $cols
  | ($cols | map(ckey)) as $ownkeys
  | [ $pcols[] | select(ckey as $k | ($ownkeys | index($k)) == null) ]
  | group_by(cdstring)
  | map(. as $g | $g[0] | combine($g[1:]; false; false)) as $inherited
  | $s | .api_collections = ($cols + $inherited);

def norm: walk(if type == "object" then to_entries | sort_by(.key) | from_entries else . end);

# The request a check sends and how it reads the reply. Two checks with the same
# signature and the same expected value are the same question and answer,
# whatever each spec calls the check.
def sig($c):
  { iface: ($c.collection_data.api_interface // ""),
    type: ($c.collection_data.type // ""),
    api: (.parse_directive.api_name // ""),
    template: (.parse_directive.function_template // ""),
    parse: ((.parse_directive.result_parsing // {})
            | {arg: (.parser_arg // []), func: (.parser_func // ""),
               default: (.default_value // ""), encoding: (.encoding // "")}),
    parsers: (.parse_directive.parsers // []) }
  | norm | tojson;

# Value rows a check contributes. Only a VERIFICATION-tagged check carries its
# own request. Under GET_BLOCK_BY_NUM the expected value is the height to FETCH
# and no compare runs, and every other tag borrows a directive at boot, so none
# of those identify a chain. `*`, empty and latest-distance values compare
# nothing either.
def answers($c):
  select(.parse_directive.function_tag == "VERIFICATION")
  | sig($c) as $sig
  | .name as $name
  | (.values // [])[]
  | select((.expected_value // "") != "" and .expected_value != "*")
  | select((.latest_distance // 0) == 0)
  | {sig: $sig, expected: .expected_value, name: $name,
     extension: (.extension // ""), severity: (.severity // "Fail")};

# An identity check is an answer that rejects the endpoint when it differs:
# extension "" (runs on every endpoint, not just archive ones) and Fail severity
# (Warning only logs).
def identity: select(.extension == "" and .severity == "Fail");

[inputs | .proposal.specs[]?] as $all
| (reduce $all[] as $s ({}; .[$s.index] = $s)) as $map
| [ $map | keys[] as $idx | expand_spec($map; $idx) ] as $expanded
| if ($ARGS.named.mode // "") == "expand" then
    $expanded[]
    | select(.enabled == true) as $s
    | (.api_collections // [])[] | select(.enabled == true) as $c
    | (.verifications // [])[] as $v
    | ($v.values // [])[]
    | [ $s.index, ($c.collection_data.api_interface // ""), ($c.collection_data.type // ""),
        ($c.collection_data.internal_path // ""), ($c.collection_data.add_on // ""), $v.name,
        ($v.parse_directive.function_tag // ""), ($v.parse_directive.api_name // ""),
        (.extension // ""), (.expected_value // ""), ((.latest_distance // 0) | tostring),
        (.severity // "Fail") ] | @tsv
  else
    # Per enabled spec: what its nodes answer (any enabled collection), and per
    # (interface, internal path) the identity checks every endpoint must pass
    # (base collections only — an add-on is opt-in per endpoint).
    [ $expanded[] | select(.enabled == true) | . as $s
      | { index: .index,
          answers: ([ (.api_collections // [])[] | select(.enabled == true) as $c
                      | (.verifications // [])[] | answers($c)
                      | "\(.sig)\u0000\(.expected)" ] | unique),
          units: ([ (.api_collections // [])[]
                    | select(.enabled == true and (.collection_data.add_on // "") == "") as $c
                    | { iface: ($c.collection_data.api_interface // ""),
                        path: ($c.collection_data.internal_path // ""),
                        checks: [ (.verifications // [])[] | answers($c) | identity
                                  | "\(.sig)\u0000\(.expected)" ] } ]
                  | group_by([.iface, .path])
                  | map({iface: .[0].iface, path: .[0].path, checks: (map(.checks[]) | unique)})) } ] as $specs
    | ( ["CHECKED", ($specs | length | tostring), ([$specs[].units[]] | length | tostring)] | @tsv ),
      ( $specs[] as $s
        | $s.units[]
        | . as $u
        | (if $u.path == "" then "-" else $u.path end) as $path
        | if ($u.checks | length) == 0 then
            ["UNIDENTIFIED", $s.index, $u.iface, $path] | @tsv
          else
            [ $specs[] | select(.index != $s.index)
              | select(.answers as $a | $u.checks | all(. as $x | $a | index($x) != null)) | .index ] as $others
            | select($others | length > 0)
            | ["UNSEPARATED", $s.index, $u.iface, $path, ($others | join(" "))] | @tsv
          end )
  end

# Output rows (tab-separated; an empty internal path prints as "-"):
#   CHECKED       <enabled specs> <endpoint shapes>
#   UNIDENTIFIED  <INDEX> <interface> <internal_path>
#   UNSEPARATED   <INDEX> <interface> <internal_path> <space-separated specs whose nodes pass>
#   (mode expand) <INDEX> <interface> <type> <internal_path> <add_on> <name> <function_tag>
#                 <api_name> <extension> <expected_value> <latest_distance> <severity>
