package xray

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"testing"

	"github.com/InazumaV/V2bX/api/panel"
	"github.com/InazumaV/V2bX/conf"
)

func TestVLESSRejectsInvalidEncryptionBeforeBuilding(t *testing.T) {
	value := "invalid-private-material"
	node := &panel.NodeInfo{Type: "vless", Common: &panel.CommonNode{ServerPort: 443}, VAllss: &panel.VAllssNode{Decryption: &value, Network: "tcp"}}
	options := &conf.Options{ListenIP: "127.0.0.1", XrayOptions: &conf.XrayOptions{}}
	if _, err := buildInbound(options, node, "test"); err == nil {
		t.Fatal("invalid encryption was silently disabled")
	}
	value = "mlkem768x25519plus.native.600s." + base64.RawURLEncoding.EncodeToString(make([]byte, 32))
	options.XrayOptions.EnableFallback = true
	if _, err := buildInbound(options, node, "test"); err == nil {
		t.Fatal("fallback silently disabled encryption")
	}
}

func TestVLESSPreflightDoesNotApplyDNS(t *testing.T) {
	path := filepath.Join(t.TempDir(), "dns.json")
	original := []byte(`{"servers":["1.1.1.1"]}`)
	if err := os.WriteFile(path, original, 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("XRAY_DNS_PATH", path)
	node := &panel.NodeInfo{Type: "vless", Common: &panel.CommonNode{ServerPort: 443}, VAllss: &panel.VAllssNode{Network: "tcp"}, RawDNS: panel.RawDNS{DNSMap: map[string]map[string]interface{}{"test": {"address": "9.9.9.9:53"}}}}
	options := &conf.Options{ListenIP: "127.0.0.1", XrayOptions: conf.NewXrayOptions()}
	x := &Xray{}
	if err := x.ValidateNode("test", node, options); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != string(original) || node.RawDNS.DNSMap["test"]["address"] != "9.9.9.9:53" {
		t.Fatal("preflight applied or mutated DNS")
	}
	rollback, err := x.SnapshotNodeState("test", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(`{}`), 0600); err != nil {
		t.Fatal(err)
	}
	if err := rollback(); err != nil {
		t.Fatal(err)
	}
	data, _ = os.ReadFile(path)
	if string(data) != string(original) {
		t.Fatal("DNS snapshot was not restored")
	}
}
