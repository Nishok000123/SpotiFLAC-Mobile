package gobackend

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"golang.org/x/net/html"
)

const (
	resolverFallbackTimeout = 12 * time.Second
	resolverResponseLimit   = 2 << 20
	squiglyPageLimit        = 8 << 20
)

type resolverMetadata struct {
	Title  string
	Artist string
}

type resolverResult struct {
	Links    map[string]songLinkPlatformLink
	Metadata resolverMetadata
}

type platformFallbackResolver interface {
	Resolve(context.Context, string, resolverMetadata) (resolverResult, error)
}

type platformResolverChain struct {
	songLinkWeb platformFallbackResolver
	unitune     platformFallbackResolver
	musicBrainz platformFallbackResolver
	squigly     platformFallbackResolver
}

var defaultPlatformResolverFallbacks platformFallbackResolver = &platformResolverChain{
	songLinkWeb: &songLinkWebResolver{
		client:      NewMetadataHTTPClient(6 * time.Second),
		rateLimiter: NewRateLimiter(20, time.Minute),
	},
	unitune: &unituneResolver{
		client:      NewMetadataHTTPClient(6 * time.Second),
		rateLimiter: NewRateLimiter(30, time.Minute),
	},
	musicBrainz: &musicBrainzPlatformResolver{
		client:      NewMetadataHTTPClient(6 * time.Second),
		rateLimiter: NewRateLimiter(1, time.Second),
	},
	squigly: &squiglyResolver{
		client:      NewMetadataHTTPClient(6 * time.Second),
		rateLimiter: NewRateLimiter(18, time.Minute),
	},
}

func (c *platformResolverChain) Resolve(
	ctx context.Context,
	inputURL string,
	hint resolverMetadata,
) (resolverResult, error) {
	result := resolverResult{Links: make(map[string]songLinkPlatformLink), Metadata: hint}
	var resolverErrors []error

	resolvers := []struct {
		name     string
		resolver platformFallbackResolver
	}{
		{name: "Song.link Web", resolver: c.songLinkWeb},
		{name: "UniTune", resolver: c.unitune},
		{name: "MusicBrainz", resolver: c.musicBrainz},
		{name: "Squigly", resolver: c.squigly},
	}

	for _, candidate := range resolvers {
		if candidate.resolver == nil {
			continue
		}
		resolved, err := candidate.resolver.Resolve(ctx, inputURL, result.Metadata)
		if err != nil {
			resolverErrors = append(resolverErrors, fmt.Errorf("%s: %w", candidate.name, err))
			LogDebug("PlatformResolver", "%s resolver failed: %v", candidate.name, err)
			continue
		}

		mergeResolverLinks(result.Links, resolved.Links)
		if result.Metadata.Title == "" {
			result.Metadata.Title = strings.TrimSpace(resolved.Metadata.Title)
		}
		if result.Metadata.Artist == "" {
			result.Metadata.Artist = strings.TrimSpace(resolved.Metadata.Artist)
		}
		LogInfo("PlatformResolver", "%s contributed %d direct platform links", candidate.name, len(resolved.Links))

		if hasUsefulResolverCoverage(result.Links) {
			break
		}
	}

	addResolverSourceLink(result.Links, inputURL)
	if len(result.Links) > 0 {
		return result, nil
	}
	if len(resolverErrors) == 0 {
		return resolverResult{}, fmt.Errorf("no additional resolver was available")
	}
	return resolverResult{}, errors.Join(resolverErrors...)
}

type songLinkWebResolver struct {
	client      *http.Client
	rateLimiter *RateLimiter
}

