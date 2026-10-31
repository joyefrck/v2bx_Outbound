package dispatcher

import (
	"context"
	"github.com/xtls/xray-core/common/buf"
	"io"
	"sync/atomic"
	"testing"
	"time"
)

type finalBufferReader struct{ timeout time.Duration }

func (r *finalBufferReader) ReadMultiBuffer() (buf.MultiBuffer, error) {
	b := buf.New()
	_, _ = b.Write([]byte("final-bytes"))
	return buf.MultiBuffer{b}, io.EOF
}
func (r *finalBufferReader) ReadMultiBufferTimeout(timeout time.Duration) (buf.MultiBuffer, error) {
	r.timeout = timeout
	return r.ReadMultiBuffer()
}
func TestCounterReaderPreservesBytesWithEOFAndTimeout(t *testing.T) {
	for _, timed := range []bool{false, true} {
		source := &finalBufferReader{}
		count := &atomic.Int64{}
		reader := &CounterReader{Reader: source, Counter: count}
		var mb buf.MultiBuffer
		var err error
		if timed {
			mb, err = reader.ReadMultiBufferTimeout(25 * time.Millisecond)
		} else {
			mb, err = reader.ReadMultiBuffer()
		}
		if err != io.EOF || mb.Len() != 11 || count.Load() != 11 {
			t.Fatalf("final payload was lost: bytes=%d count=%d err=%v", mb.Len(), count.Load(), err)
		}
		buf.ReleaseMulti(mb)
		if timed && source.timeout != 25*time.Millisecond {
			t.Fatal("read deadline ignored")
		}
	}
}

type interruptibleReader struct{ done chan struct{} }

func (r *interruptibleReader) ReadMultiBuffer() (buf.MultiBuffer, error) {
	<-r.done
	return nil, context.Canceled
}
func (r *interruptibleReader) Interrupt() { close(r.done) }
func TestCounterReaderInterruptsUnderlyingRead(t *testing.T) {
	source := &interruptibleReader{done: make(chan struct{})}
	reader := &CounterReader{Reader: &buf.TimeoutWrapperReader{Reader: source}, Counter: &atomic.Int64{}}
	completed := make(chan struct{})
	go func() { _, _ = reader.ReadMultiBuffer(); close(completed) }()
	reader.Interrupt()
	select {
	case <-completed:
	case <-time.After(time.Second):
		t.Fatal("revoked user reader remained blocked")
	}
}
