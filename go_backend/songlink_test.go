package gobackend

import (
	"context"
	"io"
	"net/http"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (fn roundTripFunc) RoundTrip(req *http.Request) (*http.Response, error) {
	return fn(req)
}

type blockingPlatformResolver struct {
	calls   atomic.Int32
	started chan struct{}
	release chan struct{}
	result  resolverResult
}

func (r *blockingPlatformResolver) Resolve(context.Context, string, resolverMetadata) (resolverResult, error) {
	if r.calls.Add(1) == 1 {
		close(r.started)
	}
	<-r.release
	return r.result, nil
}

func TestIdenticalPlatformResolverRequestsAreCoalesced(t *testing.T) {
	resolver := &blockingPlatformResolver{
		started: make(chan struct{}),
		release: make(chan struct{}),
		result: resolverResult{Links: map[string]songLinkPlatformLink{
			"deezer": {URL: "https://www.deezer.com/track/123"},
		}},
	}
	client := &SongLinkClient{fallbackResolver: resolver}

	const workers = 16
	start := make(chan struct{})
	errs := make(chan error, workers)
	var wg sync.WaitGroup
	wg.Add(workers)
	for range workers {
		go func() {
			defer wg.Done()
			<-start
			links, err := client.resolveTrackPlatforms("https://open.spotify.com/track/coalesced")
			if err == nil && links["deezer"].URL == "" {
				err = io.ErrUnexpectedEOF
			}
			errs <- err
		}()
	}
	close(start)

	select {
	case <-resolver.started:
	case <-time.After(time.Second):
		t.Fatal("resolver did not start")
	}
	time.Sleep(20 * time.Millisecond)
	close(resolver.release)
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatalf("coalesced resolution failed: %v", err)
		}
	}
	if got := resolver.calls.Load(); got != 1 {
		t.Fatalf("resolver calls = %d, want 1", got)
	}
}

func TestGetRetryAfterDurationMissingHeaderReturnsZero(t *testing.T) {
	resp := &http.Response{Header: make(http.Header)}
	if got := getRetryAfterDuration(resp); got != 0 {
		t.Fatalf("getRetryAfterDuration() = %v, want 0", got)
	}
}

func resetTrackAvailabilityCache() {
	trackAvailabilityCacheMu.Lock()
	trackAvailabilityCache = map[string]trackAvailabilityCacheEntry{}
	trackAvailabilityCacheMu.Unlock()
}

// testResolverResult is an in-memory fixture; none of these URLs are fetched.
func testResolverResult() resolverResult {
	return resolverResult{Links: map[string]songLinkPlatformLink{
		"spotify":      {URL: "https://open.spotify.com/track/testspotifyid"},
		"deezer":       {URL: "https://www.deezer.com/track/101"},
		"amazonMusic":  {URL: "https://music.amazon.com/tracks/TESTASIN"},
		"tidal":        {URL: "https://listen.tidal.com/track/202"},
		"qobuz":        {URL: "https://open.qobuz.com/track/303"},
		"youtubeMusic": {URL: "https://music.youtube.com/watch?v=testvideoid1"},
	}}
}

func TestCheckTrackAvailabilityFromSpotifyUsesActiveResolverChain(t *testing.T) {
	resetTrackAvailabilityCache()
	client := &SongLinkClient{fallbackResolver: &stubPlatformResolver{result: testResolverResult()}}

	availability, err := client.CheckTrackAvailability("testspotifyid", "")
	if err != nil {
		t.Fatalf("CheckTrackAvailability() error = %v", err)
	}
	if availability.SpotifyID != "testspotifyid" || availability.DeezerID != "101" {
		t.Fatalf("availability IDs = %+v", availability)
	}
	if !availability.Deezer || !availability.Amazon || !availability.Tidal || !availability.Qobuz || !availability.YouTube {
		t.Fatalf("availability flags = %+v", availability)
	}
	if availability.YouTubeID != "testvideoid1" {
		t.Fatalf("YouTubeID = %q", availability.YouTubeID)
	}
}

type inputCapturingResolver struct {
	input  string
	result resolverResult
}

func (r *inputCapturingResolver) Resolve(_ context.Context, input string, _ resolverMetadata) (resolverResult, error) {
	r.input = input
	return r.result, nil
}

func TestResolveTrackPlatformsByPlatformBuildsDirectURL(t *testing.T) {
	resolver := &inputCapturingResolver{result: testResolverResult()}
	client := &SongLinkClient{fallbackResolver: resolver}

	links, err := client.resolveTrackPlatformsByPlatform("spotify", "song", "testspotifyid")
	if err != nil {
		t.Fatalf("resolveTrackPlatformsByPlatform() error = %v", err)
	}
	if resolver.input != "https://open.spotify.com/track/testspotifyid" {
		t.Fatalf("resolver input = %q", resolver.input)
	}
	if links["deezer"].URL == "" {
		t.Fatalf("resolver links = %#v", links)
	}
}

func TestCheckTrackAvailabilityCachesResult(t *testing.T) {
	resetTrackAvailabilityCache()
	resolver := &stubPlatformResolver{result: resolverResult{Links: map[string]songLinkPlatformLink{
		"spotify": {URL: "https://open.spotify.com/track/cachedid"},
		"deezer":  {URL: "https://www.deezer.com/track/111"},
	}}}
	client := &SongLinkClient{fallbackResolver: resolver}

	first, err := client.CheckTrackAvailability("cachedid", "")
	if err != nil {
		t.Fatalf("first CheckTrackAvailability() error = %v", err)
	}
	second, err := client.CheckTrackAvailability("cachedid", "")
	if err != nil {
		t.Fatalf("second CheckTrackAvailability() error = %v", err)
	}
	if resolver.calls != 1 {
		t.Fatalf("resolver calls = %d, want 1", resolver.calls)
	}
	if first == second || second.DeezerID != "111" {
		t.Fatalf("cached result = %+v", second)
	}
}

func TestCheckTrackAvailabilityNegativeCacheTTL(t *testing.T) {
	resetTrackAvailabilityCache()
	entry := trackAvailabilityCacheEntry{err: true, expiresAt: time.Now().Add(-time.Second)}
	key := GetSongLinkRegion() + "|spotify:expiredneg"
	trackAvailabilityCacheMu.Lock()
	trackAvailabilityCache[key] = entry
	trackAvailabilityCacheMu.Unlock()

	if _, hit, _ := trackAvailabilityCacheLookup(key); hit {
		t.Fatal("expired negative entry should not be a cache hit")
	}
}

func TestCheckAvailabilityFromDeezerUsesActiveResolverChain(t *testing.T) {
	client := &SongLinkClient{fallbackResolver: &stubPlatformResolver{result: testResolverResult()}}
	availability, err := client.CheckAvailabilityFromDeezer("908604612")
	if err != nil {
		t.Fatalf("CheckAvailabilityFromDeezer() error = %v", err)
	}
	if !availability.Deezer || availability.DeezerID != "908604612" || availability.SpotifyID != "testspotifyid" {
		t.Fatalf("availability = %+v", availability)
	}
}
