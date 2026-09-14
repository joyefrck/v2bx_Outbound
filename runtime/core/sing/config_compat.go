package sing

import (
	"bytes"
	"encoding/json"
	"fmt"
	"github.com/InazumaV/V2bX/common/json5"
	"io"
	"net/netip"
)

// normalizeLegacyConfig migrates only the old manager's well-defined DNS/block
// forms in memory. It never rewrites the operator's config or changes rule order.
func normalizeLegacyConfig(data []byte) ([]byte, error) {
	clean, err := io.ReadAll(json5.NewTrimNodeReader(bytes.NewReader(data)))
	if err != nil {
		return nil, err
	}
	var config map[string]any
	if err = json.Unmarshal(clean, &config); err != nil {
		return nil, err
	}
	blocks := map[string]bool{}
	outbounds, _ := config["outbounds"].([]any)
	kept := make([]any, 0, len(outbounds))
	for _, entry := range outbounds {
		outbound, ok := entry.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("invalid outbound")
		}
		if outbound["type"] != "block" {
			kept = append(kept, entry)
			continue
		}
		tag, ok := outbound["tag"].(string)
		if !ok || tag == "" || len(outbound) != 2 {
			return nil, fmt.Errorf("legacy block outbound requires manual migration")
		}
		blocks[tag] = true
	}
	if len(blocks) > 0 {
		config["outbounds"] = kept
		route, _ := config["route"].(map[string]any)
		if final, _ := route["final"].(string); blocks[final] {
			return nil, fmt.Errorf("legacy block route.final requires manual migration")
		}
		var rewrite func([]any) error
		rewrite = func(rules []any) error {
			for _, entry := range rules {
				rule, ok := entry.(map[string]any)
				if !ok {
					return fmt.Errorf("invalid route rule")
				}
				if nested, ok := rule["rules"].([]any); ok {
					if e := rewrite(nested); e != nil {
						return e
					}
				}
				target, _ := rule["outbound"].(string)
				if blocks[target] {
					if action, ok := rule["action"].(string); ok && action != "route" {
						return fmt.Errorf("conflicting legacy block action")
					}
					delete(rule, "outbound")
					rule["action"] = "reject"
				}
			}
			return nil
		}
		if rules, ok := route["rules"].([]any); ok {
			if err = rewrite(rules); err != nil {
				return nil, err
			}
		}
		// References from selector/urltest groups would change semantics if removed.
		for _, entry := range kept {
			out := entry.(map[string]any)
			if members, ok := out["outbounds"].([]any); ok {
				for _, member := range members {
					if tag, ok := member.(string); ok && blocks[tag] {
						return nil, fmt.Errorf("legacy block group requires manual migration")
					}
				}
			}
		}
	}
	if dns, ok := config["dns"].(map[string]any); ok {
		if servers, ok := dns["servers"].([]any); ok {
			for _, entry := range servers {
				server, ok := entry.(map[string]any)
				if !ok {
					continue
				}
				address, legacy := server["address"].(string)
				if !legacy {
					continue
				}
				for field := range server {
					if field != "address" && field != "tag" {
						return nil, fmt.Errorf("legacy DNS options require manual migration")
					}
				}
				switch {
				case address == "local":
					server["type"] = "local"
				default:
					if _, err = netip.ParseAddr(address); err != nil {
						return nil, fmt.Errorf("legacy DNS address requires manual migration")
					}
					server["type"] = "udp"
					server["server"] = address
				}
				delete(server, "address")
			}
		}
	}
	return json.Marshal(config)
}
