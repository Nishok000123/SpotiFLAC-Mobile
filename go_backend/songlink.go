package gobackend

import (
	"context"
	"fmt"
	"net/url"
	"strings"
	"sync"
	"time"

	"golang.org/x/sync/singleflight"
)

type SongLinkClient struct {
	fallbackResolver    platformFallbackResolver
	resolutionFlight    singleflight.Group
	availabilityFlight  singleflight.Group
	platformLinksFlight singleflight.Group
}

type songLinkPlatformLink struct {
	URL string `json:"url"`
}

type TrackAvailability struct {
	SpotifyID  string `json:"spotify_id"`
	Tidal      bool   `json:"tidal"`
	Amazon     bool   `json:"amazon"`
	Qobuz      bool   `json:"qobuz"`
	Deezer     bool   `json:"deezer"`
	YouTube    bool   `json:"youtube"`
	TidalURL   string `json:"tidal_url,omitempty"`
	AmazonURL  string `json:"amazon_url,omitempty"`
	QobuzURL   string `json:"qobuz_url,omitempty"`
	DeezerURL  string `json:"deezer_url,omitempty"`
	YouTubeURL string `json:"youtube_url,omitempty"`
	DeezerID   string `json:"deezer_id,omitempty"`
	QobuzID    string `json:"qobuz_id,omitempty"`
	TidalID    string `json:"tidal_id,omitempty"`
	YouTubeID  string `json:"youtube_id,omitempty"`
}

var (
	globalSongLinkClient *SongLinkClient
	songLinkClientOnce   sync.Once
	songLinkRegion       = "US"
	songLinkRegionMu     sync.RWMutex
	songLinkSearchByISRC = func(ctx context.Context, isrc string) (*TrackMetadata, error) {
		return GetDeezerClient().SearchByISRC(ctx, isrc)
	}
	songLinkCheckAvailabilityFromDeezer = func(s *SongLinkClient, deezerTrackID string) (*TrackAvailability, error) {
		return s.CheckAvailabilityFromDeezer(deezerTrackID)
	}
)

func NewSongLinkClient() *SongLinkClient {
	songLinkClientOnce.Do(func() {
		globalSongLinkClient = &SongLinkClient{
			fallbackResolver: defaultPlatformResolverFallbacks,
		}
	})
	return globalSongLinkClient
}

func normalizeSongLinkRegion(region string) string {
	normalized := strings.ToUpper(strings.TrimSpace(region))
	if len(normalized) != 2 {
		return "US"
	}
	for _, ch := range normalized {
		if ch < 'A' || ch > 'Z' {
			return "US"
		}
	}
	return normalized
}

func SetSongLinkRegion(region string) {
	normalized := normalizeSongLinkRegion(region)
	songLinkRegionMu.Lock()
	songLinkRegion = normalized
	songLinkRegionMu.Unlock()
}

func GetSongLinkRegion() string {
	songLinkRegionMu.RLock()
	region := songLinkRegion
	songLinkRegionMu.RUnlock()
	return region
}

// resolveTrackPlatforms resolves a music URL through the active resolver
// chain. SongLinkClient remains as the compatibility facade used by the Dart
// and native bridges, but retired resolver services are not contacted.
func (s *SongLinkClient) resolveTrackPlatforms(inputURL string) (map[string]songLinkPlatformLink, error) {
	value, err, _ := s.resolutionFlight.Do(inputURL, func() (any, error) {
		return s.resolveTrackPlatformsUncoalesced(inputURL)
	})
	if err != nil {
		return nil, err
	}
	return cloneSongLinkPlatformLinks(value.(map[string]songLinkPlatformLink)), nil
}

func (s *SongLinkClient) resolveTrackPlatformsUncoalesced(inputURL string) (map[string]songLinkPlatformLink, error) {
	fallbackResolver := s.fallbackResolver
	if fallbackResolver == nil {
		fallbackResolver = defaultPlatformResolverFallbacks
	}
	ctx, cancel := context.WithTimeout(context.Background(), resolverFallbackTimeout)
	defer cancel()
	additional, additionalErr := fallbackResolver.Resolve(ctx, inputURL, resolverMetadata{})
	if additionalErr == nil && len(additional.Links) > 0 {
		LogInfo("PlatformResolver", "Resolver chain returned %d platform links", len(additional.Links))
		return additional.Links, nil
	}
	if additionalErr == nil {
		additionalErr = fmt.Errorf("additional resolvers returned no platform links")
	}

	return nil, fmt.Errorf("platform resolvers failed: %w", additionalErr)
}

