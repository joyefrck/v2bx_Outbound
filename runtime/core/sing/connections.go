package sing

import (
	N "github.com/sagernet/sing/common/network"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

func userKey(tag, user string) string { return tag + "\x00" + user }

func (h *HookServer) allowed(tag, user string) bool {
	if _, managed := h.managedNodes.Load(tag); !managed {
		return true
	}
	_, ok := h.activeUsers.Load(userKey(tag, user))
	return ok
}

func (h *HookServer) revoke(tag, user string) {
	key := userKey(tag, user)
	h.activeUsers.Delete(key)
	h.connections.Range(func(conn, identity any) bool {
		if identity == key {
			_ = conn.(interface{ Close() error }).Close()
		}
		return true
	})
}

type trackedConnection struct {
	net.Conn
	owner     *HookServer
	readMu    sync.Mutex
	writeMu   sync.Mutex
	closeOnce sync.Once
	closed    atomic.Bool
	closeErr  error
}

// Some protocol wrappers release buffers in Close. Unblock I/O before joining
// readers and writers, then close exactly once without racing their buffers.
func (c *trackedConnection) Read(p []byte) (int, error) {
	c.readMu.Lock()
	defer c.readMu.Unlock()
	if c.closed.Load() {
		return 0, net.ErrClosed
	}
	return c.Conn.Read(p)
}
func (c *trackedConnection) Write(p []byte) (int, error) {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	if c.closed.Load() {
		return 0, net.ErrClosed
	}
	return c.Conn.Write(p)
}
func (c *trackedConnection) Close() error {
	c.closeOnce.Do(func() {
		c.closed.Store(true)
		c.owner.connections.Delete(c)
		_ = c.Conn.SetDeadline(time.Now())
		c.readMu.Lock()
		defer c.readMu.Unlock()
		c.writeMu.Lock()
		defer c.writeMu.Unlock()
		c.closeErr = c.Conn.Close()
	})
	return c.closeErr
}

type trackedPacketConnection struct {
	N.PacketConn
	owner *HookServer
}

func (c *trackedPacketConnection) Close() error {
	c.owner.connections.Delete(c)
	return c.PacketConn.Close()
}

// Preserve protocol buffer requirements while keeping tracking wrappers opaque
// to copying optimizations (otherwise UDP transports receive no header space).
func (c *trackedPacketConnection) FrontHeadroom() int { return N.CalculateFrontHeadroom(c.PacketConn) }
func (c *trackedPacketConnection) RearHeadroom() int  { return N.CalculateRearHeadroom(c.PacketConn) }
func (c *trackedPacketConnection) ReaderOverhead() int {
	return N.CalculateReaderOverhead(c.PacketConn)
}
