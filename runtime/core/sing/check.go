package sing

import (
	"context"
	"fmt"
	"github.com/InazumaV/V2bX/conf"
	vCore "github.com/InazumaV/V2bX/core"
	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json"
	"github.com/sagernet/sing/service"
	"os"
)

func init() { vCore.RegisterConfigValidator("sing", checkConfig) }
func checkConfig(c *conf.CoreConfig) error {
	if c.SingConfig == nil {
		return fmt.Errorf("missing sing-box settings")
	}
	if c.SingConfig.OriginalPath == "" {
		return nil
	}
	data, err := os.ReadFile(c.SingConfig.OriginalPath)
	if err != nil {
		return err
	}
	data, err = normalizeLegacyConfig(data)
	if err != nil {
		return err
	}
	ctx := service.ContextWithDefaultRegistry(context.Background())
	ctx = box.Context(ctx, include.InboundRegistry(), include.OutboundRegistry(), include.EndpointRegistry(), include.DNSTransportRegistry(), include.ServiceRegistry(), include.CertificateProviderRegistry())
	_, err = json.UnmarshalExtendedContext[option.Options](ctx, data)
	return err
}