// resolveTrackPlatformsByPlatform resolves using platform + type + id.
func (s *SongLinkClient) resolveTrackPlatformsByPlatform(platform, entityType, entityID string) (map[string]songLinkPlatformLink, error) {
	inputURL, err := resolverURLFromPlatformID(platform, entityType, entityID)
	if err != nil {
		return nil, err
	}
	return s.resolveTrackPlatforms(inputURL)
}

func cloneSongLinkPlatformLinks(links map[string]songLinkPlatformLink) map[string]songLinkPlatformLink {
	if links == nil {
		return nil
	}
	cloned := make(map[string]songLinkPlatformLink, len(links))
	for platform, link := range links {
		cloned[platform] = link
	}
	return cloned
}

const (
	trackAvailabilityCacheTTL    = 30 * time.Minute
	trackAvailabilityNegCacheTTL = 5 * time.Minute
	trackAvailabilityCacheMax    = 500
)

type trackAvailabilityCacheEntry struct {
	availability *TrackAvailability
	err          bool
	expiresAt    time.Time
}

var (
	trackAvailabilityCacheMu sync.Mutex
	trackAvailabilityCache   = map[string]trackAvailabilityCacheEntry{}
)

// CheckTrackAvailability resolves platform availability for a track. Results are
// cached in memory (keyed by region + spotifyID/ISRC) to spare the song.link
// path its 9 req/min budget. This is an extra layer beneath the Dart-side
// cached-invoke and is safe: lookups are idempotent. Negative results use a
// shorter TTL so transient failures recover quickly.
func (s *SongLinkClient) CheckTrackAvailability(spotifyTrackID string, isrc string) (*TrackAvailability, error) {
	spotifyTrackID = strings.TrimSpace(spotifyTrackID)
	isrc = strings.ToUpper(strings.TrimSpace(isrc))

	var idKey string
	switch {
	case spotifyTrackID != "":
		idKey = "spotify:" + spotifyTrackID
	case isrc != "":
		idKey = "isrc:" + isrc
	default:
		return nil, fmt.Errorf("spotify track ID and ISRC are empty")
	}
	key := GetSongLinkRegion() + "|" + idKey

	if cached, hit, cachedErr := trackAvailabilityCacheLookup(key); hit {
		if cachedErr {
			return nil, fmt.Errorf("track availability unavailable (cached)")
		}
		return cloneTrackAvailability(cached), nil
	}

	value, err, _ := s.availabilityFlight.Do(key, func() (any, error) {
		// Another caller may have populated the cache while this caller was
		// waiting to become the singleflight owner.
		if cached, hit, cachedErr := trackAvailabilityCacheLookup(key); hit {
			if cachedErr {
				return nil, fmt.Errorf("track availability unavailable (cached)")
			}
			return cached, nil
		}

		var availability *TrackAvailability
		var resolveErr error
		switch {
		case spotifyTrackID != "":
			availability, resolveErr = s.checkTrackAvailabilityFromSpotify(spotifyTrackID)
		default:
			availability, resolveErr = s.checkTrackAvailabilityFromISRC(isrc)
		}
		trackAvailabilityCacheStore(key, availability, resolveErr)
		return availability, resolveErr
	})
	if err != nil {
		return nil, err
	}
	return cloneTrackAvailability(value.(*TrackAvailability)), nil
}

const trackPlatformLinksCacheMax = 200

type trackPlatformLinksCacheEntry struct {
	links     map[string]string
	err       bool
	expiresAt time.Time
}

var (
	trackPlatformLinksCacheMu sync.Mutex
	trackPlatformLinksCache   = map[string]trackPlatformLinksCacheEntry{}
)

