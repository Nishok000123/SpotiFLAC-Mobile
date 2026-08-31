package gobackend

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

const (
	lyricsProviderUnavailableCooldown = 10 * time.Minute
	lyricsProviderParallelism         = 3
	lyricsProviderPriorityGrace       = 5000 * time.Millisecond
)

const (
	LyricsProviderLRCLIB     = "lrclib"
	LyricsProviderNetease    = "netease"
	LyricsProviderMusixmatch = "musixmatch"
	LyricsProviderAppleMusic = "apple_music"
	LyricsProviderQQMusic    = "qqmusic"
	LyricsProviderSpotify    = "spotify"
	LyricsProviderDeezer     = "deezer"
	LyricsProviderYouTube    = "youtube"
	LyricsProviderKugou      = "kugou"
	LyricsProviderGenius     = "genius"
	LyricsProviderLyricsPlus = "lyricsplus"
)

var DefaultLyricsProviders = []string{
	LyricsProviderLRCLIB,
	LyricsProviderAppleMusic,
}

var (
	lyricsProvidersMu sync.RWMutex
	lyricsProviders   []string // ordered list of enabled providers
	appVersionMu      sync.RWMutex
	appVersion        string
)

type lyricsProviderHealthEntry struct {
	unavailableUntil time.Time
	reason           string
}

type lyricsProviderSearchRequest struct {
	spotifyID       string
	trackName       string
	artistName      string
	primaryArtist   string
	simplifiedTrack string
	durationSec     float64
	fetchOptions    LyricsFetchOptions
}

type lyricsProviderSearchResult struct {
	index        int
	providerName string
	lyrics       *LyricsResponse
	err          error
}

var (
	lyricsProviderHealthMu sync.RWMutex
	lyricsProviderHealth   = make(map[string]lyricsProviderHealthEntry)
)

func SetAppVersion(version string) {
	normalized := strings.TrimSpace(version)

	appVersionMu.Lock()
	defer appVersionMu.Unlock()
	appVersion = normalized
}

func GetAppVersion() string {
	appVersionMu.RLock()
	defer appVersionMu.RUnlock()
	return appVersion
}

func appUserAgent() string {
	version := GetAppVersion()

	if version == "" {
		return "SpotiFLAC-Mobile"
	}

	return "SpotiFLAC-Mobile/" + version
}

type LyricsFetchOptions struct {
	IncludeTranslationNetease  bool   `json:"include_translation_netease"`
	IncludeRomanizationNetease bool   `json:"include_romanization_netease"`
	MultiPersonWordByWord      bool   `json:"multi_person_word_by_word"`
	AppleElrcWordSync          bool   `json:"apple_elrc_word_sync"`
	MusixmatchLanguage         string `json:"musixmatch_language,omitempty"`
}

var defaultLyricsFetchOptions = LyricsFetchOptions{
	IncludeTranslationNetease:  false,
	IncludeRomanizationNetease: false,
	MultiPersonWordByWord:      true,
	AppleElrcWordSync:          false,
	MusixmatchLanguage:         "",
}

var instrumentalTrackPattern = regexp.MustCompile(`(?i)(?:^|[\s\[(\-])(?:instrumental|inst\.?)(?:[\s\])]|$)`)

var (
	lyricsFetchOptionsMu sync.RWMutex
	lyricsFetchOptions   = defaultLyricsFetchOptions
)

func SetLyricsProviderOrder(providers []string) {
	lyricsProvidersMu.Lock()

	if len(providers) == 0 {
		changed := len(lyricsProviders) != 0
		lyricsProviders = nil
		lyricsProvidersMu.Unlock()
		clearLyricsProviderHealth()
		if changed {
			globalLyricsCache.ClearAll()
		}
		return
	}

	validNames := map[string]bool{
		LyricsProviderLRCLIB:     true,
		LyricsProviderNetease:    true,
		LyricsProviderMusixmatch: true,
		LyricsProviderAppleMusic: true,
		LyricsProviderQQMusic:    true,
		LyricsProviderSpotify:    true,
		LyricsProviderDeezer:     true,
		LyricsProviderYouTube:    true,
		LyricsProviderKugou:      true,
		LyricsProviderGenius:     true,
		LyricsProviderLyricsPlus: true,
	}

	valid := make([]string, 0, len(providers))
	seen := make(map[string]struct{}, len(providers))
	for _, p := range providers {
		normalized := strings.ToLower(strings.TrimSpace(p))
		isExtension := strings.HasPrefix(normalized, "extension:") &&
			strings.TrimSpace(strings.TrimPrefix(normalized, "extension:")) != ""
		if !validNames[normalized] && !isExtension {
			continue
		}
		if _, exists := seen[normalized]; exists {
			continue
		}
		seen[normalized] = struct{}{}
		valid = append(valid, normalized)
	}

	changed := !equalLyricsProviderOrders(lyricsProviders, valid)
	lyricsProviders = valid
	lyricsProvidersMu.Unlock()
	clearLyricsProviderHealth()
	if changed {
		globalLyricsCache.ClearAll()
	}
	GoLog("[Lyrics] Provider order set to: %v\n", valid)
}

