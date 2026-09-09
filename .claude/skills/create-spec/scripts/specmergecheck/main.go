package main

// Validates a flat lava-specs catalog through the REAL chain merge
// (types.DoExpandSpec -> CombineCollections), not a reimplementation.
// Usage: go run ./cmd/specmergecheck <catalog-dir> <out.json>

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"

	sdk "github.com/cosmos/cosmos-sdk/types"
	specutils "github.com/lavanet/lava/v5/x/spec/client/utils"
	"github.com/lavanet/lava/v5/x/spec/types"
)

func main() {
	dir, out := os.Args[1], os.Args[2]
	files, _ := filepath.Glob(filepath.Join(dir, "*.json"))
	byIndex := map[string]types.Spec{}
	for _, f := range files {
		var p specutils.SpecAddProposalJSON
		b, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		if err := json.Unmarshal(b, &p); err != nil {
			fmt.Fprintf(os.Stderr, "DECODE FAIL %s: %v\n", filepath.Base(f), err)
			continue
		}
		for _, s := range p.Proposal.Specs {
			byIndex[s.Index] = s
		}
	}
	fmt.Fprintf(os.Stderr, "loaded %d indices from %d files\n", len(byIndex), len(files))

	get := func(_ sdk.Context, index string) (types.Spec, bool) {
		s, ok := byIndex[index]
		return s, ok
	}

	result := map[string]map[string]map[string]string{}
	var failed []string
	idxs := make([]string, 0, len(byIndex))
	for i := range byIndex {
		idxs = append(idxs, i)
	}
	sort.Strings(idxs)
	for _, i := range idxs {
		s := byIndex[i]
		spec := s
		depends := map[string]bool{spec.Index: true}
		inherit := map[string]bool{}
		if _, err := types.DoExpandSpec(sdk.Context{}, &spec, depends, &inherit, "", get); err != nil {
			failed = append(failed, fmt.Sprintf("%s: %v", i, err))
			continue
		}
		colls := map[string]map[string]string{}
		for _, c := range spec.ApiCollections {
			cd := c.CollectionData
			k := fmt.Sprintf("%s/%s/%s/%s", cd.ApiInterface, orDash(cd.InternalPath), cd.Type, orDash(cd.AddOn))
			m := map[string]string{}
			for _, a := range c.Apis {
				j, _ := json.Marshal(map[string]interface{}{
					"bp": a.BlockParsing, "cu": a.ComputeUnits, "cat": a.Category,
					"en": a.Enabled, "to": a.TimeoutMs,
				})
				m[a.Name] = string(j)
			}
			colls[k] = m
		}
		result[i] = colls
	}
	b, _ := json.Marshal(result)
	os.WriteFile(out, b, 0o644)
	fmt.Fprintf(os.Stderr, "expanded %d indices, %d failed\n", len(result), len(failed))
	for _, f := range failed {
		fmt.Fprintf(os.Stderr, "  EXPAND FAIL %s\n", f)
	}
}

func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}
