package gobackend

import (
	"io"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestSongLinkIdenticalRequestsAreCoalesced(t *testing.T) {
	origRateLimiter := songLinkRateLimiter
	// A single slot proves duplicate waiters join singleflight before reserving
	// rate-limit capacity. Reserving first would block 15 workers for an hour.
	songLinkRateLimiter = NewRateLimiter(1, time.Hour)
	defer func() { songLinkRateLimiter = origRateLimiter }()

	var calls int32
	release := make(chan struct{})
	client := &SongLinkClient{client: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		atomic.AddInt32(&calls, 1)
		<-release
		body := `{"linksByPlatform":{"deezer":{"url":"https://www.deezer.com/track/123"}}}`
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     make(http.Header),
			Body:       io.NopCloser(strings.NewReader(body)),
			Request:    req,
		}, nil
	})}}

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

	deadline := time.Now().Add(time.Second)
	for atomic.LoadInt32(&calls) == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	time.Sleep(20 * time.Millisecond)
	close(release)
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatalf("coalesced request failed: %v", err)
		}
	}
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("network calls = %d, want 1", got)
	}
}

func TestSongLinkIdenticalFallbacksShareOneIDHSRequest(t *testing.T) {
	origSongLinkLimiter := songLinkRateLimiter
	origIDHSLimiter := idhsRateLimiter
	origIDHSClient := NewIDHSClient()
	songLinkRateLimiter = NewRateLimiter(1, time.Hour)
	idhsRateLimiter = NewRateLimiter(1, time.Hour)
	defer func() {
		songLinkRateLimiter = origSongLinkLimiter
		idhsRateLimiter = origIDHSLimiter
		globalIDHSClient = origIDHSClient
	}()

	var songLinkCalls atomic.Int32
	var idhsCalls atomic.Int32
	idhsStarted := make(chan struct{})
	releaseIDHS := make(chan struct{})
	globalIDHSClient = &IDHSClient{client: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		if idhsCalls.Add(1) == 1 {
			close(idhsStarted)
		}
		<-releaseIDHS
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     make(http.Header),
			Body: io.NopCloser(strings.NewReader(
				`{"type":"song","links":[{"type":"deezer","url":"https://www.deezer.com/track/123"}]}`,
			)),
			Request: req,
		}, nil
	})}}
	client := &SongLinkClient{client: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		songLinkCalls.Add(1)
		return &http.Response{
			StatusCode: http.StatusUnauthorized,
			Header:     make(http.Header),
			Body:       io.NopCloser(strings.NewReader(`{}`)),
			Request:    req,
		}, nil
	})}}

	const workers = 16
	start := make(chan struct{})
	errs := make(chan error, workers)
	for range workers {
		go func() {
			<-start
			links, err := client.resolveTrackPlatformsWithIDHS("https://open.spotify.com/track/fallback-coalesced")
			if err == nil && links["deezer"].URL == "" {
				err = io.ErrUnexpectedEOF
			}
			errs <- err
		}()
	}
	close(start)
	select {
	case <-idhsStarted:
	case <-time.After(time.Second):
		t.Fatal("IDHS fallback did not start")
	}
	time.Sleep(20 * time.Millisecond)
	close(releaseIDHS)
	for range workers {
		if err := <-errs; err != nil {
			t.Fatalf("coalesced fallback failed: %v", err)
		}
	}
	if got := songLinkCalls.Load(); got != 1 {
		t.Fatalf("SongLink calls = %d, want 1", got)
	}
	if got := idhsCalls.Load(); got != 1 {
		t.Fatalf("IDHS calls = %d, want 1", got)
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (fn roundTripFunc) RoundTrip(req *http.Request) (*http.Response, error) {
	return fn(req)
}

func TestGetRetryAfterDurationMissingHeaderReturnsZero(t *testing.T) {
	resp := &http.Response{
		Header: make(http.Header),
	}

	if got := getRetryAfterDuration(resp); got != 0 {
		t.Fatalf("getRetryAfterDuration() = %v, want 0", got)
	}
}

func resetTrackAvailabilityCache() {
	trackAvailabilityCacheMu.Lock()
	trackAvailabilityCache = map[string]trackAvailabilityCacheEntry{}
	trackAvailabilityCacheMu.Unlock()
}

func TestCheckTrackAvailabilityFromSpotifyUsesSongLinkDirectly(t *testing.T) {
	resetTrackAvailabilityCache()
	origRetryConfig := songLinkRetryConfig
	defer func() { songLinkRetryConfig = origRetryConfig }()

	client := &SongLinkClient{
		client: &http.Client{
			Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
				if req.URL.Host == "api.song.link" && req.Method == http.MethodGet {
					body := `{"linksByPlatform":{"spotify":{"url":"https://open.spotify.com/track/testspotifyid"},"deezer":{"url":"https://www.deezer.com/track/908604612"},"amazonMusic":{"url":"https://music.amazon.com/albums/B086Q2QNLH?trackAsin=B086Q41M9C"},"tidal":{"url":"https://listen.tidal.com/track/134858527"},"qobuz":{"url":"https://open.qobuz.com/track/195125822"},"youtubeMusic":{"url":"https://music.youtube.com/watch?v=testvideoid1"}}}`
					return &http.Response{
						StatusCode: 200,
						Header:     make(http.Header),
						Body:       io.NopCloser(strings.NewReader(body)),
						Request:    req,
					}, nil
				}
				t.Fatalf("unexpected request: %s %s", req.Method, req.URL.String())
				return nil, nil
			}),
		},
	}

	availability, err := client.CheckTrackAvailability("testspotifyid", "")
	if err != nil {
		t.Fatalf("CheckTrackAvailability() error = %v", err)
	}

	if availability.SpotifyID != "testspotifyid" {
		t.Fatalf("SpotifyID = %q, want %q", availability.SpotifyID, "testspotifyid")
	}
	if !availability.Deezer || availability.DeezerID != "908604612" {
		t.Fatalf("Deezer availability = %+v, want DeezerID 908604612", availability)
	}
	if !availability.Amazon || !availability.Tidal || !availability.Qobuz || !availability.YouTube {
		t.Fatalf("availability flags = %+v, want Amazon/Tidal/Qobuz/YouTube true", availability)
	}
	if availability.YouTubeID != "testvideoid1" {
		t.Fatalf("YouTubeID = %q, want %q", availability.YouTubeID, "testvideoid1")
	}
}

