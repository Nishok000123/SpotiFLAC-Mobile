package gobackend

import (
	"bytes"
	"fmt"
	"image"
	_ "image/gif"
	"image/jpeg"
	"image/png"
	"io"
	"net/http"
	"sync"
	"time"

	xdraw "golang.org/x/image/draw"
	_ "golang.org/x/image/webp"
)

// downloadCoverToMemory downloads exactly the URL supplied by the metadata
// provider. Cover-resolution selection belongs to the provider extension;
// the app must not infer a provider from its CDN URL or rewrite that URL.
func downloadCoverToMemory(coverURL string) ([]byte, error) {
	if coverURL == "" {
		return nil, fmt.Errorf("no cover URL provided")
	}

	data, err := fetchCoverCached(coverURL)
	if err != nil {
		return nil, err
	}
	// Cached bytes are shared across goroutines and must never be mutated;
	// hand callers their own copy.
	return append([]byte(nil), data...), nil
}

const (
	embeddedCoverJPEGQuality = 88
    // Bound Library cover cache dimensions.
	libraryCoverMaxDimension = 800
	maxCoverDownloadBytes    = 24 * 1024 * 1024
	// Decoding arbitrary provider artwork allocates roughly four bytes per
	// pixel. Refuse pathological images before Decode so a malicious extension
	// cannot force an unbounded mobile allocation. Normal artwork through
	// 4000x4000 is still accepted and downscaled.
	maxCoverDecodePixels int64 = 16_000_000
)

// downloadCoverToMemorySized returns provider artwork with its aspect ratio
// preserved and its longest side capped at maxDimension. A non-positive limit
// keeps the original bytes. Images already within the limit are also returned
// byte-for-byte so this option never introduces needless generation loss.
func downloadCoverToMemorySized(coverURL string, maxDimension int) ([]byte, error) {
	if maxDimension <= 0 {
		return downloadCoverToMemory(coverURL)
	}

	variantKey := fmt.Sprintf("%s\x00max-dimension=%d", coverURL, maxDimension)
	data, err := fetchCoverCachedWithKey(variantKey, func() ([]byte, error) {
		original, fetchErr := fetchCoverCached(coverURL)
		if fetchErr != nil {
			return nil, fetchErr
		}
		resized, changed, resizeErr := resizeCoverForEmbedding(
			original,
			maxDimension,
		)
		if resizeErr != nil {
			// A requested limit is a hard ceiling. Omitting an unsupported cover is
			// preferable to silently embedding the oversized original. The default
			// (maxDimension == 0) never enters this path and remains compatible.
			return nil, fmt.Errorf("resize artwork: %w", resizeErr)
		}
		if changed {
			width, height := coverDimensions(resized)
			GoLog(
				"[Cover] Downscaled artwork to %dx%d (%d KB -> %d KB)",
				width,
				height,
				len(original)/1024,
				len(resized)/1024,
			)
		}
		return resized, nil
	})
	if err != nil {
		return nil, err
	}
	return append([]byte(nil), data...), nil
}

func resizeCoverForEmbedding(data []byte, maxDimension int) ([]byte, bool, error) {
	if len(data) == 0 || maxDimension <= 0 {
		return data, false, nil
	}

	config, format, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return nil, false, fmt.Errorf("decode artwork dimensions: %w", err)
	}
	if config.Width <= 0 || config.Height <= 0 {
		return nil, false, fmt.Errorf("invalid artwork dimensions %dx%d", config.Width, config.Height)
	}
	if config.Width <= maxDimension && config.Height <= maxDimension {
		return data, false, nil
	}
	if int64(config.Width)*int64(config.Height) > maxCoverDecodePixels {
		return nil, false, fmt.Errorf(
			"artwork dimensions %dx%d exceed safe decode limit",
			config.Width,
			config.Height,
		)
	}

	source, decodedFormat, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, false, fmt.Errorf("decode artwork: %w", err)
	}
	if decodedFormat != "" {
		format = decodedFormat
	}

	destinationWidth, destinationHeight := scaledCoverDimensions(
		config.Width,
		config.Height,
		maxDimension,
	)
	destination := image.NewRGBA(
		image.Rect(0, 0, destinationWidth, destinationHeight),
	)
	xdraw.ApproxBiLinear.Scale(
		destination,
		destination.Bounds(),
		source,
		source.Bounds(),
		xdraw.Over,
		nil,
	)

	var encoded bytes.Buffer
	if format == "png" {
		if err := png.Encode(&encoded, destination); err != nil {
			return nil, false, fmt.Errorf("encode resized PNG artwork: %w", err)
		}
	} else if err := jpeg.Encode(
		&encoded,
		destination,
		&jpeg.Options{Quality: embeddedCoverJPEGQuality},
	); err != nil {
		return nil, false, fmt.Errorf("encode resized JPEG artwork: %w", err)
	}

	return encoded.Bytes(), true, nil
}

func scaledCoverDimensions(width, height, maxDimension int) (int, int) {
	if width >= height {
		scaledHeight := max(1, (height*maxDimension+width/2)/width)
		return maxDimension, scaledHeight
	}
	scaledWidth := max(1, (width*maxDimension+height/2)/height)
	return scaledWidth, maxDimension
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
	return fetchCoverCachedWithKey(downloadURL, func() ([]byte, error) {
		return coverFetch(downloadURL)
	})
}

// fetchCoverCachedWithKey collapses both original cover downloads and derived
// size variants. This keeps native-worker album batches from decoding and
// resizing the same artwork once per track.
func fetchCoverCachedWithKey(
	cacheKey string,
	fetch func() ([]byte, error),
) ([]byte, error) {
	coverMu.Lock()
	if e, ok := coverCache[cacheKey]; ok {
		if time.Now().Before(e.expiresAt) {
			data := e.data
			coverMu.Unlock()
			return data, nil
		}
		delete(coverCache, cacheKey)
		coverCacheBytes -= len(e.data)
	}
	if call, ok := coverInflight[cacheKey]; ok {
		coverMu.Unlock()
		call.wg.Wait()
		return call.data, call.err
	}
	call := &coverInflightCall{}
	// Default error so a panicking fetch never strands waiters with a
	// (nil, nil) "success"; overwritten on normal completion.
	call.err = fmt.Errorf("cover fetch aborted")
	call.wg.Add(1)
	coverInflight[cacheKey] = call
	coverMu.Unlock()

	defer func() {
		call.wg.Done()
		coverMu.Lock()
		delete(coverInflight, cacheKey)
		coverMu.Unlock()
	}()

	data, err := fetch()
	call.data, call.err = data, err
	if err == nil {
		coverCachePut(cacheKey, data)
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
	if resp.ContentLength > maxCoverDownloadBytes {
		return nil, fmt.Errorf("cover download exceeds %d MiB limit", maxCoverDownloadBytes/(1024*1024))
	}

	data, err := io.ReadAll(io.LimitReader(resp.Body, maxCoverDownloadBytes+1))
	if err != nil {
		return nil, fmt.Errorf("failed to read cover data: %w", err)
	}
	if len(data) > maxCoverDownloadBytes {
		return nil, fmt.Errorf("cover download exceeds %d MiB limit", maxCoverDownloadBytes/(1024*1024))
	}

	width, height := coverDimensions(data)
	GoLog("[Cover] Downloaded %d KB (%dx%d)", len(data)/1024, width, height)

	return data, nil
}
