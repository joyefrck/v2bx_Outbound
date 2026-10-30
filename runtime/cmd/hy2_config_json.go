package cmd

import (
	"os"

	"github.com/InazumaV/V2bX/common/configjson"
	"github.com/spf13/cobra"
)

func init() {
	var path string
	c := &cobra.Command{Use: "hy2-config-json", Short: "Read a local HY2 YAML/JSON config as JSON (no network or writes)", Args: cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			f, err := os.Open(path)
			if err != nil {
				return err
			}
			defer f.Close()
			data, err := configjson.Normalize(f)
			if err != nil {
				return err
			}
			_, err = c.OutOrStdout().Write(data)
			return err
		}}
	c.Flags().StringVarP(&path, "config", "c", "", "local config file path")
	_ = c.MarkFlagRequired("config")
	command.AddCommand(c)
}
