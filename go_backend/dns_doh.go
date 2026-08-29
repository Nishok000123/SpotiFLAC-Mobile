package gobackend

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"sync"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

// DNS-over-HTTPS fallback for DNS-level ISP blocking. The OS resolver stays
// the primary path; only when it fails with a DNS error (NXDOMAIN, SERVFAIL,
// refused, resolver timeout) is the host re-resolved over DoH to hardcoded
// resolver IPs and dialed directly. TLS verification still runs against the
// original hostname, so a bad answer cannot silently redirect traffic.

var dohUpstreams = []string{
	"https://1.1.1.1/dns-query",
	"https://8.8.8.8/dns-query",
}

// Upstream URLs are literal IPs, so this client never needs DNS itself.
var dohClient = &http.Client{
	Transport: &http.Transport{
		DialContext:         (&net.Dialer{Timeout: 5 * time.Second}).DialContext,
		MaxIdleConnsPerHost: 1,
		IdleConnTimeout:     60 * time.Second,
		TLSHandshakeTimeout: 5 * time.Second,
		ForceAttemptHTTP2:   true,
		TLSClientConfig:     newTLSCompatibilityConfig(false),
	},
	Timeout: 10 * time.Second,
}

const (
	dohCacheMaxEntries = 256
	dohCacheMinTTL     = time.Minute
	dohCacheMaxTTL     = 30 * time.Minute
	dohCacheErrorTTL   = 30 * time.Second
	// Match Go's net.Dialer fallback cadence: give the preferred address family
	// a brief head start, then race the remaining vetted answers. We cannot hand
	// the hostname back to net.Dialer because the socket must stay pinned to an
	// address that already passed the private-network filter.
	happyEyeballsFallbackDelay = 300 * time.Millisecond
)

type dohCacheEntry struct {
	ips       []net.IP
	expiresAt time.Time
}

type resolvedDialResult struct {
	conn net.Conn
	err  error
}

type dialContextFunc func(context.Context, string, string) (net.Conn, error)

var (
	dohMu    sync.Mutex
	dohCache = map[string]dohCacheEntry{}
)

// dialWithDoHFallback resolves once, filters every answer, and then dials the
// vetted IP directly. This closes the validation-to-dial DNS rebinding window:
// TLS still receives the original hostname from net/http for SNI and hostname
// verification, while the socket cannot be redirected to a private address.
func dialWithDoHFallback(ctx context.Context, dialer *net.Dialer, network, addr string) (net.Conn, error) {
	host, port, splitErr := net.SplitHostPort(addr)
	if splitErr != nil {
		return nil, splitErr
	}
	if literal := net.ParseIP(host); literal != nil {
		if !IsPrivateNetworkAllowed() && isPrivateIPAddr(literal) {
			return nil, fmt.Errorf("network access denied: private/local address %s", host)
		}
		return dialer.DialContext(ctx, network, addr)
	}

	ips, lookupErr := net.DefaultResolver.LookupIP(ctx, "ip", host)
	if lookupErr == nil {
		ips = filterDialableIPs(ips)
		if len(ips) == 0 {
			return nil, fmt.Errorf("network access denied: %s resolved only to private/local addresses", host)
		}
		return dialResolvedIPs(ctx, dialer, network, host, port, ips, nil)
	}

	var dnsErr *net.DNSError
	if !errors.As(lookupErr, &dnsErr) {
		return nil, lookupErr
	}
	ips, dohErr := dohResolve(ctx, host)
	if dohErr != nil {
		// Surface the OS resolver's error, not the fallback's.
		return nil, lookupErr
	}
	GoLog("[DoH] OS resolver failed for %s (%v), dialing DoH answer\n", host, lookupErr)
	return dialResolvedIPs(ctx, dialer, network, host, port, ips, lookupErr)
}

func dialResolvedIPs(
	ctx context.Context,
	dialer *net.Dialer,
	network string,
	host string,
	port string,
	ips []net.IP,
	initialErr error,
) (net.Conn, error) {
	ordered := interleaveDialIPs(ips, network)
	return raceResolvedIPs(
		ctx,
		network,
		host,
		port,
		ordered,
		initialErr,
		happyEyeballsFallbackDelay,
		dialer.DialContext,
	)
}

