package dispatcher

import (
	"github.com/xtls/xray-core/common/buf"
	"sync"
	"sync/atomic"
	"testing"
)

type closingWriter struct{ closed atomic.Bool }

func (w *closingWriter) WriteMultiBuffer(mb buf.MultiBuffer) error { buf.ReleaseMulti(mb); return nil }
func (w *closingWriter) Close() error                              { w.closed.Store(true); return nil }
func TestClosedLinkManagerRejectsLateConnections(t *testing.T) {
	manager := &LinkManager{links: make(map[*ManagedWriter]buf.Reader)}
	manager.CloseAll()
	writer := &closingWriter{}
	connection := &closingWriter{}
	manager.AddLink(&ManagedWriter{writer: writer, manager: manager, connection: connection}, nil)
	if !writer.closed.Load() || !connection.closed.Load() || len(manager.links) != 0 {
		t.Fatal("revoked manager admitted a late connection")
	}
}
func TestConcurrentConnectionsShareTrafficState(t *testing.T) {
	dispatcher := &DefaultDispatcher{}
	first := dispatcher.trafficCounter("node")
	manager := dispatcher.linkManager("user")
	var group sync.WaitGroup
	for range 50 {
		group.Go(func() {
			if dispatcher.trafficCounter("node") != first || dispatcher.linkManager("user") != manager {
				t.Error("concurrent first connections replaced accounting state")
			}
			dispatcher.trafficCounter("node").Tx("user", 1)
		})
	}
	group.Wait()
	if first.GetUpCount("user") != 50 {
		t.Fatal("traffic counter lost concurrent updates")
	}
}