func equalLyricsProviderOrders(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func clearLyricsProviderHealth() {
	lyricsProviderHealthMu.Lock()
	defer lyricsProviderHealthMu.Unlock()
	lyricsProviderHealth = make(map[string]lyricsProviderHealthEntry)
}

func lyricsProviderHealthKey(providerName string) string {
	return strings.ToLower(strings.TrimSpace(providerName))
}

func shouldSkipLyricsProvider(providerName string) (bool, time.Duration, string) {
	key := lyricsProviderHealthKey(providerName)
	if key == "" {
		return false, 0, ""
	}

	now := time.Now()
	lyricsProviderHealthMu.RLock()
	entry, ok := lyricsProviderHealth[key]
	lyricsProviderHealthMu.RUnlock()
	if !ok {
		return false, 0, ""
	}
	if !now.Before(entry.unavailableUntil) {
		lyricsProviderHealthMu.Lock()
		if current, exists := lyricsProviderHealth[key]; exists && !now.Before(current.unavailableUntil) {
			delete(lyricsProviderHealth, key)
		}
		lyricsProviderHealthMu.Unlock()
		return false, 0, ""
	}
	return true, time.Until(entry.unavailableUntil), entry.reason
}

func markLyricsProviderAvailable(providerName string) {
	key := lyricsProviderHealthKey(providerName)
	if key == "" {
		return
	}
	lyricsProviderHealthMu.Lock()
	delete(lyricsProviderHealth, key)
	lyricsProviderHealthMu.Unlock()
}

func markLyricsProviderUnavailable(providerName string, err error) {
	if err == nil || !isLyricsProviderUnavailableError(err) {
		return
	}
	key := lyricsProviderHealthKey(providerName)
	if key == "" {
		return
	}
	reason := strings.TrimSpace(err.Error())
	if len(reason) > 160 {
		reason = reason[:160]
	}
	unavailableUntil := time.Now().Add(lyricsProviderUnavailableCooldown)

	lyricsProviderHealthMu.Lock()
	lyricsProviderHealth[key] = lyricsProviderHealthEntry{
		unavailableUntil: unavailableUntil,
		reason:           reason,
	}
	lyricsProviderHealthMu.Unlock()
	GoLog("[Lyrics] Provider %s marked unavailable for %s: %s\n", providerName, lyricsProviderUnavailableCooldown, reason)
}

// isLyricsProviderUnavailableError reports whether err is a provider/API-level
// failure that should temporarily disable a lyrics source. Providers classify
// their failures with the typed errors in lyrics_errors.go at the point of
// origin; transport failures are handled by isConnectivityFailure.
func isLyricsProviderUnavailableError(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, errLyricsNotFound) {
		return false
	}
	if errors.Is(err, errLyricsServiceUnavailable) {
		return true
	}
	return isConnectivityFailure(err)
}

func GetLyricsProviderOrder() []string {
	lyricsProvidersMu.RLock()
	defer lyricsProvidersMu.RUnlock()

	if len(lyricsProviders) == 0 {
		result := make([]string, len(DefaultLyricsProviders))
		copy(result, DefaultLyricsProviders)
		return result
	}

	result := make([]string, len(lyricsProviders))
	copy(result, lyricsProviders)
	return result
}

