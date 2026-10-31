package panel

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
)

func TestVLESSDecryptionContracts(t *testing.T) {
	key := base64.RawURLEncoding.EncodeToString(make([]byte, 32))
	valid := "mlkem768x25519plus.native.600s." + key
	for _, tc := range []struct {
		name, body, want string
		invalid          bool
	}{
		{"old plain", `{}`, "none", false},
		{"old disabled", `{"encryption":"none"}`, "none", false},
		{"new disabled", `{"decryption":"none"}`, "none", false},
		{"null", `{"decryption":null}`, "none", false},
		{"new encrypted", `{"decryption":"` + valid + `"}`, valid, false},
		{"old encrypted", `{"encryption":"mlkem768x25519plus","encryption_settings":{"mode":"native","ticket":"600s","private_key":"` + key + `"}}`, valid, false},
		{"conflicting disabled", `{"decryption":"none","encryption":"mlkem768x25519plus","encryption_settings":{"mode":"native","ticket":"600s","private_key":"` + key + `"}}`, "", true},
		{"empty", `{"decryption":""}`, "", true},
		{"bad type", `{"decryption":true}`, "", true},
		{"bad key", `{"decryption":"mlkem768x25519plus.native.600s.private-secret"}`, "", true},
		{"bad mode", `{"decryption":"mlkem768x25519plus.other.600s.` + key + `"}`, "", true},
		{"bad ticket", `{"decryption":"mlkem768x25519plus.native.0s.` + key + `"}`, "", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var node VAllssNode
			err := json.Unmarshal([]byte(tc.body), &node)
			var got string
			if err == nil {
				got, err = node.VLESSDecryption()
			}
			if (err != nil) != tc.invalid {
				t.Fatalf("invalid=%v, got error %v", tc.invalid, err)
			}
			if err == nil && got != tc.want {
				t.Fatalf("unexpected normalized configuration")
			}
			if err != nil && strings.Contains(err.Error(), "private-secret") {
				t.Fatal("private material leaked")
			}
		})
	}
}
