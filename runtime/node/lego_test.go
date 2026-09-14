package node

import (
	"github.com/InazumaV/V2bX/conf"
	"path/filepath"
	"testing"
)

// ACME enrollment and DNS changes are not safe automatic test fixtures.
func TestLegoRenewMissingCertificate(t *testing.T) {
	l := &Lego{config: &conf.CertConfig{CertFile: filepath.Join(t.TempDir(), "missing.pem")}}
	if err := l.RenewCert(); err == nil {
		t.Fatal("missing certificate accepted")
	}
}