func GetAvailableLyricsProviders() []map[string]any {
	return []map[string]any{
		{"id": LyricsProviderLRCLIB, "name": "LRCLIB", "has_proxy_dependency": false, "description": "Open-source synced lyrics database"},
		{"id": LyricsProviderNetease, "name": "Netease", "has_proxy_dependency": true, "description": "NetEase Cloud Music lyrics"},
		{"id": LyricsProviderMusixmatch, "name": "Musixmatch", "has_proxy_dependency": true, "description": "Musixmatch lyrics"},
		{"id": LyricsProviderAppleMusic, "name": "Apple Music", "has_proxy_dependency": true, "description": "Apple Music synced lyrics"},
		{"id": LyricsProviderQQMusic, "name": "QQ Music", "has_proxy_dependency": false, "description": "Direct QQ Music line-synced lyrics"},
		{"id": LyricsProviderSpotify, "name": "Spotify", "has_proxy_dependency": true, "description": "Spotify synced lyrics"},
		{"id": LyricsProviderDeezer, "name": "Deezer", "has_proxy_dependency": true, "description": "Deezer lyrics"},
		{"id": LyricsProviderYouTube, "name": "YouTube", "has_proxy_dependency": true, "description": "YouTube lyrics"},
		{"id": LyricsProviderKugou, "name": "Kugou", "has_proxy_dependency": false, "description": "Direct Kugou synced lyrics"},
		{"id": LyricsProviderGenius, "name": "Genius", "has_proxy_dependency": false, "description": "Direct Genius lyrics"},
		{"id": LyricsProviderLyricsPlus, "name": "LyricsPlus", "has_proxy_dependency": true, "description": "Word-by-word karaoke lyrics (Apple/Musixmatch/Spotify/QQ)"},
	}
}

func normalizeLyricsFetchOptions(opts LyricsFetchOptions) LyricsFetchOptions {
	opts.MusixmatchLanguage = strings.ToLower(strings.TrimSpace(opts.MusixmatchLanguage))
	opts.MusixmatchLanguage = regexp.MustCompile(`[^a-z0-9\-_]`).ReplaceAllString(opts.MusixmatchLanguage, "")
	if len(opts.MusixmatchLanguage) > 16 {
		opts.MusixmatchLanguage = opts.MusixmatchLanguage[:16]
	}
	return opts
}

func SetLyricsFetchOptions(opts LyricsFetchOptions) {
	normalized := normalizeLyricsFetchOptions(opts)

	lyricsFetchOptionsMu.Lock()
	changed := lyricsFetchOptions != normalized
	lyricsFetchOptions = normalized
	lyricsFetchOptionsMu.Unlock()

	if changed {
		globalLyricsCache.ClearAll()
	}

	GoLog("[Lyrics] Fetch options set: translation=%v romanization=%v multi_person=%v apple_elrc=%v musixmatch_lang=%q\n",
		normalized.IncludeTranslationNetease,
		normalized.IncludeRomanizationNetease,
		normalized.MultiPersonWordByWord,
		normalized.AppleElrcWordSync,
		normalized.MusixmatchLanguage,
	)
}

func GetLyricsFetchOptions() LyricsFetchOptions {
	lyricsFetchOptionsMu.RLock()
	defer lyricsFetchOptionsMu.RUnlock()
	return lyricsFetchOptions
}

type lyricsCacheEntry struct {
	response  *LyricsResponse
	expiresAt time.Time
}

type lyricsCache struct {
	mu                 sync.RWMutex
	cache              map[string]*lyricsCacheEntry
	persistencePath    string
	persistGeneration  uint64
	persistencePending bool
}

var globalLyricsCache = &lyricsCache{
	cache: make(map[string]*lyricsCacheEntry),
}

func (c *lyricsCache) generateKey(artist, track string, durationSec float64) string {
	return lyricsFetchCacheKey("", track, artist, durationSec)
}

func (c *lyricsCache) Get(artist, track string, durationSec float64) (*LyricsResponse, bool) {
	key := c.generateKey(artist, track, durationSec)
	c.mu.RLock()
	defer c.mu.RUnlock()

	entry, exists := c.cache[key]
	if !exists {
		return nil, false
	}

	if time.Now().After(entry.expiresAt) {
		return nil, false
	}

	responseCopy := *entry.response
	responseCopy.Lines = append([]LyricsLine(nil), entry.response.Lines...)
	return &responseCopy, true
}

const lyricsCacheMaxEntries = 500

func (c *lyricsCache) Set(artist, track string, durationSec float64, response *LyricsResponse) {
	key := c.generateKey(artist, track, durationSec)
	c.mu.Lock()
	defer c.mu.Unlock()

	// Bound the cache: without eviction a long session accumulates every
	// looked-up track's full lyrics forever.
	if len(c.cache) >= lyricsCacheMaxEntries {
		now := time.Now()
		for key, entry := range c.cache {
			if now.After(entry.expiresAt) {
				delete(c.cache, key)
			}
		}
		for len(c.cache) >= lyricsCacheMaxEntries {
			var oldestKey string
			var oldestAt time.Time
			for key, entry := range c.cache {
				if oldestKey == "" || entry.expiresAt.Before(oldestAt) {
					oldestKey = key
					oldestAt = entry.expiresAt
				}
			}
			delete(c.cache, oldestKey)
		}
	}

	c.cache[key] = &lyricsCacheEntry{
		response:  cloneLyricsResponse(response),
		expiresAt: time.Now().Add(lyricsCacheTTL),
	}
	c.schedulePersistenceLocked()
}

