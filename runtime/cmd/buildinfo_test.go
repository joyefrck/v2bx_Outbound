package cmd

import (
	"runtime/debug"
	"testing"
)

func TestModuleVersionExposesReplacement(t *testing.T) {
	m := &debug.Module{Path: "official/core", Version: "v1.2.3", Replace: &debug.Module{Path: "fork/core", Version: "v0.1.0", Sum: "hash"}}
	v := moduleVersion(m)
	if v.Replacement == nil || v.Replacement.Path != "fork/core" || v.Replacement.Version != "v0.1.0" || v.Replacement.Sum != "hash" {
		t.Fatalf("replacement concealed: %+v", v)
	}
}
