package xray

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/InazumaV/V2bX/api/panel"
)

func TestPanelDNSMapKeepsOverseasDefaults(t *testing.T) {
	path := filepath.Join(t.TempDir(), "dns.json")
	if err := os.WriteFile(path, []byte(`{"servers":["localhost"]}`), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("XRAY_DNS_PATH", path)
	node := &panel.NodeInfo{RawDNS: panel.RawDNS{
		DNSMap: map[string]map[string]interface{}{
			"test": {"address": "9.9.9.9", "domains": []string{"domain:example.com"}},
		},
	}}
	if err := updateDNSConfig(node); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var config DNSConfig
	if err := json.Unmarshal(data, &config); err != nil {
		t.Fatal(err)
	}
	want := []interface{}{"https+local://1.1.1.1/dns-query", "https+local://8.8.8.8/dns-query"}
	if len(config.Servers) != 3 || !reflect.DeepEqual(config.Servers[:2], want) {
		t.Fatalf("unexpected default resolvers: %v", config.Servers)
	}
	rule := config.Servers[2].(map[string]interface{})
	if rule["address"] != "9.9.9.9" || config.Tag != "dns_inbound" {
		t.Fatalf("custom panel rule was lost: %v", config)
	}
}
