package cmd

import (
	"crypto/ecdh"
	"crypto/mlkem"
	"encoding/base64"
	"strings"
	"testing"
)

func TestVLESSParametersArePaired(t *testing.T) {
	for _, auth := range []string{"x25519", "mlkem768"} {
		params, err := generateVLESSParameters(auth)
		if err != nil {
			t.Fatal(err)
		}
		private, err := base64.RawURLEncoding.DecodeString(strings.Split(params["decryption"], ".")[3])
		if err != nil {
			t.Fatal(err)
		}
		var public []byte
		if auth == "x25519" {
			key, err := ecdh.X25519().NewPrivateKey(private)
			if err != nil {
				t.Fatal(err)
			}
			public = key.PublicKey().Bytes()
		} else {
			key, err := mlkem.NewDecapsulationKey768(private)
			if err != nil {
				t.Fatal(err)
			}
			public = key.EncapsulationKey().Bytes()
		}
		want := "mlkem768x25519plus.native.0rtt." + base64.RawURLEncoding.EncodeToString(public)
		if params["encryption"] != want {
			t.Fatal("generated authentication keys are not paired")
		}
	}
	if _, err := generateVLESSParameters("unknown"); err == nil {
		t.Fatal("unsupported authentication was accepted")
	}
}
