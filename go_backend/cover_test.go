package gobackend

import (
	"bytes"
	"fmt"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func encodedTestCover(t *testing.T, width, height int, format string) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, width, height))
	for y := 0; y < height; y++ {
		for x := 0; x < width; x++ {
			img.SetRGBA(x, y, color.RGBA{
				R: uint8(x % 256),
				G: uint8(y % 256),
				B: uint8((x + y) % 256),
				A: uint8(128 + (x+y)%128),
			})
		}
	}

	var encoded bytes.Buffer
	var err error
	if format == "png" {
		err = png.Encode(&encoded, img)
	} else {
		err = jpeg.Encode(&encoded, img, &jpeg.Options{Quality: 95})
	}
	if err != nil {
		t.Fatalf("encode test cover: %v", err)
	}
	return encoded.Bytes()
}

func resetCoverCache() {
	coverMu.Lock()
	coverCache = map[string]*coverCacheEntry{}
	coverInflight = map[string]*coverInflightCall{}
	coverCacheBytes = 0
	coverMu.Unlock()
}

func TestFetchCoverCachedSingleflight(t *testing.T) {
	orig := coverFetch
	defer func() { coverFetch = orig }()
	resetCoverCache()

	var calls int32
	entered := make(chan struct{})
	release := make(chan struct{})
	coverFetch = func(string) ([]byte, error) {
		if atomic.AddInt32(&calls, 1) == 1 {
			close(entered)
		}
		<-release
		return []byte("coverbytes"), nil
	}

	const url = "https://cdn.example/cover_max.jpg"
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		if _, err := fetchCoverCached(url); err != nil {
			t.Errorf("leader fetch error: %v", err)
		}
	}()

	<-entered // leader has registered inflight and is blocked in coverFetch

	wg.Add(1)
	go func() {
		defer wg.Done()
		if _, err := fetchCoverCached(url); err != nil {
			t.Errorf("follower fetch error: %v", err)
		}
	}()

	close(release)
	wg.Wait()

	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("expected 1 fetch for concurrent requests, got %d", got)
	}
}

func TestFetchCoverCachedTTLExpiry(t *testing.T) {
	orig := coverFetch
	defer func() { coverFetch = orig }()
	resetCoverCache()

	var calls int32
	coverFetch = func(string) ([]byte, error) {
		atomic.AddInt32(&calls, 1)
		return []byte("data"), nil
	}

	const url = "https://cdn.example/ttl.jpg"
	if _, err := fetchCoverCached(url); err != nil {
		t.Fatalf("first fetch error: %v", err)
	}
	if _, err := fetchCoverCached(url); err != nil {
		t.Fatalf("second fetch error: %v", err)
	}
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("expected cache hit, got %d fetches", got)
	}

	coverMu.Lock()
	coverCache[url].expiresAt = time.Now().Add(-time.Minute)
	coverMu.Unlock()

	if _, err := fetchCoverCached(url); err != nil {
		t.Fatalf("third fetch error: %v", err)
	}
	if got := atomic.LoadInt32(&calls); got != 2 {
		t.Fatalf("expected refetch after TTL expiry, got %d fetches", got)
	}
}

func TestDownloadCoverUsesProviderURLUnchanged(t *testing.T) {
	orig := coverFetch
	defer func() { coverFetch = orig }()
	resetCoverCache()

	const providerURL = "https://i.scdn.co/image/ab67616d00001e02example"
	var requestedURL string
	coverFetch = func(url string) ([]byte, error) {
		requestedURL = url
		return []byte("provider-cover"), nil
	}

	got, err := downloadCoverToMemory(providerURL)
	if err != nil {
		t.Fatalf("download provider cover: %v", err)
	}
	if requestedURL != providerURL {
		t.Fatalf("requested URL = %q, want provider URL %q", requestedURL, providerURL)
	}
	if string(got) != "provider-cover" {
		t.Fatalf("downloaded cover = %q", got)
	}
}

func TestFetchCoverBytesRejectsOversizedResponse(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Content-Length", fmt.Sprintf("%d", maxCoverDownloadBytes+1))
		writer.WriteHeader(http.StatusOK)
	}))
	defer server.Close()
	SetAllowPrivateNetwork(true)
	defer SetAllowPrivateNetwork(false)

	if _, err := fetchCoverBytes(server.URL); err == nil || !strings.Contains(err.Error(), "exceeds") {
		t.Fatalf("expected oversized cover rejection, got %v", err)
	}
}

func TestResizeCoverForEmbeddingPreservesAspectRatio(t *testing.T) {
	original := encodedTestCover(t, 1200, 600, "jpeg")

	resized, changed, err := resizeCoverForEmbedding(original, 500)
	if err != nil {
		t.Fatalf("resize cover: %v", err)
	}
	if !changed {
		t.Fatal("expected oversized artwork to be resized")
	}
	config, format, err := image.DecodeConfig(bytes.NewReader(resized))
	if err != nil {
		t.Fatalf("decode resized cover config: %v", err)
	}
	if config.Width != 500 || config.Height != 250 {
		t.Fatalf("resized dimensions = %dx%d, want 500x250", config.Width, config.Height)
	}
	if format != "jpeg" {
		t.Fatalf("resized format = %q, want jpeg", format)
	}
}

func TestResizeCoverForEmbeddingKeepsSmallArtworkByteForByte(t *testing.T) {
	original := encodedTestCover(t, 320, 320, "jpeg")

	resized, changed, err := resizeCoverForEmbedding(original, 500)
	if err != nil {
		t.Fatalf("resize cover: %v", err)
	}
	if changed {
		t.Fatal("artwork within the limit should not be re-encoded")
	}
	if !bytes.Equal(resized, original) {
		t.Fatal("artwork within the limit was modified")
	}
}

func TestResizeCoverForEmbeddingPreservesPNG(t *testing.T) {
	original := encodedTestCover(t, 600, 1200, "png")

	resized, changed, err := resizeCoverForEmbedding(original, 500)
	if err != nil {
		t.Fatalf("resize PNG cover: %v", err)
	}
	if !changed {
		t.Fatal("expected oversized PNG artwork to be resized")
	}
	config, format, err := image.DecodeConfig(bytes.NewReader(resized))
	if err != nil {
		t.Fatalf("decode resized PNG config: %v", err)
	}
	if config.Width != 250 || config.Height != 500 {
		t.Fatalf("resized dimensions = %dx%d, want 250x500", config.Width, config.Height)
	}
	if format != "png" {
		t.Fatalf("resized format = %q, want png", format)
	}
}

func TestDownloadCoverToMemorySizedCachesDerivedVariant(t *testing.T) {
	originalFetch := coverFetch
	defer func() { coverFetch = originalFetch }()
	resetCoverCache()

	original := encodedTestCover(t, 1200, 600, "jpeg")
	var calls int32
	coverFetch = func(string) ([]byte, error) {
		atomic.AddInt32(&calls, 1)
		return original, nil
	}

	for range 2 {
		resized, err := downloadCoverToMemorySized(
			"https://cdn.example/album.jpg",
			500,
		)
		if err != nil {
			t.Fatalf("download sized cover: %v", err)
		}
		width, height := coverDimensions(resized)
		if width != 500 || height != 250 {
			t.Fatalf("sized cover = %dx%d, want 500x250", width, height)
		}
	}
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("provider cover fetched %d times, want once", got)
	}
}
