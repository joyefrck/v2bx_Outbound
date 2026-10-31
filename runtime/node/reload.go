package node

import (
	"errors"
	"fmt"

	"github.com/InazumaV/V2bX/api/panel"
	core "github.com/InazumaV/V2bX/core"
	"github.com/InazumaV/V2bX/limiter"
)

func (c *Controller) replaceVLESSNode(candidate *panel.NodeInfo, users []panel.UserInfo, alive map[int]int) error {
	validator, ok := c.server.(core.NodeValidator)
	if !ok {
		return errors.New("selected core does not provide VLESS preflight")
	}
	if err := validator.ValidateNode(c.tag, candidate, c.Options); err != nil {
		return fmt.Errorf("VLESS candidate rejected: %w", err)
	}
	trial := &limiter.Limiter{}
	if err := trial.UpdateRule(&candidate.Rules); err != nil {
		return errors.New("invalid VLESS candidate rules")
	}
	if _, err := c.flushUserTraffic(); err != nil {
		return fmt.Errorf("cannot preserve traffic before reload: %w", err)
	}
	unlock := core.LockNodeUpdates()
	defer unlock()
	restore := func() error { return nil }
	if snapshotter, ok := c.server.(core.NodeStateSnapshotter); ok {
		var err error
		restore, err = snapshotter.SnapshotNodeState(c.tag, c.info, c.Options)
		if err != nil {
			return errors.New("cannot snapshot previous node state")
		}
	}
	oldNode, oldUsers, oldLimiter := c.info, c.userList, c.limiter
	install := func(node *panel.NodeInfo, list []panel.UserInfo) error {
		if err := c.server.AddNode(c.tag, node, c.Options); err != nil {
			return errors.New("VLESS listener setup failed")
		}
		_, err := c.server.AddUsers(&core.AddUsersParams{Tag: c.tag, Users: list, NodeInfo: node})
		if err != nil {
			return errors.New("VLESS users setup failed")
		}
		return nil
	}
	if err := c.server.DelNode(c.tag); err != nil {
		_ = c.server.DelNode(c.tag)
		recovery := errors.Join(install(oldNode, oldUsers), restore())
		return errors.Join(errors.New("could not remove previous VLESS listener"), recovery)
	}
	c.limiter = limiter.AddLimiter(c.tag, &c.LimitConfig, users, alive)
	_ = c.limiter.UpdateRule(&candidate.Rules)
	if err := install(candidate, users); err != nil {
		_ = c.server.DelNode(c.tag)
		limiter.RestoreLimiter(c.tag, oldLimiter)
		c.limiter = oldLimiter
		recovery := install(oldNode, oldUsers)
		recovery = errors.Join(recovery, restore())
		if recovery != nil {
			return errors.Join(err, fmt.Errorf("previous VLESS listener restoration failed: %w", recovery))
		}
		return err
	}
	c.info, c.userList, c.aliveMap = candidate, users, alive
	if c.nodeInfoMonitorPeriodic != nil {
		c.nodeInfoMonitorPeriodic.SetInterval(candidate.PullInterval)
	}
	if c.userReportPeriodic != nil {
		c.userReportPeriodic.SetInterval(candidate.PushInterval)
	}
	if c.apiClient != nil {
		c.apiClient.AcceptNodeInfo(candidate)
		c.apiClient.AcceptUserList()
	}
	return nil
}

func (c *Controller) flushUserTraffic() ([]panel.UserTraffic, error) {
	traffic, err := c.server.GetUserTrafficSlice(c.tag, true)
	if err != nil {
		return nil, err
	}
	c.pendingTraffic = mergeUserTraffic(c.pendingTraffic, traffic)
	if len(c.pendingTraffic) == 0 {
		return nil, nil
	}
	if err := c.apiClient.ReportUserTraffic(c.pendingTraffic); err != nil {
		return nil, err
	}
	result := c.pendingTraffic
	c.pendingTraffic = nil
	return result, nil
}

func mergeUserTraffic(pending, next []panel.UserTraffic) []panel.UserTraffic {
	merged := make(map[int]panel.UserTraffic)
	for _, batch := range [][]panel.UserTraffic{pending, next} {
		for _, item := range batch {
			total := merged[item.UID]
			total.UID = item.UID
			total.Upload += item.Upload
			total.Download += item.Download
			merged[item.UID] = total
		}
	}
	result := make([]panel.UserTraffic, 0, len(merged))
	for _, item := range merged {
		result = append(result, item)
	}
	return result
}