func (r *songLinkWebResolver) Resolve(
	ctx context.Context,
	inputURL string,
	_ resolverMetadata,
) (resolverResult, error) {
	platform := resolverPlatformFromURL(inputURL)
	if directResolverURL(platform, inputURL) == "" {
		return resolverResult{}, fmt.Errorf("unsupported source URL")
	}
	if err := r.rateLimiter.WaitForSlotContext(ctx); err != nil {
		return resolverResult{}, err
	}

	endpoint := "https://song.link/" + url.PathEscape(inputURL)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return resolverResult{}, err
	}
	req.Header.Set("Accept", "text/html,application/xhtml+xml")
	req.Header.Set("User-Agent", getRandomUserAgent())
	resp, err := r.client.Do(req)
	if err != nil {
		return resolverResult{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return resolverResult{}, fmt.Errorf("web page returned status %d", resp.StatusCode)
	}
	if resp.Request == nil || resp.Request.URL == nil || !isSongLinkLandingHost(resp.Request.URL.Hostname()) {
		return resolverResult{}, fmt.Errorf("web page redirected to an unexpected host")
	}

	body, err := readResolverResponse(resp, squiglyPageLimit)
	if err != nil {
		return resolverResult{}, err
	}
	document, err := html.Parse(bytes.NewReader(body))
	if err != nil {
		return resolverResult{}, fmt.Errorf("failed to parse web page: %w", err)
	}

	result := resolverResult{Links: make(map[string]songLinkPlatformLink)}
	var visit func(*html.Node)
	visit = func(node *html.Node) {
		if node.Type == html.ElementNode && node.Data == "a" {
			for _, attr := range node.Attr {
				if attr.Key != "href" {
					continue
				}
				platform := resolverPlatformFromURL(attr.Val)
				if _, exists := result.Links[platform]; exists {
					break
				}
				if directURL := directResolverURL(platform, attr.Val); directURL != "" {
					result.Links[platform] = songLinkPlatformLink{URL: directURL}
				}
				break
			}
		}
		for child := node.FirstChild; child != nil; child = child.NextSibling {
			visit(child)
		}
	}
	visit(document)
	addResolverSourceLink(result.Links, inputURL)
	if len(result.Links) < 2 {
		return resolverResult{}, fmt.Errorf("web page returned no cross-platform links")
	}
	return result, nil
}

func isSongLinkLandingHost(host string) bool {
	host = strings.ToLower(strings.TrimSpace(host))
	switch host {
	case "song.link", "album.link", "artist.link", "odesli.co", "www.odesli.co":
		return true
	default:
		return false
	}
}

func mergeResolverLinks(dst, src map[string]songLinkPlatformLink) {
	for platform, link := range src {
		if _, exists := dst[platform]; exists {
			continue
		}
		if directURL := directResolverURL(platform, link.URL); directURL != "" {
			dst[platform] = songLinkPlatformLink{URL: directURL}
		}
	}
}

func hasUsefulResolverCoverage(links map[string]songLinkPlatformLink) bool {
	if len(links) < 4 {
		return false
	}
	downloadProviders := 0
	for _, platform := range []string{"deezer", "tidal", "amazonMusic", "qobuz"} {
		if link, ok := links[platform]; ok && link.URL != "" {
			downloadProviders++
		}
	}
	return downloadProviders >= 2
}

func canonicalResolverPlatform(platform string) string {
	normalized := strings.ToLower(strings.NewReplacer("-", "", "_", "", " ", "").Replace(strings.TrimSpace(platform)))
	switch normalized {
	case "spotify", "deezer", "tidal", "qobuz", "soundcloud", "bandcamp":
		return normalized
	case "apple", "applemusic":
		return "appleMusic"
	case "amazon", "amazonmusic":
		return "amazonMusic"
	case "youtube":
		return "youtube"
	case "youtubemusic":
		return "youtubeMusic"
	default:
		return ""
	}
}

func resolverURLFromPlatformID(platform, entityType, entityID string) (string, error) {
	platform = canonicalResolverPlatform(platform)
	entityID = strings.TrimSpace(entityID)
	if platform == "" || entityID == "" {
		return "", fmt.Errorf("invalid platform or entity ID")
	}

	entityType = strings.ToLower(strings.TrimSpace(entityType))
	if entityType == "song" {
		entityType = "track"
	}
	if entityType != "track" && entityType != "album" && entityType != "artist" {
		return "", fmt.Errorf("unsupported entity type %q", entityType)
	}

	id := url.PathEscape(entityID)
	switch platform {
	case "spotify":
		return fmt.Sprintf("https://open.spotify.com/%s/%s", entityType, id), nil
	case "deezer":
		return fmt.Sprintf("https://www.deezer.com/%s/%s", entityType, id), nil
	case "tidal":
		return fmt.Sprintf("https://tidal.com/browse/%s/%s", entityType, id), nil
	case "qobuz":
		return fmt.Sprintf("https://open.qobuz.com/%s/%s", entityType, id), nil
	case "amazonMusic":
		return fmt.Sprintf("https://music.amazon.com/%ss/%s", entityType, id), nil
	case "youtube", "youtubeMusic":
		if entityType != "track" {
			return "", fmt.Errorf("unsupported %s entity type %q", platform, entityType)
		}
		host := "www.youtube.com"
		if platform == "youtubeMusic" {
			host = "music.youtube.com"
		}
		return fmt.Sprintf("https://%s/watch?v=%s", host, url.QueryEscape(entityID)), nil
	default:
		return "", fmt.Errorf("cannot build a direct %s URL from an ID", platform)
	}
}