func TestCheckTrackAvailabilityFromSpotifyFallsBackToIDHS(t *testing.T) {
	resetTrackAvailabilityCache()
	origRetryConfig := songLinkRetryConfig
	songLinkRetryConfig = func() RetryConfig {
		return RetryConfig{MaxRetries: 0, InitialDelay: 0, MaxDelay: 0, BackoffFactor: 1}
	}
	defer func() { songLinkRetryConfig = origRetryConfig }()

	origIDHSClient := NewIDHSClient()
	origIDHSRateLimiter := idhsRateLimiter
	idhsRateLimiter = NewRateLimiter(100, time.Minute)
	globalIDHSClient = &IDHSClient{client: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		if req.URL.Host != "idonthavespotify.sjdonado.com" {
			t.Fatalf("unexpected IDHS request: %s", req.URL.String())
		}
		body := `{"type":"song","links":[{"type":"deezer","url":"https://www.deezer.com/track/908604612"},{"type":"tidal","url":"https://listen.tidal.com/track/134858527"}]}`
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     make(http.Header),
			Body:       io.NopCloser(strings.NewReader(body)),
			Request:    req,
		}, nil
	})}}
	defer func() {
		globalIDHSClient = origIDHSClient
		idhsRateLimiter = origIDHSRateLimiter
	}()

	client := &SongLinkClient{client: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		if req.URL.Host != "api.song.link" {
			t.Fatalf("retired resolver or unexpected host was called: %s", req.URL.String())
		}
		return &http.Response{
			StatusCode: http.StatusUnauthorized,
			Header:     make(http.Header),
			Body:       io.NopCloser(strings.NewReader(`{"error":"unauthorized"}`)),
			Request:    req,
		}, nil
	})}}

	availability, err := client.CheckTrackAvailability("spotify-idhs-fallback", "")
	if err != nil {
		t.Fatalf("CheckTrackAvailability() error = %v", err)
	}
	if availability.DeezerID != "908604612" || availability.TidalID != "134858527" {
		t.Fatalf("IDHS fallback availability = %+v", availability)
	}
}

