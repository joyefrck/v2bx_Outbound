// Package configjson normalizes local HY2 configuration without starting a core.
package configjson

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"

	"gopkg.in/yaml.v3"
)

const maxConfigSize = 16 << 20

func Normalize(r io.Reader) ([]byte, error) {
	data, err := io.ReadAll(io.LimitReader(r, maxConfigSize+1))
	if err != nil || len(data) > maxConfigSize {
		return nil, errors.New("cannot read HY2 config or config exceeds 16 MiB")
	}
	d := yaml.NewDecoder(bytes.NewReader(data))
	var node, extra yaml.Node
	if d.Decode(&node) != nil || len(node.Content) != 1 || node.Content[0].Kind != yaml.MappingNode {
		return nil, errors.New("HY2 config must contain one mapping")
	}
	if d.Decode(&extra) != io.EOF || !plainNode(&node) {
		return nil, errors.New("HY2 config cannot contain multiple documents, aliases or custom tags")
	}
	var value map[string]interface{}
	if node.Decode(&value) != nil {
		// Parser diagnostics may include passwords from the input. Keep errors generic.
		return nil, errors.New("invalid HY2 config (check duplicate keys and value types)")
	}
	out, err := json.Marshal(value)
	if err != nil {
		return nil, errors.New("HY2 config cannot be represented as JSON")
	}
	return append(out, '\n'), nil
}

func plainNode(n *yaml.Node) bool {
	if n.Kind == yaml.AliasNode || n.Anchor != "" {
		return false
	}
	switch n.Tag {
	case "", "!!map", "!!seq", "!!str", "!!bool", "!!null", "!!int", "!!float":
	default:
		return false
	}
	for _, child := range n.Content {
		if !plainNode(child) {
			return false
		}
	}
	return true
}
