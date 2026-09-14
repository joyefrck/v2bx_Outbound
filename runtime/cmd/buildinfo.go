package cmd

import (
	"encoding/json"
	"fmt"
	"runtime"
	"runtime/debug"
	"sort"

	core "github.com/InazumaV/V2bX/core"
	"github.com/spf13/cobra"
)

var sourceRevision, patchDigest, sourceState string

// ModuleVersion reports replacements explicitly: a label must never conceal a fork.
type ModuleVersion struct {
	Path        string         `json:"path"`
	Version     string         `json:"version"`
	Sum         string         `json:"sum,omitempty"`
	Replacement *ModuleVersion `json:"replacement,omitempty"`
}

func moduleVersion(m *debug.Module) ModuleVersion {
	v := ModuleVersion{Path: m.Path, Version: m.Version, Sum: m.Sum}
	if m.Replace != nil {
		r := moduleVersion(m.Replace)
		v.Replacement = &r
	}
	return v
}

func buildInfo() (any, error) {
	b, ok := debug.ReadBuildInfo()
	if !ok {
		return nil, fmt.Errorf("Go build information unavailable")
	}
	names := map[string]string{
		"github.com/xtls/xray-core":             "xray",
		"github.com/sagernet/sing-box":          "sing-box",
		"github.com/apernet/hysteria/core/v2":   "hysteria2",
		"github.com/apernet/hysteria/extras/v2": "hysteria2-extras",
	}
	modules := map[string]ModuleVersion{}
	for _, m := range b.Deps {
		if name, ok := names[m.Path]; ok {
			modules[name] = moduleVersion(m)
		}
	}
	enabled := core.RegisteredCore()
	sort.Strings(enabled)
	return struct {
		SourceState    string                   `json:"source_state"`
		SourceRevision string                   `json:"source_revision"`
		PatchDigest    string                   `json:"patch_index_sha256"`
		Schema         int                      `json:"schema"`
		Version        string                   `json:"version"`
		Go             string                   `json:"go"`
		OS             string                   `json:"os"`
		Arch           string                   `json:"arch"`
		Cores          []string                 `json:"cores"`
		Modules        map[string]ModuleVersion `json:"modules"`
	}{sourceState, sourceRevision, patchDigest, 1, version, b.GoVersion, runtime.GOOS, runtime.GOARCH, enabled, modules}, nil
}

func init() {
	command.AddCommand(&cobra.Command{
		Use: "build-info", Short: "Print actual compiled core dependencies as JSON", Args: cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			info, err := buildInfo()
			if err != nil {
				return err
			}
			return json.NewEncoder(c.OutOrStdout()).Encode(info)
		},
	})
}
