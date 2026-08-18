//go:build !ios

package gobackend

import (
	"context"
	"net/http"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/net/http2"
)

type fakePooledHTTP2Conn struct {
	healthy             bool
	streamsActive       int
	blockShutdown       bool
	ignoreShutdownCtx   bool
	closeCount          atomic.Int32
	shutdownCount       atomic.Int32
	shutdownOnce        sync.Once
	shutdownDone        chan struct{}
	forceCloseUnblocked chan struct{}
	forceCloseOnce      sync.Once
}

func newFakePooledHTTP2Conn(healthy bool) *fakePooledHTTP2Conn {
	return &fakePooledHTTP2Conn{
		healthy:             healthy,
		shutdownDone:        make(chan struct{}),
		forceCloseUnblocked: make(chan struct{}),
	}
}

func (c *fakePooledHTTP2Conn) RoundTrip(*http.Request) (*http.Response, error) {
	return nil, nil
}

func (c *fakePooledHTTP2Conn) ReserveNewRequest() bool { return c.healthy }

func (c *fakePooledHTTP2Conn) State() http2.ClientConnState {
	if c.healthy {
		return http2.ClientConnState{
			StreamsActive:        c.streamsActive,
			MaxConcurrentStreams: 100,
		}
	}
	return http2.ClientConnState{Closing: true, StreamsActive: c.streamsActive}
}

func (c *fakePooledHTTP2Conn) Close() error {
	c.closeCount.Add(1)
	c.forceCloseOnce.Do(func() { close(c.forceCloseUnblocked) })
	return nil
}

func (c *fakePooledHTTP2Conn) Shutdown(ctx context.Context) error {
	c.shutdownCount.Add(1)
	c.shutdownOnce.Do(func() { close(c.shutdownDone) })
	if c.ignoreShutdownCtx {
		<-c.forceCloseUnblocked
		return context.DeadlineExceeded
	}
	if c.blockShutdown {
		<-ctx.Done()
		return ctx.Err()
	}
	return nil
}

func waitForShutdown(t *testing.T, conn *fakePooledHTTP2Conn) {
	t.Helper()
	select {
	case <-conn.shutdownDone:
	case <-time.After(time.Second):
		t.Fatal("connection did not begin graceful shutdown")
	}
}

func TestUTLSPoolRetiresStaleCachedConnection(t *testing.T) {
	transport := newUTLSTransport()
	stale := newFakePooledHTTP2Conn(false)
	transport.conns["example:443"] = stale

	if got := transport.cachedConn("example:443"); got != nil {
		t.Fatalf("cachedConn returned stale connection: %#v", got)
	}
	waitForShutdown(t, stale)
	if stale.closeCount.Load() != 0 {
		t.Fatalf("gracefully retired connection was force closed")
	}
	if _, exists := transport.conns["example:443"]; exists {
		t.Fatal("stale connection was not removed")
	}
}

func TestUTLSPoolStoreClosesDiscardedAndRetiresReplacedConnection(t *testing.T) {
	transport := newUTLSTransport()
	healthy := newFakePooledHTTP2Conn(true)
	transport.conns["example:443"] = healthy
	fresh := newFakePooledHTTP2Conn(true)

	if got := transport.storeConn("example:443", fresh); got != healthy {
		t.Fatal("healthy pooled connection was not reused")
	}
	if fresh.closeCount.Load() != 1 {
		t.Fatalf("discarded fresh close count = %d", fresh.closeCount.Load())
	}

	stale := newFakePooledHTTP2Conn(false)
	transport.conns["example:443"] = stale
	replacement := newFakePooledHTTP2Conn(true)
	if got := transport.storeConn("example:443", replacement); got != replacement {
		t.Fatal("stale connection was not replaced")
	}
	waitForShutdown(t, stale)
	if stale.closeCount.Load() != 0 {
		t.Fatalf("replaced connection was force closed")
	}
}

func TestUTLSPoolInvalidateRetiresOnlyRequestedConnection(t *testing.T) {
	transport := newUTLSTransport()
	current := newFakePooledHTTP2Conn(true)
	old := newFakePooledHTTP2Conn(false)
	transport.conns["example:443"] = current

	transport.invalidate("example:443", old)
	if transport.conns["example:443"] != current {
		t.Fatal("invalidating an old connection removed the replacement")
	}
	if old.shutdownCount.Load() != 0 {
		t.Fatal("connection already removed from the pool was retired again")
	}

	transport.invalidate("example:443", current)
	waitForShutdown(t, current)
	if _, exists := transport.conns["example:443"]; exists {
		t.Fatal("invalidated current connection remained in the pool")
	}
}

func TestUTLSPoolCloseIdleUsesBoundedShutdown(t *testing.T) {
	transport := newUTLSTransport()
	conn := newFakePooledHTTP2Conn(true)
	transport.conns["example:443"] = conn

	transport.closeIdleConnections()
	if len(transport.conns) != 0 {
		t.Fatal("pool was not cleared synchronously")
	}
	select {
	case <-conn.shutdownDone:
	case <-time.After(time.Second):
		t.Fatal("pooled connection was not shut down")
	}
	if conn.shutdownCount.Load() != 1 {
		t.Fatalf("shutdown count = %d", conn.shutdownCount.Load())
	}
}

func TestUTLSPoolForcesCloseWhenGracefulShutdownTimesOut(t *testing.T) {
	conn := newFakePooledHTTP2Conn(true)
	conn.ignoreShutdownCtx = true

	retirePooledHTTP2ConnWithTimeout(conn, 20*time.Millisecond)
	waitForShutdown(t, conn)

	deadline := time.After(time.Second)
	for conn.closeCount.Load() == 0 {
		select {
		case <-deadline:
			t.Fatal("timed-out graceful shutdown did not force close")
		case <-time.After(10 * time.Millisecond):
		}
	}
}

func TestUTLSPoolDoesNotPutADeadlineOnActiveStreams(t *testing.T) {
	conn := newFakePooledHTTP2Conn(false)
	conn.streamsActive = 1
	if timeout := pooledHTTP2RetirementTimeout(conn.State()); timeout != 0 {
		t.Fatalf("active connection retirement timeout = %v", timeout)
	}
}
