package node

import (
	"errors"
	"testing"

	"github.com/InazumaV/V2bX/api/panel"
	"github.com/InazumaV/V2bX/conf"
	core "github.com/InazumaV/V2bX/core"
	"github.com/InazumaV/V2bX/limiter"
)

type reloadCore struct {
	core.Core
	active, rejected *panel.NodeInfo
	failUsers        bool
	invalid          bool
	deletions        int
}

func (f *reloadCore) ValidateNode(_ string, _ *panel.NodeInfo, _ *conf.Options) error {
	if f.invalid {
		return errors.New("invalid candidate")
	}
	return nil
}

func (f *reloadCore) AddNode(_ string, n *panel.NodeInfo, _ *conf.Options) error {
	if n == f.rejected {
		return errors.New("candidate bind failed")
	}
	f.active = n
	return nil
}

func (f *reloadCore) DelNode(_ string) error {
	f.active = nil
	f.deletions++
	return nil
}

func (f *reloadCore) AddUsers(p *core.AddUsersParams) (int, error) {
	if f.failUsers && p.NodeInfo != f.rejected {
		f.failUsers = false
		return 0, errors.New("user setup failed")
	}
	return len(p.Users), nil
}

func (f *reloadCore) GetUserTrafficSlice(_ string, _ bool) ([]panel.UserTraffic, error) {
	return nil, nil
}

func TestVLESSReloadRestoresPreviousNode(t *testing.T) {
	for _, mode := range []string{"invalid", "invalid-rule", "bind", "users", "success"} {
		t.Run(mode, func(t *testing.T) {
			limiter.Init()
			old := &panel.NodeInfo{Type: "vless", VAllss: &panel.VAllssNode{Network: "tcp"}}
			candidate := &panel.NodeInfo{Type: "vless", VAllss: &panel.VAllssNode{Network: "tcp"}}
			if mode == "invalid-rule" {
				candidate.Rules.Regexp = []string{"["}
			}
			users := []panel.UserInfo{{Id: 1, Uuid: "test-user"}}
			f := &reloadCore{active: old, invalid: mode == "invalid", failUsers: mode == "users"}
			if mode == "bind" {
				f.rejected = candidate
			}
			c := &Controller{server: f, tag: "node", info: old, userList: users, Options: &conf.Options{Name: "node"}}
			c.limiter = limiter.AddLimiter(c.tag, &c.LimitConfig, users, nil)
			oldLimiter := c.limiter
			err := c.replaceVLESSNode(candidate, users, nil)
			if mode == "success" {
				if err != nil || f.active != candidate || c.info != candidate {
					t.Fatalf("candidate not applied: %v", err)
				}
			} else if err == nil || f.active != old || c.info != old || c.limiter != oldLimiter {
				t.Fatalf("failed reload did not preserve old state: %v", err)
			}
			if (mode == "invalid" || mode == "invalid-rule") && f.deletions != 0 {
				t.Fatal("preflight removed a healthy listener")
			}
		})
	}
}

func TestPendingTrafficAggregatesSameUser(t *testing.T) {
	result := mergeUserTraffic([]panel.UserTraffic{{UID: 2, Upload: 10, Download: 20}}, []panel.UserTraffic{{UID: 2, Upload: 30, Download: 40}})
	if len(result) != 1 || result[0].Upload != 40 || result[0].Download != 60 {
		t.Fatalf("lost pending traffic: %+v", result)
	}
}
