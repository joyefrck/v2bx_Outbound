package cmd

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
)

func TestCheckConfigDoesNotFetchInclude(t *testing.T) {
	var requests atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { requests.Add(1) }))
	defer server.Close()
	path := filepath.Join(t.TempDir(), "config.json")
	os.WriteFile(path, []byte(`{"Nodes":[{"Include":"`+server.URL+`"}]}`), 0600)
	if checkConfig(path) == nil {
		t.Fatal("remote Include accepted")
	}
	if requests.Load() != 0 {
		t.Fatal("preflight made a network request")
	}
}
func TestCheckConfigRejectsInvalidAndUnknownCore(t *testing.T) {
	for _, data := range []string{`{`, `{"Cores":[]}`, `{"Cores":[{"Type":"unknown"}]}`} {
		path := filepath.Join(t.TempDir(), "config.json")
		os.WriteFile(path, []byte(data), 0600)
		if checkConfig(path) == nil {
			t.Fatalf("accepted %s", data)
		}
	}
}
