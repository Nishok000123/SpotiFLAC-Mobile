package gobackend

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const (
	qqMusicSearchURL       = "https://c.y.qq.com/soso/fcgi-bin/client_search_cp"
	qqMusicLyricsURL       = "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg"
	maxQQMusicResponseSize = 2 << 20
)

// QQMusicClient fetches line-synchronised lyrics from QQ Music's public web
// endpoints. Word-level timing remains available through lyrics extensions.
type QQMusicClient struct {
	httpClient *http.Client
}

type qqMusicSearchResult struct {
	Mid      string `json:"mid"`
	ID       int64  `json:"id"`
	Name     string `json:"name"`
	Interval int    `json:"interval"`
	Singer   []struct {
		Name string `json:"name"`
	} `json:"singer"`
}

type qqMusicSearchResponse struct {
	Code int `json:"code"`
	Data struct {
		Song struct {
			List []qqMusicSearchResult `json:"list"`
		} `json:"song"`
	} `json:"data"`
}

type qqMusicLyricsResponse struct {
	RetCode int    `json:"retcode"`
	Code    int    `json:"code"`
	Lyric   string `json:"lyric"`
}

func NewQQMusicClient() *QQMusicClient {
	return &QQMusicClient{httpClient: NewMetadataHTTPClient(15 * time.Second)}
}

func fetchQQMusicBody(client *http.Client, endpoint string, params url.Values) ([]byte, error) {
	req, err := http.NewRequest(http.MethodGet, endpoint+"?"+params.Encode(), nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create QQ Music request: %w", err)
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Referer", "https://y.qq.com/")
	req.Header.Set("User-Agent", getRandomUserAgent())

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, lyricsServiceUnavailableErrorf("QQ Music returned HTTP %d", resp.StatusCode)
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, maxQQMusicResponseSize+1))
	if err != nil {
		return nil, fmt.Errorf("failed to read QQ Music response: %w", err)
	}
	if len(body) > maxQQMusicResponseSize {
		return nil, lyricsServiceUnavailableErrorf("QQ Music response exceeds %d bytes", maxQQMusicResponseSize)
	}
	if len(strings.TrimSpace(string(body))) == 0 {
		return nil, lyricsServiceUnavailableErrorf("QQ Music returned an empty response")
	}
	return body, nil
}

func (c *QQMusicClient) searchSong(trackName, artistName string, durationSec float64) (*qqMusicSearchResult, error) {
	query := strings.TrimSpace(trackName + " " + artistName)
	if query == "" {
		return nil, lyricsNotFoundErrorf("empty search query")
	}

	params := url.Values{
		"format": {"json"}, "inCharset": {"utf8"}, "outCharset": {"utf8"},
		"platform": {"yqq.json"}, "new_json": {"1"}, "w": {query},
		"p": {"1"}, "n": {"20"}, "t": {"0"}, "aggr": {"1"},
		"cr": {"1"}, "catZhida": {"1"}, "lossless": {"1"},
		"flag_qc": {"0"}, "remoteplace": {"txt.yqq.center"}, "needNewCode": {"0"},
	}
	raw, err := fetchQQMusicBody(c.httpClient, qqMusicSearchURL, params)
	if err != nil {
		return nil, fmt.Errorf("QQ Music search failed: %w", err)
	}
	var response qqMusicSearchResponse
	if err := json.Unmarshal(raw, &response); err != nil {
		return nil, fmt.Errorf("failed to decode QQ Music search: %w", err)
	}
	if response.Code != 0 {
		return nil, lyricsServiceUnavailableErrorf("QQ Music search returned code %d", response.Code)
	}
	best := selectBestQQMusicSearchResult(response.Data.Song.List, trackName, artistName, durationSec)
	if best == nil || strings.TrimSpace(best.Mid) == "" {
		return nil, lyricsNotFoundErrorf("no matching song found on QQ Music")
	}
	return best, nil
}

func selectBestQQMusicSearchResult(results []qqMusicSearchResult, trackName, artistName string, durationSec float64) *qqMusicSearchResult {
	best := selectBestLyricsCandidate(len(results), trackName, artistName, durationSec, func(i int) (string, string, float64, bool) {
		result := &results[i]
		artists := make([]string, 0, len(result.Singer))
		for _, singer := range result.Singer {
			if name := strings.TrimSpace(singer.Name); name != "" {
				artists = append(artists, name)
			}
		}
		candidateArtist := strings.Join(artists, ", ")
		duration := float64(result.Interval)
		matches := lyricsSearchTitlesMatch(result.Name, trackName, false) &&
			lyricsSearchArtistsMatch(candidateArtist, artistName) &&
			lyricsSearchDurationMatches(duration, durationSec)
		return result.Name, candidateArtist, duration, matches
	})
	if best < 0 {
		return nil
	}
	return &results[best]
}

func decodeQQMusicLyric(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", lyricsNotFoundErrorf("QQ Music returned empty lyrics")
	}
	if strings.HasPrefix(raw, "[") {
		return raw, nil
	}
	decoded, err := base64.StdEncoding.DecodeString(raw)
	if err != nil {
		if decoded, rawErr := base64.RawStdEncoding.DecodeString(raw); rawErr == nil {
			return string(decoded), nil
		}
		return "", lyricsServiceUnavailableErrorf("invalid QQ Music lyrics encoding")
	}
	return string(decoded), nil
}

func (c *QQMusicClient) FetchLyrics(trackName, artistName string, durationSec float64, _ bool) (*LyricsResponse, error) {
	match, err := c.searchSong(trackName, artistName, durationSec)
	if err != nil {
		return nil, err
	}
	params := url.Values{
		"format": {"json"}, "inCharset": {"utf8"}, "outCharset": {"utf-8"},
		"notice": {"0"}, "platform": {"yqq.json"}, "needNewCode": {"0"},
		"songmid": {match.Mid}, "songid": {strconv.FormatInt(match.ID, 10)},
	}
	raw, err := fetchQQMusicBody(c.httpClient, qqMusicLyricsURL, params)
	if err != nil {
		return nil, fmt.Errorf("QQ Music lyrics fetch failed: %w", err)
	}
	var response qqMusicLyricsResponse
	if err := json.Unmarshal(raw, &response); err != nil {
		return nil, fmt.Errorf("failed to decode QQ Music lyrics: %w", err)
	}
	if response.RetCode != 0 || response.Code != 0 {
		return nil, lyricsServiceUnavailableErrorf("QQ Music lyrics returned code %d", response.Code)
	}
	lrc, err := decodeQQMusicLyric(response.Lyric)
	if err != nil {
		return nil, err
	}
	lyrics := lyricsResponseFromLRCText(lrc, "QQ Music", "QQ Music Direct")
	if !lyricsHasUsableText(lyrics) {
		return nil, lyricsNotFoundErrorf("no lyrics found on QQ Music")
	}
	return lyrics, nil
}