func directResolverURL(platform, value string) string {
	platform = canonicalResolverPlatform(platform)
	if platform == "" {
		return ""
	}
	parsed, err := url.Parse(strings.TrimSpace(value))
	if err != nil || parsed.Scheme != "https" || parsed.Hostname() == "" {
		return ""
	}

	host := strings.ToLower(parsed.Hostname())
	if strings.Contains(strings.ToLower(parsed.EscapedPath()), "/search") {
		return ""
	}

	hostAllowed := false
	switch platform {
	case "spotify":
		hostAllowed = host == "open.spotify.com"
	case "deezer":
		hostAllowed = host == "deezer.com" || host == "www.deezer.com"
	case "tidal":
		hostAllowed = host == "tidal.com" || host == "www.tidal.com" || host == "listen.tidal.com"
	case "qobuz":
		hostAllowed = host == "open.qobuz.com" || host == "play.qobuz.com" || host == "www.qobuz.com"
	case "appleMusic":
		hostAllowed = host == "music.apple.com" || host == "geo.music.apple.com"
	case "amazonMusic":
		hostAllowed = host == "music.amazon.com"
	case "youtubeMusic":
		hostAllowed = host == "music.youtube.com"
	case "youtube":
		hostAllowed = host == "youtube.com" || host == "www.youtube.com" || host == "youtu.be"
	case "soundcloud":
		hostAllowed = host == "soundcloud.com" || host == "www.soundcloud.com" || host == "m.soundcloud.com"
	case "bandcamp":
		hostAllowed = host == "bandcamp.com" || strings.HasSuffix(host, ".bandcamp.com")
	}
	if !hostAllowed {
		return ""
	}
	return parsed.String()
}

func addResolverSourceLink(links map[string]songLinkPlatformLink, inputURL string) {
	platform := resolverPlatformFromURL(inputURL)
	if platform == "" {
		return
	}
	if directURL := directResolverURL(platform, inputURL); directURL != "" {
		if _, exists := links[platform]; !exists {
			links[platform] = songLinkPlatformLink{URL: directURL}
		}
	}
}

func readResolverResponse(resp *http.Response, limit int64) ([]byte, error) {
	if resp == nil || resp.Body == nil {
		return nil, fmt.Errorf("response is empty")
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(body)) > limit {
		return nil, fmt.Errorf("response exceeds %d bytes", limit)
	}
	if len(body) == 0 {
		return nil, fmt.Errorf("response body is empty")
	}
	return body, nil
}

type unituneResolver struct {
	client      *http.Client
	rateLimiter *RateLimiter
}

func (r *unituneResolver) Resolve(ctx context.Context, inputURL string, _ resolverMetadata) (resolverResult, error) {
	if err := r.rateLimiter.WaitForSlotContext(ctx); err != nil {
		return resolverResult{}, err
	}
	endpoint := "https://api.unitune.art/v1-alpha.1/links?url=" + url.QueryEscape(inputURL)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return resolverResult{}, err
	}
	req.Header.Set("User-Agent", getRandomUserAgent())
	resp, err := r.client.Do(req)
	if err != nil {
		return resolverResult{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return resolverResult{}, fmt.Errorf("API returned status %d", resp.StatusCode)
	}
	body, err := readResolverResponse(resp, resolverResponseLimit)
	if err != nil {
		return resolverResult{}, err
	}

	var payload struct {
		EntityUniqueID string                          `json:"entityUniqueId"`
		Links          map[string]songLinkPlatformLink `json:"linksByPlatform"`
		Entities       map[string]struct {
			Title      string `json:"title"`
			ArtistName string `json:"artistName"`
		} `json:"entitiesByUniqueId"`
	}
	if err := json.Unmarshal(body, &payload); err != nil {
		return resolverResult{}, err
	}

	result := resolverResult{Links: make(map[string]songLinkPlatformLink)}
	for platform, link := range payload.Links {
		canonical := canonicalResolverPlatform(platform)
		if directURL := directResolverURL(canonical, link.URL); directURL != "" {
			result.Links[canonical] = songLinkPlatformLink{URL: directURL}
		}
	}
	if entity, ok := payload.Entities[payload.EntityUniqueID]; ok {
		result.Metadata = resolverMetadata{Title: entity.Title, Artist: entity.ArtistName}
	} else {
		for _, entity := range payload.Entities {
			result.Metadata = resolverMetadata{Title: entity.Title, Artist: entity.ArtistName}
			break
		}
	}
	if len(result.Links) == 0 && result.Metadata.Title == "" {
		return resolverResult{}, fmt.Errorf("API returned no direct platform links or metadata")
	}
	return result, nil
}