func raceResolvedIPs(
	ctx context.Context,
	network string,
	host string,
	port string,
	ordered []net.IP,
	initialErr error,
	fallbackDelay time.Duration,
	dial dialContextFunc,
) (net.Conn, error) {
	if len(ordered) == 0 {
		if initialErr != nil {
			return nil, initialErr
		}
		return nil, fmt.Errorf("no dialable address for %s", host)
	}

	raceCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	results := make(chan resolvedDialResult, len(ordered))
	started := 0
	finished := 0
	lastErr := initialErr

	startNext := func() bool {
		if started >= len(ordered) {
			return false
		}
		ip := ordered[started]
		started++
		go func() {
			conn, err := dial(
				raceCtx,
				network,
				net.JoinHostPort(ip.String(), port),
			)
			// The channel is sized for every possible attempt, so each goroutine
			// can always report exactly once. The winner path drains and closes any
			// late successful connections after cancelling the race.
			results <- resolvedDialResult{conn: conn, err: err}
		}()
		return true
	}

	startNext()
	timer := time.NewTimer(fallbackDelay)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			cancel()
			drainDialResults(results, started-finished)
			return nil, ctx.Err()
		case result := <-results:
			finished++
			if result.err == nil && result.conn != nil {
				cancel()
				drainDialResults(results, started-finished)
				return result.conn, nil
			}
			if result.err != nil {
				lastErr = result.err
			}
			if finished == len(ordered) {
				if lastErr == nil {
					lastErr = fmt.Errorf("no dialable address for %s", host)
				}
				return nil, lastErr
			}
			// A fast refusal should not wait for the fallback timer when there is
			// no other connection attempt currently in flight.
			if finished == started && startNext() {
				resetTimer(timer, fallbackDelay)
			}
		case <-timer.C:
			if startNext() && started < len(ordered) {
				timer.Reset(fallbackDelay)
			}
		}
	}
}

func drainDialResults(results <-chan resolvedDialResult, count int) {
	if count <= 0 {
		return
	}
	go func() {
		for i := 0; i < count; i++ {
			result := <-results
			if result.conn != nil {
				result.conn.Close()
			}
		}
	}()
}

func resetTimer(timer *time.Timer, delay time.Duration) {
	if !timer.Stop() {
		select {
		case <-timer.C:
		default:
		}
	}
	timer.Reset(delay)
}

// interleaveDialIPs preserves the resolver's preferred family while ensuring
// the first fallback uses the other family. This avoids waiting through every
// unreachable IPv6 address before trying IPv4 (and vice versa).
func interleaveDialIPs(ips []net.IP, network string) []net.IP {
	ordered := make([]net.IP, 0, len(ips))
	var v4, v6 []net.IP
	for _, ip := range ips {
		if ip == nil {
			continue
		}
		if ip.To4() != nil {
			if network != "tcp6" && network != "udp6" {
				v4 = append(v4, ip)
			}
		} else if network != "tcp4" && network != "udp4" {
			v6 = append(v6, ip)
		}
	}
	if len(v4) == 0 {
		return append(ordered, v6...)
	}
	if len(v6) == 0 {
		return append(ordered, v4...)
	}

	firstV4 := false
	for _, ip := range ips {
		if ip == nil {
			continue
		}
		firstV4 = ip.To4() != nil
		break
	}
	for len(v4) > 0 || len(v6) > 0 {
		if firstV4 {
			if len(v4) > 0 {
				ordered = append(ordered, v4[0])
				v4 = v4[1:]
			}
			if len(v6) > 0 {
				ordered = append(ordered, v6[0])
				v6 = v6[1:]
			}
		} else {
			if len(v6) > 0 {
				ordered = append(ordered, v6[0])
				v6 = v6[1:]
			}
			if len(v4) > 0 {
				ordered = append(ordered, v4[0])
				v4 = v4[1:]
			}
		}
	}
	return ordered
}