func TestSongLinkPlatformKeyFromIDHS(t *testing.T) {
	tests := map[string]string{
		"youTube":      "youtubeMusic",
		"appleMusic":   "appleMusic",
		"amazon_music": "amazonMusic",
		"soundCloud":   "soundcloud",
		"unknown":      "",
	}
	for input, want := range tests {
		if got := songLinkPlatformKeyFromIDHS(input); got != want {
			t.Errorf("songLinkPlatformKeyFromIDHS(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestResolveTrackPlatformsByPlatformUsesSongLinkForSpotify(t *testing.T) {
	origRetryConfig := songLinkRetryConfig
	songLinkRetryConfig = func() RetryConfig {
		return RetryConfig{MaxRetries: 0, InitialDelay: 0, MaxDelay: 0, BackoffFactor: 1}
	}
	defer func() { songLinkRetryConfig = origRetryConfig }()

	client := &SongLinkClient{
		client: &http.Client{
			Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
				if req.URL.Host == "api.song.link" {
					if req.URL.Query().Get("platform") != "spotify" ||
						req.URL.Query().Get("type") != "song" ||
						req.URL.Query().Get("id") != "testspotifyid" {
						t.Fatalf("unexpected SongLink query: %s", req.URL.RawQuery)
					}
					body := `{"linksByPlatform":{"spotify":{"url":"https://open.spotify.com/track/testspotifyid"},"deezer":{"url":"https://www.deezer.com/track/908604612"},"tidal":{"url":"https://listen.tidal.com/track/134858527"}}}`
					return &http.Response{
						StatusCode: 200,
						Header:     make(http.Header),
						Body:       io.NopCloser(strings.NewReader(body)),
						Request:    req,
					}, nil
				}
				t.Fatalf("unexpected request: %s %s", req.Method, req.URL.String())
				return nil, nil
			}),
		},
	}

	links, err := client.resolveTrackPlatformsByPlatform("spotify", "song", "testspotifyid")
	if err != nil {
		t.Fatalf("resolveTrackPlatformsByPlatform() error = %v", err)
	}
	if links["deezer"].URL != "https://www.deezer.com/track/908604612" {
		t.Fatalf("Deezer link = %#v", links["deezer"])
	}
}

func TestCheckTrackAvailabilityFromSpotifySongLinkMixedURLShapes(t *testing.T) {
	resetTrackAvailabilityCache()
	origRetryConfig := songLinkRetryConfig
	defer func() { songLinkRetryConfig = origRetryConfig }()

	client := &SongLinkClient{
		client: &http.Client{
			Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
				if req.URL.Host == "api.song.link" && req.Method == http.MethodGet {
					body := `{"linksByPlatform":{"spotify":{"url":"https://open.spotify.com/track/5glgyj6zH0irbNGfukHacv"},"deezer":{"url":"https://www.deezer.com/track/2248583177"},"tidal":{"url":"https://tidal.com/browse/track/290565315"},"appleMusic":{"url":"https://geo.music.apple.com/us/album/example?i=1"},"youtubeMusic":null,"youtube":{"url":"https://www.youtube.com/watch?v=wD_e59XUNdQ"},"amazonMusic":{"url":"https://music.amazon.com/tracks/B0C35TG38Y/?ref=dm_ff_amazonmusic_3p"},"qobuz":null}}`
					return &http.Response{
						StatusCode: 200,
						Header:     make(http.Header),
						Body:       io.NopCloser(strings.NewReader(body)),
						Request:    req,
					}, nil
				}
				t.Fatalf("unexpected request: %s %s", req.Method, req.URL.String())
				return nil, nil
			}),
		},
	}

	availability, err := client.CheckTrackAvailability("5glgyj6zH0irbNGfukHacv", "")
	if err != nil {
		t.Fatalf("CheckTrackAvailability() error = %v", err)
	}

	if availability.SpotifyID != "5glgyj6zH0irbNGfukHacv" {
		t.Fatalf("SpotifyID = %q, want %q", availability.SpotifyID, "5glgyj6zH0irbNGfukHacv")
	}
	if !availability.Deezer || availability.DeezerID != "2248583177" {
		t.Fatalf("Deezer availability = %+v, want DeezerID 2248583177", availability)
	}
	if !availability.Tidal || availability.TidalID != "290565315" {
		t.Fatalf("Tidal availability = %+v, want TidalID 290565315", availability)
	}
	if availability.Qobuz {
		t.Fatalf("Qobuz should remain false when resolve response contains null, got %+v", availability)
	}
}