type musicBrainzPlatformResolver struct {
	client      *http.Client
	rateLimiter *RateLimiter
}

func (r *musicBrainzPlatformResolver) Resolve(
	ctx context.Context,
	_ string,
	hint resolverMetadata,
) (resolverResult, error) {
	title := strings.TrimSpace(hint.Title)
	artist := strings.TrimSpace(hint.Artist)
	if title == "" || artist == "" {
		return resolverResult{}, fmt.Errorf("title and artist metadata are required")
	}

	query := fmt.Sprintf("recording:\"%s\" AND artist:\"%s\"", escapeMusicBrainzQuery(title), escapeMusicBrainzQuery(artist))
	searchURL := musicBrainzAPIBase + "/recording?fmt=json&limit=5&query=" + url.QueryEscape(query)
	var search struct {
		Recordings []struct {
			ID           string `json:"id"`
			Score        int    `json:"score"`
			Title        string `json:"title"`
			ArtistCredit []struct {
				Name string `json:"name"`
			} `json:"artist-credit"`
		} `json:"recordings"`
	}
	if err := r.getJSON(ctx, searchURL, &search); err != nil {
		return resolverResult{}, err
	}

	var recordingID string
	for _, candidate := range search.Recordings {
		candidateArtist := ""
		if len(candidate.ArtistCredit) > 0 {
			candidateArtist = candidate.ArtistCredit[0].Name
		}
		if candidate.Score < 90 || normalizeLooseTitle(candidate.Title) != normalizeLooseTitle(title) || !artistsMatch(artist, candidateArtist) {
			continue
		}
		recordingID = candidate.ID
		break
	}
	if recordingID == "" {
		return resolverResult{}, fmt.Errorf("no verified recording match")
	}

	lookupURL := fmt.Sprintf("%s/recording/%s?fmt=json&inc=url-rels+isrcs", musicBrainzAPIBase, url.PathEscape(recordingID))
	var recording struct {
		Relations []struct {
			URL struct {
				Resource string `json:"resource"`
			} `json:"url"`
		} `json:"relations"`
	}
	if err := r.getJSON(ctx, lookupURL, &recording); err != nil {
		return resolverResult{}, err
	}

	result := resolverResult{Links: make(map[string]songLinkPlatformLink), Metadata: hint}
	for _, relation := range recording.Relations {
		platform := resolverPlatformFromURL(relation.URL.Resource)
		if directURL := directResolverURL(platform, relation.URL.Resource); directURL != "" {
			if _, exists := result.Links[platform]; !exists {
				result.Links[platform] = songLinkPlatformLink{URL: directURL}
			}
		}
	}
	if len(result.Links) == 0 {
		return resolverResult{}, fmt.Errorf("recording has no supported platform relations")
	}
	return result, nil
}

func (r *musicBrainzPlatformResolver) getJSON(ctx context.Context, endpoint string, payload any) error {
	if err := r.rateLimiter.WaitForSlotContext(ctx); err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", getRandomUserAgent())
	resp, err := r.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("API returned status %d", resp.StatusCode)
	}
	body, err := readResolverResponse(resp, resolverResponseLimit)
	if err != nil {
		return err
	}
	return json.Unmarshal(body, payload)
}

