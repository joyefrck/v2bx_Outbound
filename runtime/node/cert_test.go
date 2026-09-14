package node

import (
	"crypto/tls"
	"path/filepath"
	"testing"
)

func Test_generateSelfSslCertificate(t *testing.T) {
	d := t.TempDir()
	cert, key := filepath.Join(d, "cert.pem"), filepath.Join(d, "key.pem")
	if err := generateSelfSslCertificate("localhost", cert, key); err != nil {
		t.Fatal(err)
	}
	if _, err := tls.LoadX509KeyPair(cert, key); err != nil {
		t.Fatal(err)
	}
}