func TestCheckTrackAvailabilityCachesResult(t *testing.T) {
	resetTrackAvailabilityCache()
	origRetryConfig := songLinkRetryConfig
	defer func() { songLinkRetryConfig = origRetryConfig }()

	var calls int32
	client := &SongLinkClient{
		client: &http.Client{
			Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
				atomic.AddInt32(&calls, 1)
				if req.URL.Host != "api.song.link" {
					t.Fatalf("unexpected resolver host: %s", req.URL.Host)
				}
				body := `{"linksByPlatform":{"spotify":{"url":"https://open.spotify.com/track/cachedid"},"deezer":{"url":"https://www.deezer.com/track/111"}}}`
				return &http.Response{
					StatusCode: 200,
					Header:     make(http.Header),
					Body:       io.NopCloser(strings.NewReader(body)),
					Request:    req,
				}, nil
			}),
		},
	}

	first, err := client.CheckTrackAvailability("cachedid", "")
	if err != nil {
		t.Fatalf("first CheckTrackAvailability() error = %v", err)
	}
	second, err := client.CheckTrackAvailability("cachedid", "")
	if err != nil {
		t.Fatalf("second CheckTrackAvailability() error = %v", err)
	}

	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("expected 1 network call with caching, got %d", got)
	}
	if first == second {
		t.Fatal("expected cache to return a distinct clone, got same pointer")
	}
	if second.DeezerID != "111" {
		t.Fatalf("cached DeezerID = %q, want 111", second.DeezerID)
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

func TestCheckAvailabilityFromDeezerUsesSongLink(t *testing.T) {
	origRetryConfig := songLinkRetryConfig
	songLinkRetryConfig = func() RetryConfig {
		return RetryConfig{MaxRetries: 0, InitialDelay: 0, MaxDelay: 0, BackoffFactor: 1}
	}
	defer func() { songLinkRetryConfig = origRetryConfig }()

	client := &SongLinkClient{
		client: &http.Client{
			Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
				// Non-Spotify should go to SongLink, not resolve API
				if req.URL.Host == "api.zarz.moe" {
					t.Fatalf("non-Spotify URL should not hit resolve API, got: %s", req.URL.String())
					return nil, nil
				}
				if req.URL.Host == "api.song.link" {
					body := `{"linksByPlatform":{"spotify":{"url":"https://open.spotify.com/track/testid"},"deezer":{"url":"https://www.deezer.com/track/908604612"},"tidal":{"url":"https://listen.tidal.com/track/134858527"},"qobuz":{"url":"https://open.qobuz.com/track/195125822"},"youtubeMusic":{"url":"https://music.youtube.com/watch?v=testvid"}}}`
					return &http.Response{
						StatusCode: 200,
						Header:     make(http.Header),
						Body:       io.NopCloser(strings.NewReader(body)),
						Request:    req,
					}, nil
				}
				t.Fatalf("unexpected request: %s %s", req.Method, req.URL.String())
				return nil, nil
			}),
		},
	}

	availability, err := client.checkAvailabilityFromDeezerSongLink("908604612")
	if err != nil {
		t.Fatalf("checkAvailabilityFromDeezerSongLink() error = %v", err)
	}

	if !availability.Deezer || availability.DeezerID != "908604612" {
		t.Fatalf("Deezer = %+v, want DeezerID 908604612", availability)
	}
	if availability.SpotifyID != "testid" {
		t.Fatalf("SpotifyID = %q, want %q", availability.SpotifyID, "testid")
	}
}
