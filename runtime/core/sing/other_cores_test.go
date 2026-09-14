//go:build xray && hysteria2

package sing

import (
	"github.com/InazumaV/V2bX/api/panel"
	"github.com/InazumaV/V2bX/conf"
	vCore "github.com/InazumaV/V2bX/core"
	"github.com/InazumaV/V2bX/core/hy2"
	"github.com/InazumaV/V2bX/core/xray"
	"github.com/InazumaV/V2bX/limiter"
	"io"
	"net"
	"testing"
)

func TestOtherCores(t *testing.T) {
	limiter.Init()
	cert := testCertificate(t)
	target, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer target.Close()
	go func() {
		for {
			c, e := target.Accept()
			if e != nil {
				return
			}
			go func() { defer c.Close(); io.Copy(c, c) }()
		}
	}()
	for _, proto := range []string{"vless", "vmess", "shadowsocks", "trojan", "hysteria2"} {
		t.Run(proto, func(t *testing.T) {
			reserve, e := net.Listen("tcp", "127.0.0.1:0")
			if e != nil {
				t.Fatal(e)
			}
			port := reserve.Addr().(*net.TCPAddr).Port
			reserve.Close()
			info := &panel.NodeInfo{Type: proto, Common: &panel.CommonNode{ServerPort: port}, VAllss: &panel.VAllssNode{Network: "tcp"}, Shadowsocks: &panel.ShadowsocksNode{Cipher: "aes-128-gcm"}, Trojan: &panel.TrojanNode{Network: "tcp", NetworkSettings: []byte("{}")}, Hysteria2: &panel.Hysteria2Node{}}
			if proto == "trojan" || proto == "hysteria2" {
				info.Security = panel.Tls
			}
			cfg := &conf.Options{ListenIP: "127.0.0.1", SendIP: "0.0.0.0", XrayOptions: conf.NewXrayOptions(), CertConfig: cert}
			var server vCore.Core
			if proto == "hysteria2" {
				server, err = hy2.New(&conf.CoreConfig{Hysteria2Config: conf.NewHysteria2Config()})
			} else {
				server, err = xray.New(&conf.CoreConfig{XrayConfig: conf.NewXrayConfig()})
			}
			if err != nil {
				t.Fatal(err)
			}
			if err = server.Start(); err != nil {
				t.Fatal(err)
			}
			defer server.Close()
			name := "other-" + proto
			users := []panel.UserInfo{{Id: 1, Uuid: "11111111-1111-4111-8111-111111111111"}, {Id: 2, Uuid: "22222222-2222-4222-8222-222222222222"}}
			limiter.AddLimiter(name, &conf.LimitConfig{}, users, map[int]int{})
			defer limiter.DeleteLimiter(name)
			if err = server.AddNode(name, info, cfg); err != nil {
				t.Fatal(err)
			}
			if _, err = server.AddUsers(&vCore.AddUsersParams{Tag: name, Users: users, NodeInfo: info}); err != nil {
				t.Fatal(err)
			}
			client := clientBox(t, proto, port, users[1].Uuid, false)
			c, e := exchange(client, target.Addr().String())
			if e != nil {
				t.Fatal(e)
			}
			c.Close()
			report, e := server.GetUserTrafficSlice(name, true)
			if e != nil {
				t.Fatal(e)
			}
			if len(report) != 1 || report[0].UID != 2 || report[0].Upload <= 0 || report[0].Download <= 0 {
				t.Fatalf("bad traffic: %+v", report)
			}
			if err = server.DelUsers(users[:1], name, info); err != nil {
				t.Fatal(err)
			}
			rejected := clientBox(t, proto, port, users[0].Uuid, false)
			if c, e := exchange(rejected, target.Addr().String()); e == nil {
				c.Close()
				t.Fatal("deleted user accepted")
			}
			c, e = exchange(client, target.Addr().String())
			if e != nil {
				t.Fatal("remaining user", e)
			}
			c.Close()
		})
	}
}
