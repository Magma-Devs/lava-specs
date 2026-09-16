# spec_leaves.jq — identity-keyed leaf dump of a Lava spec file.
#
# Emits one "<key>\t<json-value>" line per leaf. Keys are built from IDENTITY
# (spec index, collection_data tuple, api/extension/verification name, …), never
# from array position, so appending a method does not renumber every key that
# follows it. That is what lets check_update_diff.sh tell an ADDED api apart
# from a MODIFIED one.
#
# Every target additionally emits a "<target>|@" presence leaf so a target with
# no fields of its own is still visible to the add/remove comparison.

def flat($p):
  . as $v
  | if ($v | type) == "object" then
      ( if ($v | length) == 0 then [{k: $p, v: "{}"}]
        else [ $v | to_entries[]
               | .key as $k
               | (.value | flat(if $p == "" then $k else "\($p).\($k)" end)) ] | add
        end )
    elif ($v | type) == "array" then
      ( if ($v | length) == 0 then [{k: $p, v: "[]"}]
        else [ range(0; $v | length) as $i
               | ($v[$i] | flat("\($p)[\($i)]")) ] | add
        end )
    else [{k: $p, v: ($v | tojson)}]
    end;

# A collection's identity is its full collection_data tuple: two collections on
# the same interface but different internal_path/add_on are different targets.
def ckey:
  .collection_data
  | "\(.api_interface // "")~\(.internal_path // "")~\(.type // "")~\(.add_on // "")";

def emit($prefix): flat("") | .[] | "\($prefix)|\(.k)\t\(.v)";

.proposal.specs[]?
| .index as $si
| ("S:\($si)") as $sp
| ( "\($sp)|@\t1",

    # spec-level fields (everything but the collections)
    ( del(.api_collections) | emit($sp) ),

    ( .api_collections[]?
      | ckey as $ck
      | "\($sp)|C:\($ck)" as $cp
      | ( "\($cp)|@\t1",

          # collection-level fields + its identity tuple
          ( del(.apis, .headers, .inheritance_apis, .parse_directives,
                .verifications, .extensions) | emit($cp) ),

          ( .apis[]? | .name as $n | "\($cp)|A:\($n)" as $t
            | ("\($t)|@\t1", (del(.name) | emit($t))) ),

          ( .extensions[]? | .name as $n | "\($cp)|E:\($n)" as $t
            | ("\($t)|@\t1", (del(.name) | emit($t))) ),

          ( .parse_directives[]? | .function_tag as $n | "\($cp)|P:\($n)" as $t
            | ("\($t)|@\t1", (del(.function_tag) | emit($t))) ),

          ( .verifications[]? | .name as $n | "\($cp)|V:\($n)" as $t
            | ("\($t)|@\t1", (del(.name) | emit($t))) ),

          ( .headers[]? | (.name // .header_name // "?") as $n | "\($cp)|H:\($n)" as $t
            | ("\($t)|@\t1", (del(.name) | emit($t))) ),

          ( .inheritance_apis[]?
            | "\($cp)|I:\(.api_interface // "")~\(.internal_path // "")~\(.type // "")~\(.add_on // "")" as $t
            | "\($t)|@\t1" )
        )
    )
  )
