package core

import (
	"github.com/InazumaV/V2bX/api/panel"
	"github.com/InazumaV/V2bX/conf"
	"testing"
)

type snapshotCore struct {
	Core
	snapshots int
}

func (c *snapshotCore) Type() string { return "xray" }
func (c *snapshotCore) SnapshotNodeState(_ string, _ *panel.NodeInfo, _ *conf.Options) (func() error, error) {
	c.snapshots++
	return func() error { return nil }, nil
}

func TestSnapshotBeforeInitialAddSelectsCandidateCore(t *testing.T) {
	candidate := &snapshotCore{}
	selector := &Selector{cores: map[string]Core{"xray": candidate}}
	options := &conf.Options{Core: "xray"}
	restore, err := selector.SnapshotNodeState("new-node", &panel.NodeInfo{Type: "vless"}, options)
	if err != nil || restore == nil || candidate.snapshots != 1 {
		t.Fatalf("initial snapshot failed: %v", err)
	}
	if _, active := selector.nodes.Load("new-node"); active {
		t.Fatal("snapshot activated a node")
	}
}
