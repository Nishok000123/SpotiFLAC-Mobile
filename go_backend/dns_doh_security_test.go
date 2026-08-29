package gobackend

import (
	"context"
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
