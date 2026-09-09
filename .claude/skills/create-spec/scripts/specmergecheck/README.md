# specmergecheck — resolve the catalog through the REAL chain merge

Every other check in this repo resolves `imports` with a reimplementation of
`CombineCollections` (jq, bash, or a script). That is proportionate for a small
diff. It is not proportionate for a change that deletes ~1300 method entries
across 21 specs and claims to alter nothing — there, the reimplementation is the
thing under test.

This runs the catalog through `types.DoExpandSpec` in `github.com/lavanet/lava`,
the same code path the chain and the router use, and dumps every resolved
method's full definition.

## Use

Requires a local checkout of the lava chain module (`~/go/lava` by default):

```bash
mkdir -p ~/go/lava/cmd/specmergecheck
cp .claude/skills/create-spec/scripts/specmergecheck/main.go ~/go/lava/cmd/specmergecheck/
cd ~/go/lava && go run ./cmd/specmergecheck /path/to/lava-specs /tmp/resolved.json
```

It prints `loaded N indices from M files` and `expanded N indices, K failed`. A
non-zero `failed` means an import chain does not resolve — the check every other
guard approximates.

## Proving a refactor changed nothing

Materialise both trees and diff the resolved output, not the files:

```bash
git archive <before> | tar -x -C /tmp/pre
git archive <after>  | tar -x -C /tmp/post
cd ~/go/lava
go run ./cmd/specmergecheck /tmp/pre  /tmp/pre.json
go run ./cmd/specmergecheck /tmp/post /tmp/post.json
# then diff the two JSON maps key by key
```

Used this way on the SUBSTRATE base-spec change: **46332 definitions across 269
indices, 0 changed**. That is the claim a reviewer cannot re-derive from a
21-file diff, and it is the only form of it that does not rest on our own
resolver being right.

Update the module path in `main.go` if lava's major version moves (`v5` today).