// GetTrackPlatformLinks returns every streaming-platform URL song.link knows
// for a track, keyed by song.link platform ID. Cached in memory like
// CheckTrackAvailability to spare the same request budget.
func (s *SongLinkClient) GetTrackPlatformLinks(spotifyTrackID string, isrc string) (map[string]string, error) {
	spotifyTrackID = strings.TrimSpace(spotifyTrackID)
	isrc = strings.ToUpper(strings.TrimSpace(isrc))

	var idKey string
	switch {
	case spotifyTrackID != "":
		idKey = "spotify:" + spotifyTrackID
	case isrc != "":
		idKey = "isrc:" + isrc
	default:
		return nil, fmt.Errorf("spotify track ID and ISRC are empty")
	}
	key := GetSongLinkRegion() + "|" + idKey

	if links, hit, cachedErr := trackPlatformLinksCacheLookup(key); hit {
		if cachedErr {
			return nil, fmt.Errorf("track platform links unavailable (cached)")
		}
		return links, nil
	}

	value, err, _ := s.platformLinksFlight.Do(key, func() (any, error) {
		if links, hit, cachedErr := trackPlatformLinksCacheLookup(key); hit {
			if cachedErr {
				return nil, fmt.Errorf("track platform links unavailable (cached)")
			}
			return links, nil
		}
		links, fetchErr := s.fetchTrackPlatformLinks(spotifyTrackID, isrc)
		trackPlatformLinksCacheStore(key, links, fetchErr)
		return links, fetchErr
	})
	if err != nil {
		return nil, err
	}
	return cloneStringMap(value.(map[string]string)), nil
}

func (s *SongLinkClient) fetchTrackPlatformLinks(spotifyTrackID string, isrc string) (map[string]string, error) {
	var raw map[string]songLinkPlatformLink
	var err error
	if spotifyTrackID != "" {
		raw, err = s.resolveTrackPlatforms(
			fmt.Sprintf("https://open.spotify.com/track/%s", spotifyTrackID),
		)
	} else {
		ctx, cancel := context.WithTimeout(context.Background(), SongLinkTimeout)
		defer cancel()
		track, isrcErr := songLinkSearchByISRC(ctx, isrc)
		if isrcErr != nil {
			return nil, fmt.Errorf("failed to resolve Deezer track from ISRC %s: %w", isrc, isrcErr)
		}
		deezerTrackID := songLinkExtractDeezerTrackID(track)
		if deezerTrackID == "" {
			return nil, fmt.Errorf("failed to resolve Deezer track ID from ISRC %s", isrc)
		}
		raw, err = s.resolveTrackPlatforms(
			fmt.Sprintf("https://www.deezer.com/track/%s", deezerTrackID),
		)
	}
	if err != nil {
		return nil, err
	}

	links := make(map[string]string, len(raw))
	for platform, link := range raw {
		if url := normalizeShareURL(link.URL); url != "" {
			links[platform] = url
		}
	}
	if len(links) == 0 {
		return nil, fmt.Errorf("no platform links found")
	}
	return links, nil
}

func trackPlatformLinksCacheLookup(key string) (map[string]string, bool, bool) {
	trackPlatformLinksCacheMu.Lock()
	defer trackPlatformLinksCacheMu.Unlock()
	e, ok := trackPlatformLinksCache[key]
	if !ok {
		return nil, false, false
	}
	if time.Now().After(e.expiresAt) {
		delete(trackPlatformLinksCache, key)
		return nil, false, false
	}
	return cloneStringMap(e.links), true, e.err
}

func trackPlatformLinksCacheStore(key string, links map[string]string, err error) {
	ttl := trackAvailabilityCacheTTL
	if err != nil {
		ttl = trackAvailabilityNegCacheTTL
	}
	trackPlatformLinksCacheMu.Lock()
	defer trackPlatformLinksCacheMu.Unlock()
	if _, exists := trackPlatformLinksCache[key]; !exists && len(trackPlatformLinksCache) >= trackPlatformLinksCacheMax {
		var oldestKey string
		var oldest time.Time
		first := true
		for k, e := range trackPlatformLinksCache {
			if first || e.expiresAt.Before(oldest) {
				oldest, oldestKey, first = e.expiresAt, k, false
			}
		}
		delete(trackPlatformLinksCache, oldestKey)
	}
	trackPlatformLinksCache[key] = trackPlatformLinksCacheEntry{
		links:     cloneStringMap(links),
		err:       err != nil,
		expiresAt: time.Now().Add(ttl),
	}
}

