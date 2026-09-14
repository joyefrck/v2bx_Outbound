package sing

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"io"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/InazumaV/V2bX/api/panel"
	"github.com/InazumaV/V2bX/conf"
	vCore "github.com/InazumaV/V2bX/core"
	"github.com/InazumaV/V2bX/limiter"
	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
	SJSON "github.com/sagernet/sing/common/json"
	M "github.com/sagernet/sing/common/metadata"
	"github.com/sagernet/sing/service"
)

func testCertificate(t *testing.T) *conf.CertConfig {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "localhost"}, DNSNames: []string{"localhost"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	private, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	cert := filepath.Join(dir, "cert.pem")
	priv := filepath.Join(dir, "key.pem")
	if err = os.WriteFile(cert, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0600); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(priv, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: private}), 0600); err != nil {
		t.Fatal(err)
	}
	return &conf.CertConfig{CertMode: "file", CertFile: cert, KeyFile: priv}
}

func clientBox(t *testing.T, proto string, port int, uuid string, ss2022 bool) *box.Box {
	t.Helper()
	out := map[string]any{"type": proto, "tag": "test", "server": "127.0.0.1", "server_port": port}
	switch proto {
	case "vless":
		out["uuid"] = uuid
	case "vmess":
		out["uuid"] = uuid
		out["security"] = "auto"
	case "shadowsocks":
		out["method"] = "aes-128-gcm"
		out["password"] = uuid
		if ss2022 {
			out["method"] = "2022-blake3-aes-128-gcm"
			out["password"] = base64.StdEncoding.EncodeToString([]byte("0123456789abcdef")) + ":" + base64.StdEncoding.EncodeToString([]byte(uuid[:16]))
		}
	case "tuic":
		out["uuid"] = uuid
		out["password"] = uuid
		out["congestion_control"] = "cubic"
	case "hysteria":
		out["auth_str"] = uuid
		out["up_mbps"] = 100
		out["down_mbps"] = 100
	default:
		out["password"] = uuid
	}
	if proto == "trojan" || proto == "tuic" || proto == "hysteria" || proto == "hysteria2" || proto == "anytls" {
		out["tls"] = map[string]any{"enabled": true, "server_name": "localhost", "insecure": true}
	}
	if proto == "tuic" {
		out["tls"].(map[string]any)["alpn"] = []string{"h3"}
	}
	ctx := service.ContextWithDefaultRegistry(context.Background())
	ctx = box.Context(ctx, include.InboundRegistry(), include.OutboundRegistry(), include.EndpointRegistry(), include.DNSTransportRegistry(), include.ServiceRegistry(), include.CertificateProviderRegistry())
	data, _ := json.Marshal(map[string]any{"log": map[string]any{"disabled": true}, "outbounds": []any{out}})
	opts, err := SJSON.UnmarshalExtendedContext[option.Options](ctx, data)
	if err != nil {
		t.Fatal(err)
	}
	client, err := box.New(box.Options{Context: ctx, Options: opts})
	if err != nil {
		t.Fatal(err)
	}
	if err = client.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { client.Close() })
	return client
}

func exchange(client *box.Box, target string) (net.Conn, error) {
	out, _ := client.Outbound().Outbound("test")
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	conn, err := out.DialContext(ctx, "tcp", M.ParseSocksaddr(target))
	if err != nil {
		return nil, err
	}
	conn.SetDeadline(time.Now().Add(3 * time.Second))
	payload := []byte("verified-user-traffic")
	if _, err = conn.Write(payload); err == nil {
		answer := make([]byte, len(payload))
		_, err = io.ReadFull(conn, answer)
		if err == nil && string(answer) != string(payload) {
			err = io.ErrUnexpectedEOF
		}
	}
	if err != nil {
		conn.Close()
		return nil, err
	}
	return conn, nil
}

