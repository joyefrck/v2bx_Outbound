package hy2

import (
	"fmt"
	"github.com/InazumaV/V2bX/conf"
	"github.com/InazumaV/V2bX/core"
	"github.com/spf13/viper"
)

func init() {
	core.RegisterNodeConfigValidator("hysteria2", func(options *conf.Options) error {
		if options.Hysteria2ConfigPath == "" {
			return nil
		}
		v := viper.New()
		v.SetConfigFile(options.Hysteria2ConfigPath)
		if err := v.ReadInConfig(); err != nil {
			return err
		}
		var parsed serverConfig
		return v.UnmarshalExact(&parsed)
	})
	core.RegisterConfigValidator("hysteria2", func(c *conf.CoreConfig) error {
		if c.Hysteria2Config == nil {
			return fmt.Errorf("missing Hysteria settings")
		}
		return nil
	})
}
