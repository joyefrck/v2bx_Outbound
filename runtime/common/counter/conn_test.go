package counter

import (
	"io"
	"net"
	"testing"
)

func TestConnCountsMultipleReadsAndEOF(t *testing.T) {
	a, b := net.Pipe()
	defer a.Close()
	s := &TrafficStorage{}
	c := NewConnCounter(a, s)
	go func() { b.Write([]byte("abc")); b.Write([]byte("defg")); b.Close() }()
	if _, err := io.Copy(io.Discard, c); err != nil {
		t.Fatal(err)
	}
	if got := s.UpCounter.Load(); got != 7 {
		t.Fatalf("count after EOF=%d", got)
	}
}
