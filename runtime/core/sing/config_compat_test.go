package sing

import (
	"encoding/json"
	"github.com/InazumaV/V2bX/conf"
	"os"
	"path/filepath"
	"testing"
)

func TestLegacyConfigMigrationIsInMemoryAndPreservesRuleOrder(t *testing.T) {
	data := []byte(`{"dns":{"servers":[{"tag":"cf","address":"1.1.1.1"}]},"outbounds":[{"type":"direct","tag":"direct"},{"type":"block","tag":"block"}],"route":{"rules":[{"ip_is_private":true,"outbound":"block"},{"network":["udp","tcp"],"outbound":"direct"}]}}`)
	migrated, err := normalizeLegacyConfig(data)
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	json.Unmarshal(migrated, &got)
	rules := got["route"].(map[string]any)["rules"].([]any)
	if rules[0].(map[string]any)["action"] != "reject" || rules[1].(map[string]any)["outbound"] != "direct" {
		t.Fatal("rule order or target changed")
	}
	path := filepath.Join(t.TempDir(), "sing.json")
	os.WriteFile(path, data, 0600)
	cfg := conf.NewSingConfig()
	cfg.OriginalPath = path
	if err = checkConfig(&conf.CoreConfig{SingConfig: cfg}); err != nil {
		t.Fatal(err)
	}
	core, err := New(&conf.CoreConfig{SingConfig: cfg})
	if err != nil {
		t.Fatal(err)
	}
	if err = core.Start(); err != nil {
		t.Fatal(err)
	}
	core.Close()
	after, _ := os.ReadFile(path)
	if string(after) != string(data) {
		t.Fatal("original config was modified")
	}
}
func TestAmbiguousLegacyConfigRequiresMigration(t *testing.T) {
	for _, data := range []string{
		`{"dns":{"servers":[{"address":"https://example.invalid/dns-query"}]}}`,
		`{"dns":{"servers":[{"address":"1.1.1.1","address_resolver":"other"}]}}`,
		`{"outbounds":[{"type":"block","tag":"block"}],"route":{"final":"block"}}`,
		`{"outbounds":[{"type":"block","tag":"block"},{"type":"selector","tag":"select","outbounds":["block"]}]}`,
	} {
		if _, err := normalizeLegacyConfig([]byte(data)); err == nil {
			t.Fatalf("ambiguous config accepted: %s", data)
		}
	}
}
