package gobackend

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const maxKugouLyricsResponseBytes = 2 << 20

type KugouLyricsClient struct {
	httpClient *http.Client
}

type kugouLyricsSearchResult struct {
	ID        string  `json:"id"`
	AccessKey string  `json:"accesskey"`
	Title     string  `json:"song"`
	Artist    string  `json:"singer"`
	Duration  float64 `json:"duration"`
}

type kugouLyricsSearchResponse struct {
	Status     int                       `json:"status"`
	ErrorCode  int                       `json:"errcode"`
	Error      string                    `json:"errmsg"`
	Candidates []kugouLyricsSearchResult `json:"candidates"`
}

type kugouLyricsDownloadResponse struct {
	Status    int    `json:"status"`
	ErrorCode int    `json:"error_code"`
	Info      string `json:"info"`
	Content   string `json:"content"`
}

func NewKugouLyricsClient() *KugouLyricsClient {
	return &KugouLyricsClient{httpClient: NewMetadataHTTPClient(15 * time.Second)}
}

func fetchKugouLyricsBody(httpClient *http.Client, endpoint string, params url.Values) ([]byte, error) {
	req, err := http.NewRequest(http.MethodGet, endpoint+"?"+params.Encode(), nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", appUserAgent())

	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, lyricsServiceUnavailableErrorf("HTTP %d", resp.StatusCode)
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, maxKugouLyricsResponseBytes+1))
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}
	if len(body) > maxKugouLyricsResponseBytes {
		return nil, lyricsServiceUnavailableErrorf(
			"response exceeds %d bytes",
			maxKugouLyricsResponseBytes,
		)
	}
	if strings.TrimSpace(string(body)) == "" {
		return nil, lyricsServiceUnavailableErrorf("empty response")
	}
	return body, nil
}

func (c *KugouLyricsClient) searchSong(
	trackName,
	artistName string,
	durationSec float64,
) (*kugouLyricsSearchResult, error) {
	query := strings.TrimSpace(artistName + " - " + trackName)
	if query == "" {
		return nil, lyricsNotFoundErrorf("empty search query")
	}

	params := url.Values{
		"ver":      {"1"},
		"man":      {"yes"},
		"client":   {"pc"},
		"keyword":  {query},
		"duration": {strconv.FormatInt(int64(math.Round(durationSec*1000)), 10)},
		"hash":     {""},
	}
	raw, err := fetchKugouLyricsBody(
		c.httpClient,
		"https://lyrics.kugou.com/search",
		params,
	)
	if err != nil {
		return nil, fmt.Errorf("kugou search failed: %w", err)
	}

	var response kugouLyricsSearchResponse
	if err := json.Unmarshal(raw, &response); err != nil {
		return nil, fmt.Errorf("failed to decode kugou search: %w", err)
	}
	// KuGou uses errcode=200 for a successful search response, while some
	// mirrors omit the field (or return zero). Treat both success forms as
	// valid and only reject explicit non-success codes.
	if response.Status != http.StatusOK ||
		(response.ErrorCode != 0 && response.ErrorCode != http.StatusOK) {
		message := strings.TrimSpace(response.Error)
		if message == "" {
			message = fmt.Sprintf(
				"status %d/error %d",
				response.Status,
				response.ErrorCode,
			)
		}
		return nil, lyricsServiceUnavailableErrorf("%s", message)
	}

	best := selectBestKugouLyricsSearchResult(
		response.Candidates,
		trackName,
		artistName,
		durationSec,
	)
	if best == nil ||
		strings.TrimSpace(best.ID) == "" ||
		strings.TrimSpace(best.AccessKey) == "" {
		return nil, lyricsNotFoundErrorf("no matching song found on kugou")
	}
	return best, nil
}

func selectBestKugouLyricsSearchResult(
	results []kugouLyricsSearchResult,
	trackName,
	artistName string,
	durationSec float64,
) *kugouLyricsSearchResult {
	best := selectBestLyricsCandidate(
		len(results),
		trackName,
		artistName,
		durationSec,
		func(i int) (string, string, float64, bool) {
			result := &results[i]
			durationSeconds := result.Duration / 1000
			matches := lyricsSearchTitlesMatch(result.Title, trackName, false) &&
				lyricsSearchArtistsMatch(result.Artist, artistName) &&
				lyricsSearchDurationMatches(durationSeconds, durationSec)
			return result.Title, result.Artist, durationSeconds, matches
		},
	)
	if best < 0 {
		return nil
	}
	return &results[best]
}

func (c *KugouLyricsClient) FetchLyrics(
	trackName,
	artistName string,
	durationSec float64,
) (*LyricsResponse, error) {
	match, err := c.searchSong(trackName, artistName, durationSec)
	if err != nil {
		return nil, err
	}

	params := url.Values{
		"ver":       {"1"},
		"client":    {"pc"},
		"id":        {match.ID},
		"accesskey": {match.AccessKey},
		"fmt":       {"lrc"},
		"charset":   {"utf8"},
	}
	raw, err := fetchKugouLyricsBody(
		c.httpClient,
		"https://lyrics.kugou.com/download",
		params,
	)
	if err != nil {
		return nil, fmt.Errorf("kugou lyrics fetch failed: %w", err)
	}

	var response kugouLyricsDownloadResponse
	if err := json.Unmarshal(raw, &response); err != nil {
		return nil, fmt.Errorf("failed to decode kugou lyrics: %w", err)
	}
	if response.Status != http.StatusOK || response.ErrorCode != 0 {
		message := strings.TrimSpace(response.Info)
		if message == "" {
			message = fmt.Sprintf(
				"status %d/error %d",
				response.Status,
				response.ErrorCode,
			)
		}
		return nil, lyricsServiceUnavailableErrorf("%s", message)
	}

	decoded, err := base64.StdEncoding.DecodeString(response.Content)
	if err != nil {
		return nil, lyricsServiceUnavailableErrorf(
			"invalid base64 lyrics: %v",
			err,
		)
	}
	lyrics := lyricsResponseFromLRCText(
		string(decoded),
		"Kugou",
		"Kugou Direct",
	)
	if !lyricsHasUsableText(lyrics) {
		return nil, lyricsNotFoundErrorf("kugou returned empty lyrics")
	}
	return lyrics, nil
}
