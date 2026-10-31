package xray

import (
	"context"
	"fmt"
	"strings"

	"github.com/InazumaV/V2bX/api/panel"
	"github.com/InazumaV/V2bX/common/counter"
	"github.com/InazumaV/V2bX/common/format"
	vCore "github.com/InazumaV/V2bX/core"
	"github.com/InazumaV/V2bX/core/xray/app/dispatcher"
	"github.com/xtls/xray-core/common/protocol"
	"github.com/xtls/xray-core/proxy"
)

func (c *Xray) GetUserManager(tag string) (proxy.UserManager, error) {
	handler, err := c.ihm.GetHandler(context.Background(), tag)
	if err != nil {
		return nil, fmt.Errorf("no such inbound tag: %s", err)
	}
	inboundInstance, ok := handler.(proxy.GetInbound)
	if !ok {
		return nil, fmt.Errorf("handler %s is not implement proxy.GetInbound", tag)
	}
	userManager, ok := inboundInstance.GetInbound().(proxy.UserManager)
	if !ok {
		return nil, fmt.Errorf("handler %s is not implement proxy.UserManager", tag)
	}
	return userManager, nil
}

func (c *Xray) DelUsers(users []panel.UserInfo, tag string, _ *panel.NodeInfo) error {
	userManager, err := c.GetUserManager(tag)
	if err != nil {
		return fmt.Errorf("get user manager error: %s", err)
	}
	var user string
	c.users.mapLock.Lock()
	defer c.users.mapLock.Unlock()
	for i := range users {
		user = format.UserTag(tag, users[i].Uuid)
		if userManager.GetUser(context.Background(), user) != nil {
			if err := userManager.RemoveUser(context.Background(), user); err != nil {
				return err
			}
		}
		c.dispatcher.AllowedUsers.Delete(user)
		if v, ok := c.dispatcher.LinkManagers.Load(user); ok {
			lm := v.(*dispatcher.LinkManager)
			lm.CloseAll()
			c.dispatcher.LinkManagers.Delete(user)
		}
		c.retainUserTraffic(tag, user, c.users.uidMap[user])
		delete(c.users.uidMap, user)
		if v, ok := c.dispatcher.Counter.Load(tag); ok {
			v.(*counter.TrafficCounter).Delete(user)
		}

	}
	return nil
}

func (x *Xray) GetUserTrafficSlice(tag string, reset bool) ([]panel.UserTraffic, error) {
	x.users.mapLock.Lock()
	defer x.users.mapLock.Unlock()
	trafficSlice := append([]panel.UserTraffic(nil), x.retiredTraffic[tag]...)
	if reset {
		delete(x.retiredTraffic, tag)
	}
	if v, ok := x.dispatcher.Counter.Load(tag); ok {
		c := v.(*counter.TrafficCounter)
		c.Counters.Range(func(key, value interface{}) bool {
			email := key.(string)
			traffic := value.(*counter.TrafficStorage)
			up := traffic.UpCounter.Load()
			down := traffic.DownCounter.Load()
			if up+down > x.nodeReportMinTrafficBytes[tag] {
				if reset {
					up = traffic.UpCounter.Swap(0)
					down = traffic.DownCounter.Swap(0)
				}
				if x.users.uidMap[email] == 0 {
					c.Delete(email)
					return true
				}
				trafficSlice = append(trafficSlice, panel.UserTraffic{
					UID:      x.users.uidMap[email],
					Upload:   up,
					Download: down,
				})
			}
			return true
		})
		if len(trafficSlice) == 0 {
			return nil, nil
		}
		return trafficSlice, nil
	}
	return trafficSlice, nil
}

func (c *Xray) AddUsers(p *vCore.AddUsersParams) (added int, err error) {
	c.users.mapLock.Lock()
	defer c.users.mapLock.Unlock()
	var users []*protocol.User
	switch p.NodeInfo.Type {
	case "vmess":
		users = buildVmessUsers(p.Tag, p.Users)
	case "vless":
		users = buildVlessUsers(p.Tag, p.Users, p.VAllss.Flow)
	case "trojan":
		users = buildTrojanUsers(p.Tag, p.Users)
	case "shadowsocks":
		users = buildSSUsers(p.Tag,
			p.Users,
			p.Shadowsocks.Cipher,
			p.Shadowsocks.ServerKey)
	default:
		return 0, fmt.Errorf("unsupported node type: %s", p.NodeInfo.Type)
	}
	man, err := c.GetUserManager(p.Tag)
	if err != nil {
		return 0, fmt.Errorf("get user manager error: %s", err)
	}
	memoryUsers := make([]*protocol.MemoryUser, 0, len(users))
	for _, u := range users {
		mUser, err := u.ToMemoryUser()
		if err != nil {
			return 0, fmt.Errorf("invalid user configuration")
		}
		memoryUsers = append(memoryUsers, mUser)
	}
	installed := make([]string, 0, len(users))
	for _, u := range memoryUsers {
		if err := man.AddUser(context.Background(), u); err != nil {
			for _, email := range installed {
				_ = man.RemoveUser(context.Background(), email)
			}
			return 0, fmt.Errorf("could not install users")
		}
		installed = append(installed, u.Email)
	}
	for i := range p.Users {
		email := format.UserTag(p.Tag, p.Users[i].Uuid)
		c.users.uidMap[email] = p.Users[i].Id
		c.dispatcher.LinkManagers.Delete(email)
		c.dispatcher.AllowedUsers.Store(email, true)
	}
	return len(users), nil
}

func (c *Xray) retireNodeUsers(tag string) {
	c.users.mapLock.Lock()
	defer c.users.mapLock.Unlock()
	prefix := tag + "|"
	for email, uid := range c.users.uidMap {
		if !strings.HasPrefix(email, prefix) {
			continue
		}
		c.dispatcher.AllowedUsers.Delete(email)
		if v, ok := c.dispatcher.LinkManagers.LoadAndDelete(email); ok {
			v.(*dispatcher.LinkManager).CloseAll()
		}
		c.retainUserTraffic(tag, email, uid)
		delete(c.users.uidMap, email)
	}
	c.dispatcher.Counter.Delete(tag)
	delete(c.nodeReportMinTrafficBytes, tag)
}

func (c *Xray) retainUserTraffic(tag, email string, uid int) {
	if v, ok := c.dispatcher.Counter.Load(tag); ok {
		if value, ok := v.(*counter.TrafficCounter).Counters.Load(email); ok {
			counts := value.(*counter.TrafficStorage)
			up, down := counts.UpCounter.Swap(0), counts.DownCounter.Swap(0)
			if up+down > 0 {
				c.retiredTraffic[tag] = append(c.retiredTraffic[tag], panel.UserTraffic{UID: uid, Upload: up, Download: down})
			}
		}
	}
}
