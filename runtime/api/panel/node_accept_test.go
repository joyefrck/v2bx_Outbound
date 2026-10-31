package panel

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/InazumaV/V2bX/conf"
)

func TestNodeConfigurationRequiresAcceptance(t *testing.T) {
	body := `{"server_port":443,"network":"tcp","tls":0,"decryption":"none","base_config":{"push_interval":60,"pull_interval":60}}`
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("ETag", `"test-config"`)
		fmt.Fprint(w, body)
	}))
	defer server.Close()
	client, err := New(&conf.ApiConfig{APIHost: server.URL, NodeType: "vless", NodeID: 1})
	if err != nil {
		t.Fatal(err)
	}
	first, err := client.GetNodeInfo()
	if err != nil || first == nil {
		t.Fatalf("first fetch failed: %v", err)
	}
	second, err := client.GetNodeInfo()
	if err != nil || second == nil {
		t.Fatalf("unapplied candidate was skipped: %v", err)
	}
	client.AcceptNodeInfo(second)
	third, err := client.GetNodeInfo()
	if err != nil || third != nil {
		t.Fatalf("accepted response was reapplied: %v", err)
	}
	body = `{"tls":2,"decryption":"invalid-private-material"}`
	for range 2 {
		if _, err := client.GetNodeInfo(); err == nil {
			t.Fatal("malformed VLESS configuration accepted")
		}
	}
}

func TestUsersRequireAcceptanceIncludingEmptyList(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("If-None-Match") == `"users"` {
			w.WriteHeader(304)
			return
		}
		w.Header().Set("ETag", `"users"`)
		fmt.Fprint(w, `{"users":[]}`)
	}))
	defer server.Close()
	client, _ := New(&conf.ApiConfig{APIHost: server.URL, NodeType: "vless", NodeID: 1})
	for range 2 {
		users, err := client.GetUserList()
		if err != nil || users == nil || len(users) != 0 {
			t.Fatalf("empty user revocation lost: %v", err)
		}
	}
	client.AcceptUserList()
	users, err := client.GetUserList()
	if err != nil || users != nil {
		t.Fatalf("accepted user response not acknowledged: %v", err)
	}
}
