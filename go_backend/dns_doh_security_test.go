package gobackend

import (
	"context"
	"errors"
	"net"
	"strings"
	"testing"
	"time"
)

func TestDialWithDoHFallbackRejectsPrivateLiteral(t *testing.T) {
	SetAllowPrivateNetwork(false)
	dialer := &net.Dialer{Timeout: 50 * time.Millisecond}
	for _, address := range []string{
		"127.0.0.1:443",
		"10.0.0.1:443",
		"[::1]:443",
		"[fe80::1]:443",
	} {
		if _, err := dialWithDoHFallback(context.Background(), dialer, "tcp", address); err == nil ||
			!strings.Contains(err.Error(), "private/local") {
			t.Fatalf("address %q was not rejected as private/local: %v", address, err)
		}
	}
}

func TestFilterDialableIPsDropsEveryPrivateAnswer(t *testing.T) {
	SetAllowPrivateNetwork(false)
	filtered := filterDialableIPs([]net.IP{
		net.ParseIP("127.0.0.1"),
		net.ParseIP("192.168.1.4"),
		net.ParseIP("169.254.1.2"),
		net.ParseIP("::1"),
		net.ParseIP("203.0.113.10"),
	})
	if len(filtered) != 1 || !filtered[0].Equal(net.ParseIP("203.0.113.10")) {
		t.Fatalf("unexpected filtered addresses: %v", filtered)
	}
}

func TestInterleaveDialIPsAlternatesAddressFamilies(t *testing.T) {
	ordered := interleaveDialIPs([]net.IP{
		net.ParseIP("2001:db8::1"),
		net.ParseIP("2001:db8::2"),
		net.ParseIP("192.0.2.1"),
		net.ParseIP("192.0.2.2"),
	}, "tcp")
	want := []string{"2001:db8::1", "192.0.2.1", "2001:db8::2", "192.0.2.2"}
	if len(ordered) != len(want) {
		t.Fatalf("ordered addresses = %v, want %v", ordered, want)
	}
	for i, ip := range ordered {
		if ip.String() != want[i] {
			t.Fatalf("ordered[%d] = %s, want %s", i, ip, want[i])
		}
	}
}

func TestRaceResolvedIPsFallsBackWithoutWaitingForPreferredFamilyTimeout(t *testing.T) {
	preferredStarted := make(chan struct{})
	clientPeerClosed := make(chan struct{})
	dial := func(ctx context.Context, _ string, address string) (net.Conn, error) {
		host, _, err := net.SplitHostPort(address)
		if err != nil {
			return nil, err
		}
		if net.ParseIP(host).To4() == nil {
			close(preferredStarted)
			<-ctx.Done()
			return nil, ctx.Err()
		}
		client, peer := net.Pipe()
		go func() {
			<-ctx.Done()
			peer.Close()
			close(clientPeerClosed)
		}()
		return client, nil
	}

	startedAt := time.Now()
	conn, err := raceResolvedIPs(
		context.Background(),
		"tcp",
		"dual-stack.example",
		"443",
		[]net.IP{net.ParseIP("2001:db8::1"), net.ParseIP("192.0.2.1")},
		nil,
		10*time.Millisecond,
		dial,
	)
	if err != nil {
		t.Fatalf("raceResolvedIPs returned error: %v", err)
	}
	defer conn.Close()
	if elapsed := time.Since(startedAt); elapsed > 100*time.Millisecond {
		t.Fatalf("fallback took %v, want <100ms", elapsed)
	}
	select {
	case <-preferredStarted:
	default:
		t.Fatal("preferred address family was not attempted first")
	}
	select {
	case <-clientPeerClosed:
	case <-time.After(time.Second):
		t.Fatal("losing dial was not cancelled")
	}
}

func TestRaceResolvedIPsReturnsLastErrorAfterFastFailures(t *testing.T) {
	wantErr := errors.New("refused")
	conn, err := raceResolvedIPs(
		context.Background(),
		"tcp",
		"failed.example",
		"443",
		[]net.IP{net.ParseIP("192.0.2.1"), net.ParseIP("192.0.2.2")},
		nil,
		time.Second,
		func(context.Context, string, string) (net.Conn, error) {
			return nil, wantErr
		},
	)
	if conn != nil || !errors.Is(err, wantErr) {
		t.Fatalf("result = (%v, %v), want (nil, %v)", conn, err, wantErr)
	}
}
