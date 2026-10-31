package core

import (
	"github.com/InazumaV/V2bX/api/panel"
	"github.com/InazumaV/V2bX/conf"
	"sync"
)

type AddUsersParams struct {
	Tag   string
	Users []panel.UserInfo
	*panel.NodeInfo
}

type Core interface {
	Start() error
	Close() error
	AddNode(tag string, info *panel.NodeInfo, config *conf.Options) error
	DelNode(tag string) error
	AddUsers(p *AddUsersParams) (added int, err error)
	GetUserTrafficSlice(tag string, reset bool) ([]panel.UserTraffic, error)
	DelUsers(users []panel.UserInfo, tag string, info *panel.NodeInfo) error
	Protocols() []string
	Type() string
}

type NodeValidator interface {
	ValidateNode(tag string, info *panel.NodeInfo, config *conf.Options) error
}

type NodeStateSnapshotter interface {
	SnapshotNodeState(tag string, info *panel.NodeInfo, options *conf.Options) (restore func() error, err error)
}

var nodeUpdateLock sync.Mutex

func LockNodeUpdates() func() {
	nodeUpdateLock.Lock()
	return sync.OnceFunc(nodeUpdateLock.Unlock)
}
