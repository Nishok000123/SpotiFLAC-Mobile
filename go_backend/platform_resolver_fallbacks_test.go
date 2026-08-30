package gobackend

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

func resolverTestResponse(req *http.Request, status int, body string) *http.Response {
	return &http.Response{
		StatusCode: status,
		Header:     make(http.Header),
		Body:       io.NopCloser(strings.NewReader(body)),
		Request:    req,
	}
}

func TestUnituneResolverKeepsOnlyDirectTrustedLinks(t *testing.T) {
	resolver := &unituneResolver{
		client: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
			if req.URL.Host != "api.unitune.art" || req.URL.Query().Get("url") == "" {
				t.Fatalf("unexpected UniTune request: %s", req.URL.String())
			}
			return resolverTestResponse(req, http.StatusOK, `{
				"entityUniqueId":"SPOTIFY::TRACK::source",
				"entitiesByUniqueId":{"SPOTIFY::TRACK::source":{"title":"Track","artistName":"Artist"}},
				"linksByPlatform":{
					"spotify":{"url":"https://open.spotify.com/track/source"},
					"deezer":{"url":"https://www.deezer.com/track/123"},
					"tidal":{"url":"https://listen.tidal.com/search?q=Track"},
					"appleMusic":{"url":"https://music.apple.com/search?term=Track"},
					"amazonMusic":{"url":"https://evil.example/track/123"}
				}
			}`), nil
		})},
		rateLimiter: NewRateLimiter(100, time.Minute),
	}

	result, err := resolver.Resolve(context.Background(), "https://open.spotify.com/track/source", resolverMetadata{})
	if err != nil {
		t.Fatalf("Resolve() error = %v", err)
	}
	if len(result.Links) != 2 || result.Links["deezer"].URL == "" || result.Links["spotify"].URL == "" {
		t.Fatalf("direct links = %#v, want only Spotify and Deezer", result.Links)
	}
	if result.Metadata.Title != "Track" || result.Metadata.Artist != "Artist" {
		t.Fatalf("metadata = %+v", result.Metadata)
	}
}

func TestMusicBrainzResolverAcceptsVerifiedProviderRelations(t *testing.T) {
	resolver := &musicBrainzPlatformResolver{
		client: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
			switch req.URL.Path {
			case "/ws/2/recording":
				return resolverTestResponse(req, http.StatusOK, `{
					"recordings":[
						{"id":"wrong","score":100,"title":"Live Version","artist-credit":[{"name":"Artist"}]},
						{"id":"match","score":100,"title":"Track","artist-credit":[{"name":"Artist"}]}
					]
				}`), nil
			case "/ws/2/recording/match":
				return resolverTestResponse(req, http.StatusOK, `{
					"relations":[
						{"url":{"resource":"https://open.spotify.com/track/spotify-id"}},
						{"url":{"resource":"https://tidal.com/browse/track/123"}},
						{"url":{"resource":"https://evil.example/track/not-allowed"}}
					]
				}`), nil
			default:
				t.Fatalf("unexpected MusicBrainz request: %s", req.URL.String())
				return nil, nil
			}
		})},
		rateLimiter: NewRateLimiter(100, time.Minute),
	}

	result, err := resolver.Resolve(
		context.Background(),
		"https://example.invalid/source",
		resolverMetadata{Title: "Track", Artist: "Artist"},
	)
	if err != nil {
		t.Fatalf("Resolve() error = %v", err)
	}
	if len(result.Links) != 2 || result.Links["spotify"].URL == "" || result.Links["tidal"].URL == "" {
		t.Fatalf("MusicBrainz links = %#v", result.Links)
	}
}

func TestSquiglyResolverParsesEmbeddedPayload(t *testing.T) {
	resolver := &squiglyResolver{
		client: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
			switch {
			case req.Method == http.MethodPost && req.URL.Path == "/api/create":
				return resolverTestResponse(req, http.StatusCreated, `{
					"full_url":"https://squigly.link/song/artist/track",
					"title":"Track",
					"artist":"Artist"
				}`), nil
			case req.Method == http.MethodGet && req.URL.Path == "/song/artist/track":
				return resolverTestResponse(req, http.StatusOK, `<html><script>
					window.__SQUIGLY_LINK__ = {"data":{"title":"Track","artist":"Artist","services":{
						"spotify":{"url":"https://open.spotify.com/track/spotify-id"},
						"apple":{"url":"https://music.apple.com/us/album/track/1?i=2"},
						"tidal":{"url":"https://tidal.com/browse/track/3"},
						"bandcamp":null
					}}};
				</script></html>`), nil
			default:
				t.Fatalf("unexpected Squigly request: %s %s", req.Method, req.URL.String())
				return nil, nil
			}
		})},
		rateLimiter: NewRateLimiter(100, time.Minute),
	}

	result, err := resolver.Resolve(context.Background(), "https://open.spotify.com/track/source", resolverMetadata{})
	if err != nil {
		t.Fatalf("Resolve() error = %v", err)
	}
	if len(result.Links) != 3 || result.Links["appleMusic"].URL == "" || result.Links["tidal"].URL == "" {
		t.Fatalf("Squigly links = %#v", result.Links)
	}
}

