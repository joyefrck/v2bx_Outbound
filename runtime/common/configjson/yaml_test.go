package configjson

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestNormalizePreservesHY2Settings(t *testing.T) {
	data, err := Normalize(strings.NewReader("quic:\n  maxIdleTimeout: 30s\ndisableUDP: false\nacl:\n  inline:\n    - direct(geosite:google)\n    - reject(geoip:cn)\nmasquerade:\n  type: 404\n"))
	if err != nil {
		t.Fatal(err)
	}
	var result map[string]interface{}
	if err := json.Unmarshal(data, &result); err != nil {
		t.Fatal(err)
	}
	if result["disableUDP"] != false || result["quic"].(map[string]interface{})["maxIdleTimeout"] != "30s" {
		t.Fatalf("settings changed: %s", data)
	}
}

func TestNormalizeRejectsAmbiguousInputWithoutLeakingSecrets(t *testing.T) {
	for _, input := range []string{
		"password: secret-fixture\npassword: other\n", "[]", "null", "{}\n---\n{}",
		"outbounds: [secret-fixture", "base: &base {}\ncopy: *base", "value: !custom secret-fixture",
		strings.Repeat(" ", maxConfigSize+1),
	} {
		_, err := Normalize(strings.NewReader(input))
		if err == nil {
			t.Fatal("invalid document accepted")
		}
		if strings.Contains(err.Error(), "secret-fixture") {
			t.Fatal("error exposed document contents")
		}
	}
}

func TestNormalizeAcceptsManagedJSON(t *testing.T) {
	input := `{"disableUDP":true,"outbounds":[{"type":"socks5","socks5":{"password":"p:a$\"\\ss"}}]}`
	data, err := Normalize(strings.NewReader(input))
	if err != nil {
		t.Fatal(err)
	}
	var before, after interface{}
	json.Unmarshal([]byte(input), &before)
	json.Unmarshal(data, &after)
	b, _ := json.Marshal(before)
	a, _ := json.Marshal(after)
	if string(b) != string(a) {
		t.Fatal("JSON values changed")
	}
}
