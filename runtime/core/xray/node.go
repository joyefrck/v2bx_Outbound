package xray

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"

	"github.com/InazumaV/V2bX/api/panel"
	"github.com/InazumaV/V2bX/conf"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/inbound"
	"github.com/xtls/xray-core/features/outbound"
)

type DNSConfig struct {
	Servers []interface{} `json:"servers"`
	Tag     string        `json:"tag"`
}

func (c *Xray) ValidateNode(tag string, info *panel.NodeInfo, config *conf.Options) error {
	if info.Type == "vless" {
		if info.VAllss == nil || info.Security < panel.None || info.Security > panel.Reality {
			return errors.New("invalid VLESS security configuration")
		}
		if info.Common == nil || info.Common.ServerPort < 1 || info.Common.ServerPort > 65535 {
			return errors.New("invalid VLESS listen port")
		}
		flow := info.VAllss.Flow
		if flow != "" && flow != "none" && flow != "xtls-rprx-vision" {
			return errors.New("invalid VLESS flow")
		}
		if flow == "xtls-rprx-vision" && (info.VAllss.Network != "tcp" || info.Security == panel.None) {
			return errors.New("Vision requires TCP with TLS or REALITY")
		}
	}
	if config.XrayOptions == nil {
		return errors.New("missing Xray options")
	}
	if info.Security == panel.Tls && (config.CertConfig == nil || config.CertConfig.CertMode == "" || config.CertConfig.CertMode == "none") {
		return errors.New("TLS node requires configured certificate files")
	}
	if _, err := compileDNSConfig(info.RawDNS); err != nil {
		return err
	}
	if _, err := buildInbound(config, info, tag); err != nil {
		return errors.New("invalid Xray inbound configuration")
	}
	if _, err := buildOutbound(config, tag); err != nil {
		return errors.New("invalid Xray outbound configuration")
	}
	if info.Security == panel.Tls && config.CertConfig != nil && config.CertConfig.CertMode != "" && config.CertConfig.CertMode != "none" {
		if _, err := tls.LoadX509KeyPair(config.CertConfig.CertFile, config.CertConfig.KeyFile); err != nil {
			return errors.New("invalid TLS certificate files")
		}
	}
	return nil
}

func (c *Xray) AddNode(tag string, info *panel.NodeInfo, config *conf.Options) error {
	err := updateDNSConfig(info)
	if err != nil {
		return fmt.Errorf("build dns error: %s", err)
	}
	inboundConfig, err := buildInbound(config, info, tag)
	if err != nil {
		return fmt.Errorf("build inbound error: %s", err)
	}
	err = c.addInbound(inboundConfig)
	if err != nil {
		return fmt.Errorf("add inbound error: %s", err)
	}
	outBoundConfig, err := buildOutbound(config, tag)
	if err != nil {
		_ = c.removeInbound(tag)
		return fmt.Errorf("build outbound error: %s", err)
	}
	err = c.addOutbound(outBoundConfig)
	if err != nil {
		_ = c.removeInbound(tag)
		return fmt.Errorf("add outbound error: %s", err)
	}
	c.users.mapLock.Lock()
	c.nodeReportMinTrafficBytes[tag] = config.ReportMinTraffic * 1024
	c.users.mapLock.Unlock()
	return nil
}

func (c *Xray) addInbound(config *core.InboundHandlerConfig) error {
	rawHandler, err := core.CreateObject(c.Server, config)
	if err != nil {
		return err
	}
	handler, ok := rawHandler.(inbound.Handler)
	if !ok {
		return fmt.Errorf("not an InboundHandler: %s", err)
	}
	if err := c.ihm.AddHandler(context.Background(), handler); err != nil {
		if active, _ := c.ihm.GetHandler(context.Background(), config.Tag); active == handler {
			_ = c.removeInbound(config.Tag)
		} else {
			_ = handler.Close()
		}
		return err
	}
	return nil
}

func (c *Xray) addOutbound(config *core.OutboundHandlerConfig) error {
	rawHandler, err := core.CreateObject(c.Server, config)
	if err != nil {
		return err
	}
	handler, ok := rawHandler.(outbound.Handler)
	if !ok {
		return fmt.Errorf("not an InboundHandler: %s", err)
	}
	if err := c.ohm.AddHandler(context.Background(), handler); err != nil {
		if c.ohm.GetHandler(config.Tag) == handler {
			_ = c.removeOutbound(config.Tag)
		} else {
			_ = handler.Close()
		}
		return err
	}
	return nil
}

func (c *Xray) DelNode(tag string) error {
	var result error
	if _, err := c.ihm.GetHandler(context.Background(), tag); err == nil {
		result = errors.Join(result, c.removeInbound(tag))
	}
	if c.ohm.GetHandler(tag) != nil {
		result = errors.Join(result, c.removeOutbound(tag))
	}
	if result == nil {
		c.retireNodeUsers(tag)
	}
	return result
}

func (c *Xray) removeInbound(tag string) error {
	return c.ihm.RemoveHandler(context.Background(), tag)
}

func (c *Xray) removeOutbound(tag string) error {
	err := c.ohm.RemoveHandler(context.Background(), tag)
	return err
}
