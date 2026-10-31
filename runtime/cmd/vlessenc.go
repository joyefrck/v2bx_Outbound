package cmd

import (
	"crypto/ecdh"
	"crypto/mlkem"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/spf13/cobra"
)

func generateVLESSParameters(auth string) (map[string]string, error) {
	var private, public []byte
	switch auth {
	case "x25519":
		key, err := ecdh.X25519().GenerateKey(rand.Reader)
		if err != nil {
			return nil, err
		}
		private, public = key.Bytes(), key.PublicKey().Bytes()
	case "mlkem768":
		key, err := mlkem.GenerateKey768()
		if err != nil {
			return nil, err
		}
		private, public = key.Bytes(), key.EncapsulationKey().Bytes()
	default:
		return nil, errors.New("authentication must be x25519 or mlkem768")
	}
	return map[string]string{
		"decryption": "mlkem768x25519plus.native.600s." + base64.RawURLEncoding.EncodeToString(private),
		"encryption": "mlkem768x25519plus.native.0rtt." + base64.RawURLEncoding.EncodeToString(public),
	}, nil
}

func init() {
	var auth string
	var jsonOutput bool
	c := &cobra.Command{
		Use: "vlessenc", Short: "Generate paired VLESS Encryption parameters locally", Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			params, err := generateVLESSParameters(auth)
			if err != nil {
				return err
			}
			if jsonOutput {
				return json.NewEncoder(cmd.OutOrStdout()).Encode(params)
			}
			_, err = fmt.Fprintf(cmd.OutOrStdout(), "decryption: %s\nencryption: %s\n", params["decryption"], params["encryption"])
			return err
		},
	}
	c.Flags().StringVar(&auth, "auth", "x25519", "Authentication key type: x25519 or mlkem768")
	c.Flags().BoolVar(&jsonOutput, "json", false, "Output a JSON parameter pair")
	command.AddCommand(c)
}