func cloneStringMap(m map[string]string) map[string]string {
	if m == nil {
		return nil
	}
	c := make(map[string]string, len(m))
	for k, v := range m {
		c[k] = v
	}
	return c
}

func cloneTrackAvailability(a *TrackAvailability) *TrackAvailability {
	if a == nil {
		return nil
	}
	c := *a
	return &c
}

func trackAvailabilityCacheLookup(key string) (*TrackAvailability, bool, bool) {
	trackAvailabilityCacheMu.Lock()
	defer trackAvailabilityCacheMu.Unlock()
	e, ok := trackAvailabilityCache[key]
	if !ok {
		return nil, false, false
	}
	if time.Now().After(e.expiresAt) {
		delete(trackAvailabilityCache, key)
		return nil, false, false
	}
	return e.availability, true, e.err
}

func trackAvailabilityCacheStore(key string, availability *TrackAvailability, err error) {
	ttl := trackAvailabilityCacheTTL
	if err != nil {
		ttl = trackAvailabilityNegCacheTTL
	}
	trackAvailabilityCacheMu.Lock()
	defer trackAvailabilityCacheMu.Unlock()
	if _, exists := trackAvailabilityCache[key]; !exists && len(trackAvailabilityCache) >= trackAvailabilityCacheMax {
		var oldestKey string
		var oldest time.Time
		first := true
		for k, e := range trackAvailabilityCache {
			if first || e.expiresAt.Before(oldest) {
				oldest, oldestKey, first = e.expiresAt, k, false
			}
		}
		delete(trackAvailabilityCache, oldestKey)
	}
	trackAvailabilityCache[key] = trackAvailabilityCacheEntry{
		availability: availability,
		err:          err != nil,
		expiresAt:    time.Now().Add(ttl),
	}
}

func (s *SongLinkClient) checkTrackAvailabilityFromSpotify(spotifyTrackID string) (*TrackAvailability, error) {
	spotifyURL := fmt.Sprintf("https://open.spotify.com/track/%s", spotifyTrackID)
	links, err := s.resolveTrackPlatforms(spotifyURL)
	if err != nil {
		return nil, fmt.Errorf("platform resolution failed for Spotify %s: %w", spotifyTrackID, err)
	}
	return buildTrackAvailabilityFromSongLinkLinks(spotifyTrackID, links), nil
}

func (s *SongLinkClient) checkTrackAvailabilityFromISRC(isrc string) (*TrackAvailability, error) {
	ctx, cancel := context.WithTimeout(context.Background(), SongLinkTimeout)
	defer cancel()

	track, err := songLinkSearchByISRC(ctx, isrc)
	if err != nil {
		return nil, fmt.Errorf("failed to resolve Deezer track from ISRC %s: %w", isrc, err)
	}

	deezerTrackID := songLinkExtractDeezerTrackID(track)
	if deezerTrackID == "" {
		return nil, fmt.Errorf("failed to resolve Deezer track ID from ISRC %s", isrc)
	}

	availability, err := songLinkCheckAvailabilityFromDeezer(s, deezerTrackID)
	if err != nil {
		return nil, fmt.Errorf("failed to resolve SongLink availability from ISRC %s via Deezer %s: %w", isrc, deezerTrackID, err)
	}

	return availability, nil
}

func songLinkExtractDeezerTrackID(track *TrackMetadata) string {
	if track == nil {
		return ""
	}

	if deezerID, ok := strings.CutPrefix(strings.TrimSpace(track.SpotifyID), "deezer:"); ok {
		deezerID = strings.TrimSpace(deezerID)
		if deezerID != "" {
			return deezerID
		}
	}

	if deezerID := extractDeezerIDFromURL(strings.TrimSpace(track.ExternalURL)); deezerID != "" {
		return deezerID
	}

	return ""
}

func (s *SongLinkClient) GetStreamingURLs(spotifyTrackID string) (map[string]string, error) {
	availability, err := s.CheckTrackAvailability(spotifyTrackID, "")
	if err != nil {
		return nil, err
	}

	urls := make(map[string]string)
	if availability.TidalURL != "" {
		urls["tidal"] = availability.TidalURL
	}
	if availability.AmazonURL != "" {
		urls["amazon"] = availability.AmazonURL
	}

	return urls, nil
}

