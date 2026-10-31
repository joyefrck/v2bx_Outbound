package xray

import (
	"bytes"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"github.com/InazumaV/V2bX/api/panel"
	"github.com/InazumaV/V2bX/conf"
	coreConf "github.com/xtls/xray-core/infra/conf"
)

func compileDNSConfig(raw panel.RawDNS) ([]byte, error) {
	var data []byte
	if len(raw.DNSJson) != 0 {
		var formatted bytes.Buffer
		if err := json.Indent(&formatted, raw.DNSJson, "", " "); err != nil {
			return nil, errors.New("invalid panel DNS JSON")
		}
		data = formatted.Bytes()
	} else if len(raw.DNSMap) != 0 {
		config := DNSConfig{Servers: []interface{}{"https+local://1.1.1.1/dns-query", "https+local://8.8.8.8/dns-query"}, Tag: "dns_inbound"}
		keys := make([]string, 0, len(raw.DNSMap))
		for key := range raw.DNSMap {
			keys = append(keys, key)
		}
		slices.Sort(keys)
		for _, key := range keys {
			value := make(map[string]interface{})
			for k, v := range raw.DNSMap[key] {
				value[k] = v
			}
			address, ok := value["address"].(string)
			if !ok {
				return nil, errors.New("invalid panel DNS address")
			}
			if strings.Contains(address, ":") && !strings.Contains(address, "/") && net.ParseIP(address) == nil {
				host, port, err := net.SplitHostPort(address)
				if err != nil {
					return nil, errors.New("invalid panel DNS endpoint")
				}
				number, err := strconv.ParseUint(port, 10, 16)
				if err != nil || number == 0 {
					return nil, errors.New("invalid panel DNS port")
				}
				value["address"], value["port"] = host, uint16(number)
			}
			config.Servers = append(config.Servers, value)
		}
		var err error
		data, err = json.MarshalIndent(config, "", "  ")
		if err != nil {
			return nil, errors.New("invalid panel DNS configuration")
		}
	} else {
		return nil, nil
	}
	config := &coreConf.DNSConfig{}
	if err := json.Unmarshal(data, config); err != nil {
		return nil, errors.New("invalid panel DNS configuration")
	}
	if _, err := config.Build(); err != nil {
		return nil, errors.New("invalid panel DNS configuration")
	}
	return data, nil
}

func updateDNSConfig(node *panel.NodeInfo) error {
	data, err := compileDNSConfig(node.RawDNS)
	if err != nil || data == nil {
		return err
	}
	return saveDnsConfig(data, os.Getenv("XRAY_DNS_PATH"))
}

func saveDnsConfig(data []byte, path string) error {
	current, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if bytes.Equal(current, data) {
		return nil
	}
	return writeDNSConfig(path, data)
}

func writeDNSConfig(path string, data []byte) error {
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return err
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(resolved), ".v2bx-dns-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	if err := file.Chmod(info.Mode().Perm()); err != nil {
		return err
	}
	if _, err := file.Write(data); err != nil {
		return err
	}
	if err := file.Sync(); err != nil {
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	return os.Rename(file.Name(), resolved)
}

func (c *Xray) SnapshotNodeState(_ string, _ *panel.NodeInfo, _ *conf.Options) (func() error, error) {
	path := os.Getenv("XRAY_DNS_PATH")
	if path == "" {
		return func() error { return nil }, nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return func() error { return writeDNSConfig(path, data) }, nil
}
