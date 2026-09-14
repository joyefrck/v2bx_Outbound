package cmd

import (
	"fmt"
	"github.com/spf13/cobra"
)

// System management belongs to the verified, locked shell manager. Imported
// upstream self-update/uninstall code must not bypass that transaction boundary.
func init() {
	for _, action := range []string{"update", "uninstall"} {
		command.AddCommand(&cobra.Command{Use: action, Short: "Use the integrated v2bx manager", Args: cobra.ArbitraryArgs, RunE: func(*cobra.Command, []string) error {
			return fmt.Errorf("please use `v2bx %s` through the installed manager", action)
		}})
	}
}