func extractDeezerIDFromURL(deezerURL string) string {
	parts := strings.Split(deezerURL, "/")
	if len(parts) > 0 {
		lastPart := parts[len(parts)-1]
		if idx := strings.Index(lastPart, "?"); idx > 0 {
			lastPart = lastPart[:idx]
		}
		return lastPart
	}
	return ""
}

// extractQobuzIDFromURL extracts Qobuz track ID from URL.
// URL formats:
//   - https://www.qobuz.com/us-en/album/.../12345678 (album page with track highlight)
//   - https://open.qobuz.com/track/12345678
//   - https://www.qobuz.com/track/12345678
//   - https://play.qobuz.com/track/12345678
func extractQobuzIDFromURL(qobuzURL string) string {
	if qobuzURL == "" {
		return ""
	}

	if strings.Contains(qobuzURL, "/track/") {
		parts := strings.Split(qobuzURL, "/track/")
		if len(parts) > 1 {
			idPart := parts[1]
			if idx := strings.Index(idPart, "?"); idx > 0 {
				idPart = idPart[:idx]
			}
			if idx := strings.Index(idPart, "/"); idx > 0 {
				idPart = idPart[:idx]
			}
			idPart = strings.TrimSpace(idPart)
			if idPart != "" && isNumeric(idPart) {
				return idPart
			}
		}
	}

	// Try to extract from album URL with track highlight (e.g. ?trackId=12345678)
	if strings.Contains(qobuzURL, "trackId=") {
		parts := strings.Split(qobuzURL, "trackId=")
		if len(parts) > 1 {
			idPart := parts[1]
			if idx := strings.Index(idPart, "&"); idx > 0 {
				idPart = idPart[:idx]
			}
			idPart = strings.TrimSpace(idPart)
			if idPart != "" && isNumeric(idPart) {
				return idPart
			}
		}
	}

	// Last resort: get last numeric segment from URL
	parts := strings.Split(qobuzURL, "/")
	for i := len(parts) - 1; i >= 0; i-- {
		part := parts[i]
		if idx := strings.Index(part, "?"); idx > 0 {
			part = part[:idx]
		}
		part = strings.TrimSpace(part)
		if part != "" && isNumeric(part) {
			return part
		}
	}

	return ""
}

func extractTidalIDFromURL(tidalURL string) string {
	if tidalURL == "" {
		return ""
	}

	if strings.Contains(tidalURL, "/track/") {
		parts := strings.Split(tidalURL, "/track/")
		if len(parts) > 1 {
			idPart := parts[1]
			if idx := strings.Index(idPart, "?"); idx > 0 {
				idPart = idPart[:idx]
			}
			if idx := strings.Index(idPart, "/"); idx > 0 {
				idPart = idPart[:idx]
			}
			idPart = strings.TrimSpace(idPart)
			if idPart != "" && isNumeric(idPart) {
				return idPart
			}
		}
	}

	return ""
}

func extractYouTubeIDFromURL(youtubeURL string) string {
	if youtubeURL == "" {
		return ""
	}

	if strings.Contains(youtubeURL, "youtu.be/") {
		parts := strings.Split(youtubeURL, "youtu.be/")
		if len(parts) >= 2 {
			idPart := parts[1]
			if idx := strings.Index(idPart, "?"); idx > 0 {
				idPart = idPart[:idx]
			}
			if idx := strings.Index(idPart, "&"); idx > 0 {
				idPart = idPart[:idx]
			}
			return strings.TrimSpace(idPart)
		}
	}

	parsed, err := url.Parse(youtubeURL)
	if err != nil {
		return ""
	}

	if v := parsed.Query().Get("v"); v != "" {
		return v
	}

	if strings.Contains(parsed.Path, "/embed/") {
		parts := strings.Split(parsed.Path, "/embed/")
		if len(parts) >= 2 {
			return strings.Split(parts[1], "/")[0]
		}
	}

	return ""
}

