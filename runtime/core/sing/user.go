package sing

import (
	"encoding/base64"
	"errors"
	"sort"
	"strings"

	"github.com/InazumaV/V2bX/api/panel"
	"github.com/InazumaV/V2bX/common/counter"
	"github.com/InazumaV/V2bX/core"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing-box/protocol/anytls"
	"github.com/sagernet/sing-box/protocol/hysteria"
	"github.com/sagernet/sing-box/protocol/hysteria2"
	"github.com/sagernet/sing-box/protocol/shadowsocks"
	"github.com/sagernet/sing-box/protocol/trojan"
	"github.com/sagernet/sing-box/protocol/tuic"
	"github.com/sagernet/sing-box/protocol/vless"
	"github.com/sagernet/sing-box/protocol/vmess"
)

// User changes commit only after the authentication table accepts the entire snapshot.
func (b *Sing) AddUsers(p *core.AddUsersParams) (int, error) {
	b.managedMu.Lock()
	defer b.managedMu.Unlock()
	users := make(map[string]panel.UserInfo)
	for k, v := range b.managedUsers[p.Tag] {
		users[k] = v
	}
	for _, u := range p.Users {
		users[u.Uuid] = u
	}
	copyParams := *p
	copyParams.Users = sortedUsers(users)
	for _, u := range copyParams.Users {
		b.hookServer.activeUsers.Store(userKey(p.Tag, u.Uuid), true)
	}
	if err := b.setUsers(&copyParams); err != nil {
		for uuid := range users {
			if _, old := b.managedUsers[p.Tag][uuid]; !old {
				b.hookServer.revoke(p.Tag, uuid)
			}
		}
		return 0, err
	}
	b.managedUsers[p.Tag] = users
	b.managedParams[p.Tag] = copyParams
	b.users.mapLock.Lock()
	defer b.users.mapLock.Unlock()
	for _, u := range copyParams.Users {
		b.users.uidMap[p.Tag+"\x00"+u.Uuid] = u.Id
	}
	return len(p.Users), nil
}