func escapeMusicBrainzQuery(value string) string {
	value = strings.ReplaceAll(value, `\`, `\\`)
	return strings.ReplaceAll(value, `"`, `\"`)
}

func resolverPlatformFromURL(value string) string {
	parsed, err := url.Parse(strings.TrimSpace(value))
	if err != nil {
		return ""
	}
	host := strings.ToLower(parsed.Hostname())
	switch {
	case host == "open.spotify.com":
		return "spotify"
	case host == "deezer.com" || host == "www.deezer.com":
		return "deezer"
	case host == "tidal.com" || host == "www.tidal.com" || host == "listen.tidal.com":
		return "tidal"
	case host == "music.apple.com" || host == "geo.music.apple.com":
		return "appleMusic"
	case host == "music.amazon.com":
		return "amazonMusic"
	case host == "music.youtube.com":
		return "youtubeMusic"
	case host == "youtube.com" || host == "www.youtube.com" || host == "youtu.be":
		return "youtube"
	case host == "soundcloud.com" || host == "www.soundcloud.com" || host == "m.soundcloud.com":
		return "soundcloud"
	case host == "open.qobuz.com" || host == "play.qobuz.com" || host == "www.qobuz.com":
		return "qobuz"
	case host == "bandcamp.com" || strings.HasSuffix(host, ".bandcamp.com"):
		return "bandcamp"
	default:
		return ""
	}
}

type squiglyResolver struct {
	client      *http.Client
	rateLimiter *RateLimiter
}

func (r *squiglyResolver) Resolve(ctx context.Context, inputURL string, _ resolverMetadata) (resolverResult, error) {
	if err := r.rateLimiter.WaitForSlotContext(ctx); err != nil {
		return resolverResult{}, err
	}
	requestBody, err := json.Marshal(map[string]string{"url": inputURL})
	if err != nil {
		return resolverResult{}, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://squigly.link/api/create", bytes.NewReader(requestBody))
	if err != nil {
		return resolverResult{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", getRandomUserAgent())
	resp, err := r.client.Do(req)
	if err != nil {
		return resolverResult{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusOK {
		return resolverResult{}, fmt.Errorf("create endpoint returned status %d", resp.StatusCode)
	}
	body, err := readResolverResponse(resp, resolverResponseLimit)
	if err != nil {
		return resolverResult{}, err
	}
	var created struct {
		FullURL string `json:"full_url"`
		Title   string `json:"title"`
		Artist  string `json:"artist"`
	}
	if err := json.Unmarshal(body, &created); err != nil {
		return resolverResult{}, err
	}
	parsedPageURL, err := url.Parse(strings.TrimSpace(created.FullURL))
	if err != nil || parsedPageURL.Scheme != "https" || parsedPageURL.Hostname() != "squigly.link" {
		return resolverResult{}, fmt.Errorf("create endpoint returned an invalid page URL")
	}

	pageReq, err := http.NewRequestWithContext(ctx, http.MethodGet, parsedPageURL.String(), nil)
	if err != nil {
		return resolverResult{}, err
	}
	pageReq.Header.Set("User-Agent", getRandomUserAgent())
	pageResp, err := r.client.Do(pageReq)
	if err != nil {
		return resolverResult{}, err
	}
	defer pageResp.Body.Close()
	if pageResp.StatusCode != http.StatusOK {
		return resolverResult{}, fmt.Errorf("result page returned status %d", pageResp.StatusCode)
	}
	pageBody, err := readResolverResponse(pageResp, squiglyPageLimit)
	if err != nil {
		return resolverResult{}, err
	}

	const marker = "window.__SQUIGLY_LINK__ ="
	markerIndex := bytes.Index(pageBody, []byte(marker))
	if markerIndex < 0 {
		return resolverResult{}, fmt.Errorf("result page contains no resolver payload")
	}
	decoder := json.NewDecoder(bytes.NewReader(pageBody[markerIndex+len(marker):]))
	var embedded struct {
		Data struct {
			Title    string `json:"title"`
			Artist   string `json:"artist"`
			Services map[string]*struct {
				URL string `json:"url"`
			} `json:"services"`
		} `json:"data"`
	}
	if err := decoder.Decode(&embedded); err != nil {
		return resolverResult{}, fmt.Errorf("failed to decode result page: %w", err)
	}

	result := resolverResult{
		Links: make(map[string]songLinkPlatformLink),
		Metadata: resolverMetadata{
			Title:  embedded.Data.Title,
			Artist: embedded.Data.Artist,
		},
	}
	if result.Metadata.Title == "" {
		result.Metadata.Title = created.Title
	}
	if result.Metadata.Artist == "" {
		result.Metadata.Artist = created.Artist
	}
	for platform, service := range embedded.Data.Services {
		if service == nil {
			continue
		}
		canonical := canonicalResolverPlatform(platform)
		if directURL := directResolverURL(canonical, service.URL); directURL != "" {
			result.Links[canonical] = songLinkPlatformLink{URL: directURL}
		}
	}
	if len(result.Links) == 0 {
		return resolverResult{}, fmt.Errorf("result page returned no direct platform links")
	}
	return result, nil
}