func (s *SongLinkClient) GetDeezerIDFromSpotify(spotifyTrackID string) (string, error) {
	availability, err := s.CheckTrackAvailability(spotifyTrackID, "")
	if err != nil {
		return "", err
	}

	if !availability.Deezer || availability.DeezerID == "" {
		return "", fmt.Errorf("track not found on Deezer")
	}

	return availability.DeezerID, nil
}

func (s *SongLinkClient) GetYouTubeURLFromSpotify(spotifyTrackID string) (string, error) {
	availability, err := s.CheckTrackAvailability(spotifyTrackID, "")
	if err != nil {
		return "", err
	}

	if !availability.YouTube || availability.YouTubeURL == "" {
		return "", fmt.Errorf("track not found on YouTube")
	}

	return availability.YouTubeURL, nil
}

type AlbumAvailability struct {
	SpotifyID string `json:"spotify_id"`
	Deezer    bool   `json:"deezer"`
	DeezerURL string `json:"deezer_url,omitempty"`
	DeezerID  string `json:"deezer_id,omitempty"`
}

func (s *SongLinkClient) CheckAlbumAvailability(spotifyAlbumID string) (*AlbumAvailability, error) {
	spotifyURL := fmt.Sprintf("https://open.spotify.com/album/%s", spotifyAlbumID)
	links, err := s.resolveTrackPlatforms(spotifyURL)
	if err != nil {
		return nil, fmt.Errorf("platform resolution failed for album %s: %w", spotifyAlbumID, err)
	}

	availability := &AlbumAvailability{
		SpotifyID: spotifyAlbumID,
	}

	if deezerLink, ok := links["deezer"]; ok && deezerLink.URL != "" {
		availability.Deezer = true
		availability.DeezerURL = deezerLink.URL
		availability.DeezerID = extractDeezerIDFromURL(deezerLink.URL)
	}

	return availability, nil
}

func (s *SongLinkClient) GetDeezerAlbumIDFromSpotify(spotifyAlbumID string) (string, error) {
	availability, err := s.CheckAlbumAvailability(spotifyAlbumID)
	if err != nil {
		return "", err
	}

	if !availability.Deezer || availability.DeezerID == "" {
		return "", fmt.Errorf("album not found on Deezer")
	}

	return availability.DeezerID, nil
}

// This is useful when we have Deezer metadata and want to find the track on other platforms
func (s *SongLinkClient) CheckAvailabilityFromDeezer(deezerTrackID string) (*TrackAvailability, error) {
	if deezerTrackID == "" {
		return nil, fmt.Errorf("deezer track ID is empty")
	}

	return s.checkAvailabilityFromDeezerSongLink(deezerTrackID)
}

func (s *SongLinkClient) checkAvailabilityFromDeezerSongLink(deezerTrackID string) (*TrackAvailability, error) {
	deezerURL := fmt.Sprintf("https://www.deezer.com/track/%s", deezerTrackID)
	links, err := s.resolveTrackPlatforms(deezerURL)
	if err != nil {
		return nil, fmt.Errorf("resolve failed for Deezer %s: %w", deezerTrackID, err)
	}

	availability := buildTrackAvailabilityFromSongLinkLinks("", links)
	// Ensure Deezer is always marked available since we started from a Deezer URL
	availability.Deezer = true
	availability.DeezerID = deezerTrackID
	if availability.DeezerURL == "" {
		availability.DeezerURL = deezerURL
	}
	return availability, nil
}

// platform: "spotify", "deezer", "tidal", "amazonMusic", "appleMusic", "youtube", etc.
// entityType: "song" or "album"
// entityID: the ID on that platform
func (s *SongLinkClient) CheckAvailabilityByPlatform(platform, entityType, entityID string) (*TrackAvailability, error) {
	if entityID == "" {
		return nil, fmt.Errorf("%s ID is empty", platform)
	}

	links, err := s.resolveTrackPlatformsByPlatform(platform, entityType, entityID)
	if err != nil {
		return nil, fmt.Errorf("resolve failed for %s %s: %w", platform, entityID, err)
	}

	return buildTrackAvailabilityFromSongLinkLinks("", links), nil
}