func sortedUsers(users map[string]panel.UserInfo) []panel.UserInfo {
	keys := make([]string, 0, len(users))
	for k := range users {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	out := make([]panel.UserInfo, 0, len(keys))
	for _, k := range keys {
		out = append(out, users[k])
	}
	return out
}

func (b *Sing) setUsers(p *core.AddUsersParams) error {
	in, found := b.box.Inbound().Get(p.Tag)
	if !found {
		return errors.New("inbound not found")
	}
	var err error
	switch p.NodeInfo.Type {
	case "vless":
		us := make([]option.VLESSUser, len(p.Users))
		for i := range p.Users {
			us[i] = option.VLESSUser{
				Name: p.Users[i].Uuid,
				Flow: p.VAllss.Flow,
				UUID: p.Users[i].Uuid,
			}
		}
		err = in.(*vless.Inbound).SetManagedUsers(us)
	case "vmess":
		us := make([]option.VMessUser, len(p.Users))
		for i := range p.Users {
			us[i] = option.VMessUser{
				Name: p.Users[i].Uuid,
				UUID: p.Users[i].Uuid,
			}
		}
		err = in.(*vmess.Inbound).SetManagedUsers(us)
	case "shadowsocks":
		us := make([]option.ShadowsocksUser, len(p.Users))
		for i := range p.Users {
			var password = p.Users[i].Uuid
			if len(password) < 32 && strings.HasPrefix(p.Shadowsocks.Cipher, "2022-") {
				return errors.New("invalid Shadowsocks 2022 user key")
			}
			switch p.Shadowsocks.Cipher {
			case "2022-blake3-aes-128-gcm":
				password = base64.StdEncoding.EncodeToString([]byte(password[:16]))
			case "2022-blake3-aes-256-gcm":
				password = base64.StdEncoding.EncodeToString([]byte(password[:32]))
			}
			us[i] = option.ShadowsocksUser{
				Name:     p.Users[i].Uuid,
				Password: password,
			}
		}
		err = in.(*shadowsocks.MultiInbound).SetManagedUsers(us)
	case "trojan":
		us := make([]option.TrojanUser, len(p.Users))
		for i := range p.Users {
			us[i] = option.TrojanUser{
				Name:     p.Users[i].Uuid,
				Password: p.Users[i].Uuid,
			}
		}
		err = in.(*trojan.Inbound).SetManagedUsers(us)
	case "tuic":
		us := make([]option.TUICUser, len(p.Users))

		for i := range p.Users {
			us[i] = option.TUICUser{
				Name:     p.Users[i].Uuid,
				UUID:     p.Users[i].Uuid,
				Password: p.Users[i].Uuid,
			}

		}
		err = in.(*tuic.Inbound).SetManagedUsers(us)
	case "hysteria":
		us := make([]option.HysteriaUser, len(p.Users))
		for i := range p.Users {
			us[i] = option.HysteriaUser{
				Name:       p.Users[i].Uuid,
				AuthString: p.Users[i].Uuid,
			}
		}
		err = in.(*hysteria.Inbound).SetManagedUsers(us)
	case "hysteria2":
		us := make([]option.Hysteria2User, len(p.Users))

		for i := range p.Users {
			us[i] = option.Hysteria2User{
				Name:     p.Users[i].Uuid,
				Password: p.Users[i].Uuid,
			}

		}
		err = in.(*hysteria2.Inbound).SetManagedUsers(us)
	case "anytls":
		us := make([]option.AnyTLSUser, len(p.Users))
		for i := range p.Users {
			us[i] = option.AnyTLSUser{
				Name:     p.Users[i].Uuid,
				Password: p.Users[i].Uuid,
			}
		}
		err = in.(*anytls.Inbound).SetManagedUsers(us)
	}
	return err
}

func (b *Sing) GetUserTraffic(tag, uuid string, reset bool) (up int64, down int64) {
	if v, ok := b.hookServer.counter.Load(tag); ok {
		c := v.(*counter.TrafficCounter)
		up = c.GetUpCount(uuid)
		down = c.GetDownCount(uuid)
		if reset {
			c.Reset(uuid)
		}
		return
	}
	return 0, 0
}

func (b *Sing) GetUserTrafficSlice(tag string, reset bool) ([]panel.UserTraffic, error) {
	b.managedMu.Lock()
	defer b.managedMu.Unlock()
	trafficSlice := make([]panel.UserTraffic, 0)
	hook := b.hookServer
	b.users.mapLock.RLock()
	defer b.users.mapLock.RUnlock()
	if v, ok := hook.counter.Load(tag); ok {
		c := v.(*counter.TrafficCounter)
		c.Counters.Range(func(key, value interface{}) bool {
			uuid := key.(string)
			traffic := value.(*counter.TrafficStorage)
			up := traffic.UpCounter.Load()
			down := traffic.DownCounter.Load()
			if up+down > b.nodeReportMinTrafficBytes[tag] {
				if reset {
					up = traffic.UpCounter.Swap(0)
					down = traffic.DownCounter.Swap(0)
				}
				if b.users.uidMap[tag+"\x00"+uuid] == 0 {
					c.Delete(uuid)
					return true
				}
				trafficSlice = append(trafficSlice, panel.UserTraffic{
					UID:      b.users.uidMap[tag+"\x00"+uuid],
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
	return nil, nil
}

func (b *Sing) DelUsers(users []panel.UserInfo, tag string, _ *panel.NodeInfo) error {
	b.managedMu.Lock()
	defer b.managedMu.Unlock()
	params, ok := b.managedParams[tag]
	if !ok {
		return errors.New("inbound user state not found")
	}
	remaining := make(map[string]panel.UserInfo)
	for k, v := range b.managedUsers[tag] {
		remaining[k] = v
	}
	for _, u := range users {
		delete(remaining, u.Uuid)
	}
	params.Users = sortedUsers(remaining)
	if err := b.setUsers(&params); err != nil {
		return err
	}
	b.managedUsers[tag] = remaining
	b.managedParams[tag] = params
	b.users.mapLock.Lock()
	defer b.users.mapLock.Unlock()
	for _, u := range users {
		b.hookServer.revoke(tag, u.Uuid)
		delete(b.users.uidMap, tag+"\x00"+u.Uuid)
		if v, ok := b.hookServer.counter.Load(tag); ok {
			v.(*counter.TrafficCounter).Delete(u.Uuid)
		}
	}
	return nil
}