func TestManagedProtocols(t *testing.T) {
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
	udp, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer udp.Close()
	go func() {
		buffer := make([]byte, 65535)
		for {
			n, addr, e := udp.ReadFrom(buffer)
			if e != nil {
				return
			}
			udp.WriteTo(buffer[:n], addr)
		}
	}()
	for _, name := range []string{"vless", "vmess", "shadowsocks", "ss2022", "trojan", "tuic", "hysteria", "hysteria2", "anytls"} {
		t.Run(name, func(t *testing.T) {
			proto := name
			if proto == "ss2022" {
				proto = "shadowsocks"
			}
			reserved, e := net.Listen("tcp", "127.0.0.1:0")
			if e != nil {
				t.Fatal(e)
			}
			port := reserved.Addr().(*net.TCPAddr).Port
			reserved.Close()
			info := &panel.NodeInfo{Type: proto, Common: &panel.CommonNode{ServerPort: port}, VAllss: &panel.VAllssNode{Network: "tcp"}, Shadowsocks: &panel.ShadowsocksNode{Cipher: "aes-128-gcm"}, Trojan: &panel.TrojanNode{Network: "tcp"}, Tuic: &panel.TuicNode{CongestionControl: "cubic"}, Hysteria: &panel.HysteriaNode{UpMbps: 100, DownMbps: 100}, Hysteria2: &panel.Hysteria2Node{}, AnyTls: &panel.AnyTlsNode{}}
			if name == "ss2022" {
				info.Shadowsocks.Cipher = "2022-blake3-aes-128-gcm"
				info.Shadowsocks.ServerKey = base64.StdEncoding.EncodeToString([]byte("0123456789abcdef"))
			}
			if proto == "trojan" || proto == "tuic" || proto == "hysteria" || proto == "hysteria2" || proto == "anytls" {
				info.Security = panel.Tls
			}
			config := &conf.Options{ListenIP: "127.0.0.1", SingOptions: conf.NewSingOptions(), CertConfig: cert}
			core, err := New(&conf.CoreConfig{SingConfig: conf.NewSingConfig()})
			if err != nil {
				t.Fatal(err)
			}
			server := core.(*Sing)
			if err = server.Start(); err != nil {
				t.Fatal(err)
			}
			defer server.Close()
			if err = server.AddNode(name, info, config); err != nil {
				t.Fatal(err)
			}
			users := []panel.UserInfo{{Id: 1, Uuid: "11111111-1111-4111-8111-111111111111"}, {Id: 2, Uuid: "22222222-2222-4222-8222-222222222222"}}
			limiter.AddLimiter(name, &conf.LimitConfig{}, users, map[int]int{})
			defer limiter.DeleteLimiter(name)
			if _, err = server.AddUsers(&vCore.AddUsersParams{Tag: name, Users: users, NodeInfo: info}); err != nil {
				t.Fatal(err)
			}
			c1 := clientBox(t, proto, port, users[0].Uuid, name == "ss2022")
			c2 := clientBox(t, proto, port, users[1].Uuid, name == "ss2022")
			live, err := exchange(c1, target.Addr().String())
			if err != nil {
				t.Fatal("first user:", err)
			}
			defer live.Close()
			if err = server.DelUsers(users[:1], name, info); err != nil {
				t.Fatal(err)
			}
			live.SetDeadline(time.Now().Add(2 * time.Second))
			live.Write([]byte("revoked"))
			var revoked [7]byte
			if _, e := io.ReadFull(live, revoked[:]); e == nil {
				t.Fatal("deleted user's existing connection stayed usable")
			}
			// Deleting one user must neither renumber the remaining user nor charge its traffic to the deleted ID.
			conn, err := exchange(c2, target.Addr().String())
			if err != nil {
				t.Fatal("remaining user:", err)
			}
			conn.Close()
			rejected := clientBox(t, proto, port, users[0].Uuid, name == "ss2022")
			if c, e := exchange(rejected, target.Addr().String()); e == nil {
				c.Close()
				t.Fatal("deleted user connected")
			}
			report, err := server.GetUserTrafficSlice(name, true)
			if err != nil {
				t.Fatal(err)
			}
			if len(report) != 1 || report[0].UID != 2 || report[0].Upload == 0 || report[0].Download == 0 {
				t.Fatalf("wrong traffic attribution: %+v", report)
			}
			// Updating authentication concurrently with successful connections must be race-free.
			var wg sync.WaitGroup
			for i := 0; i < 4; i++ {
				wg.Add(1)
				go func() {
					defer wg.Done()
					for j := 0; j < 3; j++ {
						if c, e := exchange(c2, target.Addr().String()); e != nil {
							t.Error(e)
						} else {
							c.Close()
						}
					}
				}()
			}
			for i := 0; i < 5; i++ {
				if _, err = server.AddUsers(&vCore.AddUsersParams{Tag: name, Users: users[1:], NodeInfo: info}); err != nil {
					t.Fatal(err)
				}
			}
			wg.Wait()
			if proto != "anytls" {
				out, _ := c2.Outbound().Outbound("test")
				ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
				defer cancel()
				packet, e := out.ListenPacket(ctx, M.ParseSocksaddr(udp.LocalAddr().String()))
				if e != nil {
					t.Fatal("UDP dial:", e)
				}
				defer packet.Close()
				packet.SetDeadline(time.Now().Add(3 * time.Second))
				payload := []byte("verified-udp")
				if _, e = packet.WriteTo(payload, udp.LocalAddr()); e != nil {
					t.Fatal("UDP send:", e)
				}
				buffer := make([]byte, 100)
				n, _, e := packet.ReadFrom(buffer)
				if e != nil || string(buffer[:n]) != string(payload) {
					t.Fatalf("UDP response: %q %v", buffer[:n], e)
				}
				if err = server.DelUsers(users[1:], name, info); err != nil {
					t.Fatal(err)
				}
				// TUIC virtual UDP sockets do not implement deadlines; close bounds this negative assertion.
				timeout := time.AfterFunc(150*time.Millisecond, func() { packet.Close() })
				defer timeout.Stop()
				if _, e = packet.WriteTo(payload, udp.LocalAddr()); e == nil {
					if _, _, e = packet.ReadFrom(buffer); e == nil {
						t.Fatal("deleted user retained UDP access")
					}
				}
			}
		})
	}
}