// dohResolve resolves host over DoH, IPv4 first. Failures are negative-cached
// briefly so a burst of dials does not hammer the resolvers.
func dohResolve(ctx context.Context, host string) ([]net.IP, error) {
	if ips, ok := dohCachedIPs(host); ok {
		if len(ips) == 0 {
			return nil, fmt.Errorf("doh: cached failure for %s", host)
		}
		return ips, nil
	}

	var lastErr error
	for _, upstream := range dohUpstreams {
		ips, ttl, err := dohQuery(ctx, upstream, host, dnsmessage.TypeA)
		if err == nil && len(ips) == 0 {
			ips, ttl, err = dohQuery(ctx, upstream, host, dnsmessage.TypeAAAA)
		}
		if err != nil {
			lastErr = err
			continue
		}
		ips = filterDialableIPs(ips)
		if len(ips) == 0 {
			break
		}
		dohCachePut(host, ips, min(max(ttl, dohCacheMinTTL), dohCacheMaxTTL))
		return ips, nil
	}
	dohCachePut(host, nil, dohCacheErrorTTL)
	if lastErr == nil {
		lastErr = fmt.Errorf("doh: no address for %s", host)
	}
	return nil, lastErr
}

func dohQuery(ctx context.Context, upstream, host string, qtype dnsmessage.Type) ([]net.IP, time.Duration, error) {
	name, err := dnsmessage.NewName(host + ".")
	if err != nil {
		return nil, 0, fmt.Errorf("doh: invalid host %q: %w", host, err)
	}
	msg := dnsmessage.Message{
		Header: dnsmessage.Header{RecursionDesired: true},
		Questions: []dnsmessage.Question{{
			Name:  name,
			Type:  qtype,
			Class: dnsmessage.ClassINET,
		}},
	}
	packed, err := msg.Pack()
	if err != nil {
		return nil, 0, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, upstream, bytes.NewReader(packed))
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Content-Type", "application/dns-message")
	req.Header.Set("Accept", "application/dns-message")

	resp, err := dohClient.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, 0, fmt.Errorf("doh: %s answered HTTP %d", upstream, resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	if err != nil {
		return nil, 0, err
	}

	var reply dnsmessage.Message
	if err := reply.Unpack(body); err != nil {
		return nil, 0, err
	}
	if reply.RCode != dnsmessage.RCodeSuccess {
		return nil, 0, fmt.Errorf("doh: rcode %v for %s", reply.RCode, host)
	}

	var ips []net.IP
	ttl := dohCacheMaxTTL
	for _, ans := range reply.Answers {
		var ip net.IP
		switch r := ans.Body.(type) {
		case *dnsmessage.AResource:
			ip = net.IP(r.A[:])
		case *dnsmessage.AAAAResource:
			ip = net.IP(r.AAAA[:])
		default:
			continue
		}
		ips = append(ips, ip)
		if t := time.Duration(ans.Header.TTL) * time.Second; t < ttl {
			ttl = t
		}
	}
	return ips, ttl, nil
}

// filterDialableIPs drops private/loopback/link-local answers unless the user
// opted into private-network access — a DoH answer must not bypass the SSRF
// guard the OS-resolver path enforces.
func filterDialableIPs(ips []net.IP) []net.IP {
	if IsPrivateNetworkAllowed() {
		return ips
	}
	kept := ips[:0]
	for _, ip := range ips {
		if isPrivateIPAddr(ip) {
			continue
		}
		kept = append(kept, ip)
	}
	return kept
}

func dohCachedIPs(host string) ([]net.IP, bool) {
	dohMu.Lock()
	defer dohMu.Unlock()
	e, ok := dohCache[host]
	if !ok || time.Now().After(e.expiresAt) {
		return nil, false
	}
	return e.ips, true
}

func dohCachePut(host string, ips []net.IP, ttl time.Duration) {
	dohMu.Lock()
	defer dohMu.Unlock()
	if len(dohCache) >= dohCacheMaxEntries {
		now := time.Now()
		for k, e := range dohCache {
			if now.After(e.expiresAt) {
				delete(dohCache, k)
			}
		}
		for k := range dohCache {
			if len(dohCache) < dohCacheMaxEntries {
				break
			}
			delete(dohCache, k)
		}
	}
	dohCache[host] = dohCacheEntry{ips: ips, expiresAt: time.Now().Add(ttl)}
}
