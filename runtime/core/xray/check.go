package xray

import (
	"encoding/json"
	"fmt"
	"github.com/InazumaV/V2bX/conf"
	vCore "github.com/InazumaV/V2bX/core"
	coreConf "github.com/xtls/xray-core/infra/conf"
	"os"
)

func init() { vCore.RegisterConfigValidator("xray", checkConfig) }
func checkConfig(c *conf.CoreConfig) error {
	x := c.XrayConfig
	if x == nil {
		return fmt.Errorf("missing Xray settings")
	}
	os.Setenv("XRAY_LOCATION_ASSET", x.AssetPath)
	read := func(path string, target any) error {
		if path == "" {
			return nil
		}
		data, e := os.ReadFile(path)
		if e != nil {
			return e
		}
		return json.Unmarshal(data, target)
	}
	dns := &coreConf.DNSConfig{}
	if err := read(x.DnsConfigPath, dns); err != nil {
		return err
	}
	if _, err := dns.Build(); err != nil {
		return err
	}
	route := &coreConf.RouterConfig{}
	if err := read(x.RouteConfigPath, route); err != nil {
		return err
	}
	if _, err := route.Build(); err != nil {
		return err
	}
	var ins []coreConf.InboundDetourConfig
	if err := read(x.InboundConfigPath, &ins); err != nil {
		return err
	}
	for _, in := range ins {
		if _, err := in.Build(); err != nil {
			return err
		}
	}
	var outs []coreConf.OutboundDetourConfig
	if err := read(x.OutboundConfigPath, &outs); err != nil {
		return err
	}
	for _, out := range outs {
		if _, err := out.Build(); err != nil {
			return err
		}
	}
	return nil
}
