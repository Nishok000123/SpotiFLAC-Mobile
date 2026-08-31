package gobackend

import (
	"fmt"
	"io"
	"net/http"
	"strings"

	"golang.org/x/net/html"
)

const maxGeniusPageBytes = 8 << 20

func geniusLyricsContainer(node *html.Node) bool {
	if node.Type != html.ElementNode || node.Data != "div" {
		return false
	}
	for _, attr := range node.Attr {
		if attr.Key == "data-lyrics-container" && attr.Val == "true" {
			return true
		}
	}
	return false
}

func geniusExcludedNode(node *html.Node) bool {
	for _, attr := range node.Attr {
		if attr.Key == "data-exclude-from-selection" && attr.Val == "true" {
			return true
		}
	}
	return false
}

func appendGeniusText(builder *strings.Builder, node *html.Node) {
	if geniusExcludedNode(node) {
		return
	}
	if node.Type == html.TextNode {
		builder.WriteString(node.Data)
		return
	}
	if node.Type == html.ElementNode && node.Data == "br" {
		builder.WriteByte('\n')
		return
	}
	for child := node.FirstChild; child != nil; child = child.NextSibling {
		appendGeniusText(builder, child)
	}
}

func geniusLyricsFromHTML(body io.Reader) (string, error) {
	document, err := html.Parse(body)
	if err != nil {
		return "", fmt.Errorf("failed to parse Genius page: %w", err)
	}
	var containers []*html.Node
	var walk func(*html.Node)
	walk = func(node *html.Node) {
		if geniusLyricsContainer(node) {
			containers = append(containers, node)
		}
		for child := node.FirstChild; child != nil; child = child.NextSibling {
			walk(child)
		}
	}
	walk(document)
	if len(containers) == 0 {
		return "", lyricsNotFoundErrorf("Genius page has no lyrics container")
	}

	// Genius renders each verse/chorus as a separate lyrics container. Preserve
	// document order and join all usable containers into one LRC/plain payload.
	var sections []string
	for _, container := range containers {
		var builder strings.Builder
		appendGeniusText(&builder, container)
		candidate := strings.TrimSpace(strings.ReplaceAll(builder.String(), "\u00a0", " "))
		if rawLyricsHasUsableContent(candidate) {
			sections = append(sections, candidate)
		}
	}
	if len(sections) == 0 {
		return "", lyricsNotFoundErrorf("Genius page returned empty lyrics")
	}
	return strings.Join(sections, "\n"), nil
}

func (c *GeniusLyricsClient) fetchLyricsFromPage(pageURL string) (*LyricsResponse, error) {
	pageURL = strings.TrimSpace(pageURL)
	if pageURL == "" {
		return nil, lyricsNotFoundErrorf("empty Genius lyrics URL")
	}
	req, err := http.NewRequest(http.MethodGet, pageURL, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create Genius page request: %w", err)
	}
	req.Header.Set("Accept", "text/html,application/xhtml+xml")
	req.Header.Set("Accept-Language", "en-US,en;q=0.9")
	req.Header.Set("User-Agent", getRandomUserAgent())
	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("Genius page request failed: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, lyricsServiceUnavailableErrorf("Genius page returned HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxGeniusPageBytes+1))
	if err != nil {
		return nil, fmt.Errorf("failed to read Genius page: %w", err)
	}
	if len(data) > maxGeniusPageBytes {
		return nil, lyricsServiceUnavailableErrorf("Genius page exceeds %d bytes", maxGeniusPageBytes)
	}
	lrc, err := geniusLyricsFromHTML(strings.NewReader(string(data)))
	if err != nil {
		return nil, err
	}
	lyrics := lyricsResponseFromText(lrc, "Genius")
	lyrics.Source = "Genius Direct"
	return lyrics, nil
}
