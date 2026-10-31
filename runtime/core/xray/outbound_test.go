package xray

import (
	"testing"

	"github.com/InazumaV/V2bX/conf"
	"github.com/xtls/xray-core/proxy/freedom"
)

func TestPrivateNetworkAccessIsExplicit(t *testing.T) {
	options := &conf.Options{XrayOptions: conf.NewXrayOptions()}
	for _, allowed := range []bool{false, true} {
		options.XrayOptions.AllowPrivateNetwork = allowed
		outbound, err := buildOutbound(options, "test")
		if err != nil {
			t.Fatal(err)
		}
		settings, err := outbound.ProxySettings.GetInstance()
		if err != nil {
			t.Fatal(err)
		}
		config := settings.(*freedom.Config)
		if (len(config.FinalRules) != 0) != allowed {
			t.Fatal("private-network policy does not match explicit option")
		}
	}
}