func buildTrackAvailabilityFromSongLinkLinks(spotifyTrackID string, links map[string]songLinkPlatformLink) *TrackAvailability {
	availability := &TrackAvailability{
		SpotifyID: spotifyTrackID,
	}

	if availability.SpotifyID == "" {
		if spotifyLink, ok := links["spotify"]; ok && spotifyLink.URL != "" {
			availability.SpotifyID = extractSpotifyIDFromURL(spotifyLink.URL)
		}
	}
	if tidalLink, ok := links["tidal"]; ok && tidalLink.URL != "" {
		availability.Tidal = true
		availability.TidalURL = tidalLink.URL
		availability.TidalID = extractTidalIDFromURL(tidalLink.URL)
	}
	if amazonLink, ok := links["amazonMusic"]; ok && amazonLink.URL != "" {
		availability.Amazon = true
		availability.AmazonURL = amazonLink.URL
	}
	if qobuzLink, ok := links["qobuz"]; ok && qobuzLink.URL != "" {
		availability.Qobuz = true
		availability.QobuzURL = qobuzLink.URL
		availability.QobuzID = extractQobuzIDFromURL(qobuzLink.URL)
	}
	if deezerLink, ok := links["deezer"]; ok && deezerLink.URL != "" {
		availability.Deezer = true
		availability.DeezerURL = deezerLink.URL
		availability.DeezerID = extractDeezerIDFromURL(deezerLink.URL)
	}
	if ytMusicLink, ok := links["youtubeMusic"]; ok && ytMusicLink.URL != "" {
		availability.YouTube = true
		availability.YouTubeURL = ytMusicLink.URL
		availability.YouTubeID = extractYouTubeIDFromURL(ytMusicLink.URL)
	}
	if !availability.YouTube {
		if youtubeLink, ok := links["youtube"]; ok && youtubeLink.URL != "" {
			availability.YouTube = true
			availability.YouTubeURL = youtubeLink.URL
			availability.YouTubeID = extractYouTubeIDFromURL(youtubeLink.URL)
		}
	}

	return availability
}

func extractSpotifyIDFromURL(spotifyURL string) string {
	parts := strings.Split(spotifyURL, "/track/")
	if len(parts) > 1 {
		idPart := parts[1]
		if idx := strings.Index(idPart, "?"); idx > 0 {
			idPart = idPart[:idx]
		}
		return idPart
	}
	return ""
}

func (s *SongLinkClient) GetSpotifyIDFromDeezer(deezerTrackID string) (string, error) {
	availability, err := s.CheckAvailabilityFromDeezer(deezerTrackID)
	if err != nil {
		return "", err
	}

	if availability.SpotifyID == "" {
		return "", fmt.Errorf("track not found on Spotify")
	}

	return availability.SpotifyID, nil
}

func (s *SongLinkClient) GetTidalURLFromDeezer(deezerTrackID string) (string, error) {
	availability, err := s.CheckAvailabilityFromDeezer(deezerTrackID)
	if err != nil {
		return "", err
	}

	if !availability.Tidal || availability.TidalURL == "" {
		return "", fmt.Errorf("track not found on Tidal")
	}

	return availability.TidalURL, nil
}

func (s *SongLinkClient) GetAmazonURLFromDeezer(deezerTrackID string) (string, error) {
	availability, err := s.CheckAvailabilityFromDeezer(deezerTrackID)
	if err != nil {
		return "", err
	}

	if !availability.Amazon || availability.AmazonURL == "" {
		return "", fmt.Errorf("track not found on Amazon Music")
	}

	return availability.AmazonURL, nil
}

func (s *SongLinkClient) GetYouTubeURLFromDeezer(deezerTrackID string) (string, error) {
	availability, err := s.CheckAvailabilityFromDeezer(deezerTrackID)
	if err != nil {
		return "", err
	}

	if !availability.YouTube || availability.YouTubeURL == "" {
		return "", fmt.Errorf("track not found on YouTube")
	}

	return availability.YouTubeURL, nil
}

func (s *SongLinkClient) CheckAvailabilityFromURL(inputURL string) (*TrackAvailability, error) {
	links, err := s.resolveTrackPlatforms(inputURL)
	if err != nil {
		return nil, fmt.Errorf("resolve failed for URL %s: %w", inputURL, err)
	}

	return buildTrackAvailabilityFromSongLinkLinks("", links), nil
}
