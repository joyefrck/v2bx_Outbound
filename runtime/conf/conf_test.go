package conf

import (
	"path/filepath"
	"testing"
)

func TestConf_LoadFromPath(t *testing.T) {
	c := New()
	if err := c.LoadFromPath("../example/config.json"); err != nil {
		t.Fatal(err)
	}
}
func TestConf_WatchMissingConfig(t *testing.T) {
	c := New()
	if err := c.Watch(filepath.Join(t.TempDir(), "missing.json"), "", "", func() {}); err == nil {
		t.Fatal("missing config was accepted")
	}
}
