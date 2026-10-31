package xray

import (
	"github.com/InazumaV/V2bX/api/panel"
	"github.com/InazumaV/V2bX/common/counter"
	"github.com/InazumaV/V2bX/common/format"
	"github.com/InazumaV/V2bX/conf"
	vCore "github.com/InazumaV/V2bX/core"
	"github.com/InazumaV/V2bX/limiter"
	"net"
	"testing"
)

func TestRevokedUserRetainsUnreportedTraffic(t *testing.T) {
	limiter.Init()
	core, err := New(&conf.CoreConfig{XrayConfig: conf.NewXrayConfig()})
	if err != nil {
		t.Fatal(err)
	}
	server := core.(*Xray)
	if err := server.Start(); err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	reserve, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := reserve.Addr().(*net.TCPAddr).Port
	reserve.Close()
	node := &panel.NodeInfo{Type: "vless", Common: &panel.CommonNode{ServerPort: port}, VAllss: &panel.VAllssNode{Network: "tcp"}}
	options := &conf.Options{ListenIP: "127.0.0.1", ReportMinTraffic: 1000, XrayOptions: conf.NewXrayOptions()}
	users := []panel.UserInfo{{Id: 7, Uuid: "11111111-1111-4111-8111-111111111111"}}
	tag := "retirement-test"
	limiter.AddLimiter(tag, &conf.LimitConfig{}, users, nil)
	defer limiter.DeleteLimiter(tag)
	if err := server.AddNode(tag, node, options); err != nil {
		t.Fatal(err)
	}
	if _, err := server.AddUsers(&vCore.AddUsersParams{Tag: tag, Users: users, NodeInfo: node}); err != nil {
		t.Fatal(err)
	}
	email := format.UserTag(tag, users[0].Uuid)
	counts := counter.NewTrafficCounter()
	counts.Tx(email, 10)
	counts.Rx(email, 20)
	server.dispatcher.Counter.Store(tag, counts)
	if err := server.DelUsers(users, tag, node); err != nil {
		t.Fatal(err)
	}
	if _, allowed := server.dispatcher.AllowedUsers.Load(email); allowed {
		t.Fatal("revoked user remains allowed")
	}
	report, err := server.GetUserTrafficSlice(tag, true)
	if err != nil || len(report) != 1 || report[0].UID != 7 || report[0].Upload != 10 || report[0].Download != 20 {
		t.Fatalf("unreported traffic lost: %+v %v", report, err)
	}
	if err := server.DelUsers(users, tag, node); err != nil {
		t.Fatal("user removal retry was not idempotent", err)
	}
	report, err = server.GetUserTrafficSlice(tag, true)
	if err != nil || len(report) != 0 {
		t.Fatal("retired traffic reported more than once")
	}
}