type stubPlatformResolver struct {
	calls  int
	result resolverResult
	err    error
}

func (r *stubPlatformResolver) Resolve(context.Context, string, resolverMetadata) (resolverResult, error) {
	r.calls++
	return r.result, r.err
}

func TestPlatformResolverChainMergesFallbacksWithoutReplacingEarlierLinks(t *testing.T) {
	unitune := &stubPlatformResolver{result: resolverResult{
		Metadata: resolverMetadata{Title: "Track", Artist: "Artist"},
		Links: map[string]songLinkPlatformLink{
			"spotify":      {URL: "https://open.spotify.com/track/source"},
			"deezer":       {URL: "https://www.deezer.com/track/1"},
			"youtubeMusic": {URL: "https://music.youtube.com/watch?v=one"},
		},
	}}
	musicBrainz := &stubPlatformResolver{result: resolverResult{Links: map[string]songLinkPlatformLink{
		"spotify":    {URL: "https://open.spotify.com/track/different"},
		"appleMusic": {URL: "https://music.apple.com/us/album/track/1?i=2"},
	}}}
	squigly := &stubPlatformResolver{result: resolverResult{Links: map[string]songLinkPlatformLink{
		"tidal": {URL: "https://tidal.com/browse/track/3"},
	}}}
	chain := &platformResolverChain{unitune: unitune, musicBrainz: musicBrainz, squigly: squigly}

	result, err := chain.Resolve(context.Background(), "https://open.spotify.com/track/source", resolverMetadata{})
	if err != nil {
		t.Fatalf("Resolve() error = %v", err)
	}
	if unitune.calls != 1 || musicBrainz.calls != 1 || squigly.calls != 1 {
		t.Fatalf("resolver calls = %d/%d/%d, want 1/1/1", unitune.calls, musicBrainz.calls, squigly.calls)
	}
	if result.Links["spotify"].URL != "https://open.spotify.com/track/source" {
		t.Fatalf("earlier resolver link was replaced: %#v", result.Links["spotify"])
	}
	if len(result.Links) != 5 || result.Links["tidal"].URL == "" {
		t.Fatalf("merged links = %#v", result.Links)
	}
}

func TestAdditionalResolversRunOnlyAfterSongLinkAndIDHSFail(t *testing.T) {
	originalIDHSClient := NewIDHSClient()
	originalIDHSLimiter := idhsRateLimiter
	originalRetryConfig := songLinkRetryConfig
	defer func() {
		globalIDHSClient = originalIDHSClient
		idhsRateLimiter = originalIDHSLimiter
		songLinkRetryConfig = originalRetryConfig
	}()

	idhsRateLimiter = NewRateLimiter(100, time.Minute)
	globalIDHSClient = &IDHSClient{client: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		return resolverTestResponse(req, http.StatusBadGateway, `{"error":"unavailable"}`), nil
	})}}
	songLinkRetryConfig = func() RetryConfig {
		return RetryConfig{MaxRetries: 0, BackoffFactor: 1}
	}
	additional := &stubPlatformResolver{result: resolverResult{Links: map[string]songLinkPlatformLink{
		"deezer": {URL: "https://www.deezer.com/track/123"},
	}}}
	client := &SongLinkClient{
		client: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
			return resolverTestResponse(req, http.StatusUnauthorized, `{"error":"deprecated"}`), nil
		})},
		fallbackResolver: additional,
	}

	links, err := client.resolveTrackPlatformsWithIDHSUncoalesced("https://open.spotify.com/track/source")
	if err != nil {
		t.Fatalf("resolveTrackPlatformsWithIDHSUncoalesced() error = %v", err)
	}
	if additional.calls != 1 || links["deezer"].URL == "" {
		t.Fatalf("additional resolver calls/links = %d/%#v", additional.calls, links)
	}
}
