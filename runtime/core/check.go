package core

import (
	"fmt"
	"github.com/InazumaV/V2bX/conf"
)

var validators = map[string]func(*conf.CoreConfig) error{}
var nodeValidators = map[string]func(*conf.Options) error{}

func RegisterNodeConfigValidator(name string, validate func(*conf.Options) error) {
	nodeValidators[name] = validate
}

func RegisterConfigValidator(name string, validate func(*conf.CoreConfig) error) {
	validators[name] = validate
}
func CheckConfig(c *conf.Conf) error {
	if len(c.CoresConfig) == 0 {
		return fmt.Errorf("no cores configured")
	}
	names := map[string]string{}
	types := map[string]bool{}
	for i := range c.CoresConfig {
		cfg := &c.CoresConfig[i]
		name := cfg.Name
		if name == "" {
			name = cfg.Type
		}
		if _, exists := names[name]; exists {
			return fmt.Errorf("duplicate core name %q", name)
		}
		names[name] = cfg.Type
		types[cfg.Type] = true
		validate, ok := validators[cfg.Type]
		if !ok {
			return fmt.Errorf("unsupported core %q", cfg.Type)
		}
		if err := validate(cfg); err != nil {
			return fmt.Errorf("core %d (%s): %w", i, cfg.Type, err)
		}
	}
	for i, n := range c.NodeConfig {
		chosen := n.Options.Core
		if n.Options.CoreName != "" {
			var ok bool
			chosen, ok = names[n.Options.CoreName]
			if !ok {
				return fmt.Errorf("node %d: unknown CoreName", i)
			}
		}
		if chosen == "" && len(c.CoresConfig) == 1 {
			chosen = c.CoresConfig[0].Type
		}
		if chosen != "" && !types[chosen] {
			return fmt.Errorf("node %d: core not configured", i)
		}
		if n.Options.Core == "" && chosen != "" && len(n.Options.RawOptions) > 0 {
			n.Options.Core = chosen
			if err := n.Options.UnmarshalJSON(n.Options.RawOptions); err != nil {
				return fmt.Errorf("node %d options: %w", i, err)
			}
		}
		if validate, ok := nodeValidators[chosen]; ok {
			if err := validate(&n.Options); err != nil {
				return fmt.Errorf("node %d: %w", i, err)
			}
		}
		if n.Options.XrayOptions != nil && n.Options.XrayOptions.DisableIVCheck {
			return fmt.Errorf("node %d: DisableIVCheck is no longer supported", i)
		}
		if n.ApiConfig.NodeID <= 0 || n.ApiConfig.APIHost == "" || n.ApiConfig.Key == "" {
			return fmt.Errorf("node %d: missing panel settings", i)
		}
		if n.Options.Core != "" {
			if _, ok := validators[n.Options.Core]; !ok {
				return fmt.Errorf("node %d: core unavailable", i)
			}
		}
	}
	return nil
}
