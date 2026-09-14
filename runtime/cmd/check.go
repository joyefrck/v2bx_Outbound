package cmd

import (
	"encoding/json"
	"fmt"
	"github.com/InazumaV/V2bX/common/json5"
	"github.com/InazumaV/V2bX/conf"
	"github.com/InazumaV/V2bX/core"
	"github.com/spf13/cobra"
	"io"
	"os"
)

// Preflight never constructs or starts a core, fetches a panel, or applies config.
// Includes need manual review: automatic upgrades must not dereference remote input.
func checkConfig(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(json5.NewTrimNodeReader(f), 16<<20))
	if err != nil {
		return err
	}
	var raw struct{ Nodes []struct{ Include string } }
	if err = json.Unmarshal(data, &raw); err != nil {
		return err
	}
	for _, n := range raw.Nodes {
		if n.Include != "" {
			return fmt.Errorf("Include requires manual migration before automatic upgrade")
		}
	}
	c := conf.New()
	if err = json.Unmarshal(data, c); err != nil {
		return err
	}
	return core.CheckConfig(c)
}
func init() {
	var path string
	c := &cobra.Command{Use: "check-config", Short: "Offline configuration preflight (no panel requests or listeners)", Args: cobra.NoArgs, RunE: func(c *cobra.Command, _ []string) error {
		if err := checkConfig(path); err != nil {
			return err
		}
		fmt.Fprintln(c.OutOrStdout(), "Local configuration preflight passed; panel and protocol health require service validation.")
		return nil
	}}
	c.Flags().StringVarP(&path, "config", "c", "/etc/V2bX/config.json", "config file path")
	command.AddCommand(c)
}