func (c *lyricsCache) CleanExpired() int {
	c.mu.Lock()
	defer c.mu.Unlock()

	now := time.Now()
	cleaned := 0
	for key, entry := range c.cache {
		if now.After(entry.expiresAt) {
			delete(c.cache, key)
			cleaned++
		}
	}
	return cleaned
}

func (c *lyricsCache) Size() int {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return len(c.cache)
}

func (c *lyricsCache) ClearAll() int {
	c.mu.Lock()
	defer c.mu.Unlock()

	cleared := len(c.cache)
	c.cache = make(map[string]*lyricsCacheEntry)
	c.schedulePersistenceLocked()
	return cleared
}

// DropMemory releases the in-memory snapshot without deleting the persistent
// cache. It is used for OS memory-pressure handling; a later app start can
// still restore successful lyrics lookups from disk.
func (c *lyricsCache) DropMemory() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	cleared := len(c.cache)
	c.cache = make(map[string]*lyricsCacheEntry)
	return cleared
}

type persistedLyricsCacheEntry struct {
	Response  *LyricsResponse `json:"response"`
	ExpiresAt int64           `json:"expires_at"`
}

type persistedLyricsCache struct {
	Version int                                  `json:"version"`
	Entries map[string]persistedLyricsCacheEntry `json:"entries"`
}

func cloneLyricsResponse(response *LyricsResponse) *LyricsResponse {
	if response == nil {
		return nil
	}
	copy := *response
	copy.Lines = append([]LyricsLine(nil), response.Lines...)
	return &copy
}

func (c *lyricsCache) SetPersistencePath(path string) {
	path = filepath.Clean(strings.TrimSpace(path))
	if path == "." || path == "" {
		return
	}

	data, err := os.ReadFile(path)
	loaded := make(map[string]*lyricsCacheEntry)
	if err == nil {
		var persisted persistedLyricsCache
		if json.Unmarshal(data, &persisted) == nil && persisted.Version == 1 {
			now := time.Now()
			for key, entry := range persisted.Entries {
				expiresAt := time.Unix(entry.ExpiresAt, 0)
				if entry.Response == nil || !now.Before(expiresAt) {
					continue
				}
				loaded[key] = &lyricsCacheEntry{
					response:  cloneLyricsResponse(entry.Response),
					expiresAt: expiresAt,
				}
				if len(loaded) >= lyricsCacheMaxEntries {
					break
				}
			}
		}
	}

	c.mu.Lock()
	c.persistencePath = path
	for key, entry := range loaded {
		if _, exists := c.cache[key]; !exists {
			c.cache[key] = entry
		}
	}
	c.mu.Unlock()
}

func (c *lyricsCache) schedulePersistenceLocked() {
	if c.persistencePath == "" {
		return
	}
	c.persistGeneration++
	if c.persistencePending {
		return
	}
	c.persistencePending = true
	go c.persistAfterDebounce()
}

func (c *lyricsCache) persistAfterDebounce() {
	time.Sleep(500 * time.Millisecond)
	for {
		c.mu.RLock()
		path := c.persistencePath
		generation := c.persistGeneration
		snapshot := persistedLyricsCache{
			Version: 1,
			Entries: make(map[string]persistedLyricsCacheEntry, len(c.cache)),
		}
		for key, entry := range c.cache {
			snapshot.Entries[key] = persistedLyricsCacheEntry{
				Response:  cloneLyricsResponse(entry.response),
				ExpiresAt: entry.expiresAt.Unix(),
			}
		}
		c.mu.RUnlock()

		if data, err := json.Marshal(snapshot); err == nil {
			if err := os.MkdirAll(filepath.Dir(path), 0700); err == nil {
				tempPath := path + ".tmp"
				if os.WriteFile(tempPath, data, 0600) == nil {
					if err := os.Rename(tempPath, path); err != nil {
						_ = os.Remove(tempPath)
					}
				}
			}
		}

		c.mu.Lock()
		if generation == c.persistGeneration {
			c.persistencePending = false
			c.mu.Unlock()
			return
		}
		c.mu.Unlock()
		time.Sleep(100 * time.Millisecond)
	}
}
