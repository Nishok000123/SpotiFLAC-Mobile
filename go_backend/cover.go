package gobackend

import (
	"bytes"
	"fmt"
	"image"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"net/http"
	"sync"
	"time"
)

// downloadCoverToMemory downloads exactly the URL supplied by the metadata
// provider. Cover-resolution selection belongs to the provider extension;
// the app must not infer a provider from its CDN URL or rewrite that URL.
func downloadCoverToMemory(coverURL string) ([]byte, error) {
	if coverURL == "" {
		return nil, fmt.Errorf("no cover URL provided")
	}

	GoLog("[Cover] Provider URL: %s", coverURL)
	data, err := fetchCoverCached(coverURL)
	if err != nil {
		return nil, err
	}
	// Cached bytes are shared across goroutines and must never be mutated;
	// hand callers their own copy.
	return append([]byte(nil), data...), nil
}

func coverDimensions(data []byte) (int, int) {
	if len(data) == 0 {
		return 0, 0
	}
	config, _, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil || config.Width <= 0 || config.Height <= 0 {
		return 0, 0
	}
	return config.Width, config.Height
}

const (
	coverCacheMaxBytes = 24 * 1024 * 1024
	coverCacheTTL      = 15 * time.Minute
)

type coverCacheEntry struct {
	data      []byte
	expiresAt time.Time
}

type coverInflightCall struct {
	wg   sync.WaitGroup
	data []byte
	err  error
}

var (
	coverMu         sync.Mutex
	coverCache      = map[string]*coverCacheEntry{}
	coverCacheBytes int
	coverInflight   = map[string]*coverInflightCall{}
	coverFetch      = fetchCoverBytes
)

func clearCoverMemoryCache() {
	coverMu.Lock()
	coverCache = map[string]*coverCacheEntry{}
	coverCacheBytes = 0
	coverMu.Unlock()
}

// fetchCoverCached returns cover bytes for a final URL, collapsing concurrent
// requests for the same URL into a single fetch (singleflight) and caching
// results in memory for the duration of an album batch. The returned slice is
// shared; callers must copy before mutating.
func fetchCoverCached(downloadURL string) ([]byte, error) {
	coverMu.Lock()
	if e, ok := coverCache[downloadURL]; ok {
		if time.Now().Before(e.expiresAt) {
			data := e.data
			coverMu.Unlock()
			return data, nil
		}
		delete(coverCache, downloadURL)
		coverCacheBytes -= len(e.data)
	}
	if call, ok := coverInflight[downloadURL]; ok {
		coverMu.Unlock()
		call.wg.Wait()
		return call.data, call.err
	}
	call := &coverInflightCall{}
	// Default error so a panicking fetch never strands waiters with a
	// (nil, nil) "success"; overwritten on normal completion.
	call.err = fmt.Errorf("cover fetch aborted")
	call.wg.Add(1)
	coverInflight[downloadURL] = call
	coverMu.Unlock()

	defer func() {
		call.wg.Done()
		coverMu.Lock()
		delete(coverInflight, downloadURL)
		coverMu.Unlock()
	}()

	data, err := coverFetch(downloadURL)
	call.data, call.err = data, err
	if err == nil {
		coverCachePut(downloadURL, data)
	}
	return data, err
}

func coverCachePut(downloadURL string, data []byte) {
	if len(data) == 0 || len(data) > coverCacheMaxBytes {
		return
	}
	coverMu.Lock()
	defer coverMu.Unlock()
	if e, ok := coverCache[downloadURL]; ok {
		coverCacheBytes -= len(e.data)
	}
	coverCache[downloadURL] = &coverCacheEntry{data: data, expiresAt: time.Now().Add(coverCacheTTL)}
	coverCacheBytes += len(data)
	for coverCacheBytes > coverCacheMaxBytes && len(coverCache) > 1 {
		var oldestKey string
		var oldest time.Time
		first := true
		for k, e := range coverCache {
			if first || e.expiresAt.Before(oldest) {
				oldest, oldestKey, first = e.expiresAt, k, false
			}
		}
		coverCacheBytes -= len(coverCache[oldestKey].data)
		delete(coverCache, oldestKey)
	}
}

func fetchCoverBytes(downloadURL string) ([]byte, error) {
	client := NewHTTPClientWithTimeout(DefaultTimeout)

	req, err := http.NewRequest("GET", downloadURL, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	resp, err := DoRequestWithUserAgent(client, req)
	if err != nil {
		return nil, fmt.Errorf("failed to download cover: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("cover download failed: HTTP %d", resp.StatusCode)
	}

	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read cover data: %w", err)
	}

	width, height := coverDimensions(data)
	GoLog("[Cover] Downloaded %d KB (%dx%d)", len(data)/1024, width, height)

	return data, nil
}
