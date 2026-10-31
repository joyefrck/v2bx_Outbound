package panel

import (
	"encoding/base64"
	"errors"
	"regexp"
	"strconv"
	"strings"
)

var vlessPaddingPattern = regexp.MustCompile(`^\d+-\d+-\d+$`)

func (n *VAllssNode) VLESSDecryption() (string, error) {
	if n == nil {
		return "", errors.New("missing VLESS configuration")
	}
	legacy := "none"
	legacyPresent := n.Encryption != "" || n.EncryptionSettings != (EncSettings{})
	if legacyPresent && n.Encryption != "none" {
		if n.Encryption != "mlkem768x25519plus" {
			return "", errors.New("invalid VLESS encryption algorithm")
		}
		s := n.EncryptionSettings
		parts := []string{n.Encryption, s.Mode, s.Ticket}
		if s.ServerPadding != "" {
			parts = append(parts, s.ServerPadding)
		}
		legacy = strings.Join(append(parts, s.PrivateKey), ".")
	}
	if n.Encryption == "none" && n.EncryptionSettings != (EncSettings{}) {
		return "", errors.New("disabled VLESS encryption contains settings")
	}
	value := legacy
	if n.Decryption != nil {
		value = *n.Decryption
		if legacyPresent && value != legacy {
			return "", errors.New("conflicting VLESS decryption fields")
		}
	}
	if err := ValidateVLESSDecryption(value); err != nil {
		return "", err
	}
	return value, nil
}

func ValidateVLESSDecryption(value string) error {
	invalid := errors.New("invalid VLESS decryption configuration")
	if value == "none" {
		return nil
	}
	parts := strings.Split(value, ".")
	if len(parts) < 4 || parts[0] != "mlkem768x25519plus" {
		return invalid
	}
	if parts[1] != "native" && parts[1] != "xorpub" && parts[1] != "random" {
		return invalid
	}
	ticket := strings.TrimSuffix(parts[2], "s")
	if ticket == parts[2] {
		return invalid
	}
	bounds := strings.Split(ticket, "-")
	if len(bounds) > 2 {
		return invalid
	}
	var previous uint64
	for i, bound := range bounds {
		seconds, err := strconv.ParseUint(bound, 10, 32)
		if err != nil || seconds == 0 || (i > 0 && seconds < previous) {
			return invalid
		}
		previous = seconds
	}
	keys := 0
	for _, part := range parts[3:] {
		if len(part) < 20 && vlessPaddingPattern.MatchString(part) {
			continue
		}
		key, err := base64.RawURLEncoding.DecodeString(part)
		if err != nil || (len(key) != 32 && len(key) != 64) {
			return invalid
		}
		keys++
	}
	if keys == 0 {
		return invalid
	}
	return nil
}
