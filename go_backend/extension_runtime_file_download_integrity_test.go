package gobackend

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/dop251/goja"
)

// shortCleanEOFBodyReader simulates a transport that surfaces a mid-transfer
// connection drop as a normal io.EOF instead of io.ErrUnexpectedEOF (which is
// what a network reset looks like through some custom transports, e.g. the
// uTLS-based client this app uses for TLS-fingerprint spoofing). It sends
// data once and then reports a clean end of stream, even though fewer bytes
// were sent than the response's Content-Length promised.
type shortCleanEOFBodyReader struct {
	data []byte
	sent bool
}

func (f *shortCleanEOFBodyReader) Read(p []byte) (int, error) {
	if !f.sent {
		f.sent = true
		n := copy(p, f.data)
		return n, io.EOF
	}
	return 0, io.EOF
}

func TestFileDownloadShortCleanEOFFailsByDefaultEvenWithValidator(t *testing.T) {
	var attempts int
	var rangeSeen bool
	runtime := newFileDownloadTestRuntime(t, func(req *http.Request) (*http.Response, error) {
		attempts++
		rangeSeen = rangeSeen || req.Header.Get("Range") != ""
		h := make(http.Header)
		h.Set("ETag", `"v1"`)
		return &http.Response{
			StatusCode:    200,
			Header:        h,
			Body:          io.NopCloser(&shortCleanEOFBodyReader{data: []byte("hello-")}),
			ContentLength: int64(len("hello-world!")),
			Request:       req,
		}, nil
	})

	// Resume is opt-in, so a short clean EOF must fail and clean up just like
	// a real read error would. The generic transfer engine may retry the whole
	// object, but must not send a Range request merely because a validator
	// happens to be present.
	result := runtime.fileDownload(goja.FunctionCall{Arguments: []goja.Value{
		runtime.vm.ToValue("https://cdn.example.com/track.flac"),
		runtime.vm.ToValue("out/track.flac"),
	}}).Export().(map[string]any)
	if result["success"] != false {
		t.Fatalf("expected failed download, got %#v", result)
	}
	if attempts != defaultTransferMaxAttempts {
		t.Fatalf("attempts = %d, want %d full retries", attempts, defaultTransferMaxAttempts)
	}
	if rangeSeen {
		t.Fatal("default retry unexpectedly sent a Range request")
	}

	finalPath := filepath.Join(runtime.dataDir, "out", "track.flac")
	if _, err := os.Stat(finalPath); !os.IsNotExist(err) {
		t.Fatalf("truncated download was promoted to the final path: %v", err)
	}
	if _, err := os.Stat(stagedDownloadPath(finalPath)); !os.IsNotExist(err) {
		t.Fatalf("staged partial file left behind: %v", err)
	}
}

func TestFileDownloadResumesAfterShortCleanEOFWhenEnabled(t *testing.T) {
	const full = "hello-world!"
	var attempts int
	var resumeRange, resumeIfRange string
	runtime := newFileDownloadTestRuntime(t, func(req *http.Request) (*http.Response, error) {
		attempts++
		if attempts == 1 {
			h := make(http.Header)
			h.Set("ETag", `"v1"`)
			return &http.Response{
				StatusCode:    200,
				Header:        h,
				Body:          io.NopCloser(&shortCleanEOFBodyReader{data: []byte(full[:6])}),
				ContentLength: int64(len(full)),
				Request:       req,
			}, nil
		}
		resumeRange = req.Header.Get("Range")
		resumeIfRange = req.Header.Get("If-Range")
		h := make(http.Header)
		h.Set("Content-Range", fmt.Sprintf("bytes 6-%d/%d", len(full)-1, len(full)))
		return &http.Response{
			StatusCode:    206,
			Header:        h,
			Body:          io.NopCloser(&shortCleanEOFBodyReader{data: []byte(full[6:])}),
			ContentLength: int64(len(full) - 6),
			Request:       req,
		}, nil
	})

	result := runtime.fileDownload(goja.FunctionCall{Arguments: []goja.Value{
		runtime.vm.ToValue("https://cdn.example.com/track.flac"),
		runtime.vm.ToValue("out/track.flac"),
		runtime.vm.ToValue(map[string]any{"resume": true}),
	}}).Export().(map[string]any)
	if result["success"] != true {
		t.Fatalf("download result = %#v", result)
	}
	if attempts != 2 || resumeRange != "bytes=6-" || resumeIfRange != `"v1"` {
		t.Fatalf("attempts=%d range=%q if-range=%q", attempts, resumeRange, resumeIfRange)
	}

	finalPath := filepath.Join(runtime.dataDir, "out", "track.flac")
	data, err := os.ReadFile(finalPath)
	if err != nil || string(data) != full {
		t.Fatalf("final file = %q/%v (a truncated file was silently promoted)", data, err)
	}
}

func TestFileDownloadResumesPersistentCheckpointInNewRuntime(t *testing.T) {
	const full = "hello-world!"
	firstRuntime := newFileDownloadTestRuntime(t, func(req *http.Request) (*http.Response, error) {
		header := make(http.Header)
		header.Set("ETag", `"v1"`)
		return &http.Response{
			StatusCode:    http.StatusOK,
			Header:        header,
			Body:          io.NopCloser(&shortCleanEOFBodyReader{data: []byte(full[:6])}),
			ContentLength: int64(len(full)),
			Request:       req,
		}, nil
	})
	options := map[string]any{
		"resume":               true,
		"persistentCheckpoint": true,
		"maxAttempts":          float64(1),
	}
	firstResult := firstRuntime.fileDownload(goja.FunctionCall{Arguments: []goja.Value{
		firstRuntime.vm.ToValue("https://cdn.example.com/track.flac?token=old"),
		firstRuntime.vm.ToValue("out/track.flac"),
		firstRuntime.vm.ToValue(options),
	}}).Export().(map[string]any)
	if firstResult["success"] != false {
		t.Fatalf("first result = %#v", firstResult)
	}

	var resumeRange, resumeIfRange string
	secondRuntime := newFileDownloadTestRuntime(t, func(req *http.Request) (*http.Response, error) {
		resumeRange = req.Header.Get("Range")
		resumeIfRange = req.Header.Get("If-Range")
		header := make(http.Header)
		header.Set("Content-Range", fmt.Sprintf("bytes 6-%d/%d", len(full)-1, len(full)))
		return &http.Response{
			StatusCode:    http.StatusPartialContent,
			Header:        header,
			Body:          io.NopCloser(strings.NewReader(full[6:])),
			ContentLength: int64(len(full) - 6),
			Request:       req,
		}, nil
	})
	secondRuntime.dataDir = firstRuntime.dataDir
	secondResult := secondRuntime.fileDownload(goja.FunctionCall{Arguments: []goja.Value{
		secondRuntime.vm.ToValue("https://cdn.example.com/track.flac?token=fresh"),
		secondRuntime.vm.ToValue("out/track.flac"),
		secondRuntime.vm.ToValue(options),
	}}).Export().(map[string]any)
	if secondResult["success"] != true {
		t.Fatalf("second result = %#v", secondResult)
	}
	if resumeRange != "bytes=6-" || resumeIfRange != `"v1"` {
		t.Fatalf("range=%q if-range=%q", resumeRange, resumeIfRange)
	}
	data, err := os.ReadFile(filepath.Join(firstRuntime.dataDir, "out", "track.flac"))
	if err != nil || string(data) != full {
		t.Fatalf("resumed file = %q, err=%v", data, err)
	}
}

func TestFileDownloadShortCleanEOFWithoutValidatorFails(t *testing.T) {
	runtime := newFileDownloadTestRuntime(t, func(req *http.Request) (*http.Response, error) {
		// No ETag/Last-Modified, so the download cannot be resumed and must
		// fail outright rather than promote a truncated file.
		return &http.Response{
			StatusCode:    200,
			Header:        make(http.Header),
			Body:          io.NopCloser(&shortCleanEOFBodyReader{data: []byte("partial-aud")}),
			ContentLength: 1 << 20,
			Request:       req,
		}, nil
	})

	result := runtime.fileDownload(goja.FunctionCall{Arguments: []goja.Value{
		runtime.vm.ToValue("https://cdn.example.com/track.flac"),
		runtime.vm.ToValue("out/track.flac"),
	}}).Export().(map[string]any)
	if result["success"] != false {
		t.Fatalf("expected a failed download for a short clean EOF with no validator, got %#v", result)
	}

	finalPath := filepath.Join(runtime.dataDir, "out", "track.flac")
	if _, err := os.Stat(finalPath); !os.IsNotExist(err) {
		t.Fatalf("truncated download was promoted to the final path: %v", err)
	}
	if _, err := os.Stat(stagedDownloadPath(finalPath)); !os.IsNotExist(err) {
		t.Fatalf("staged partial file left behind: %v", err)
	}
}

func TestChunkedDownloadRestartsWhenServerIgnoresLaterRange(t *testing.T) {
	const full = "abcdefgh"
	var requestedRanges []string
	runtime := newFileDownloadTestRuntime(t, func(req *http.Request) (*http.Response, error) {
		rangeHeader := req.Header.Get("Range")
		requestedRanges = append(requestedRanges, rangeHeader)
		header := make(http.Header)
		header.Set("ETag", `"v1"`)
		switch rangeHeader {
		case "bytes=0-1":
			header.Set("Content-Range", "bytes 0-1/8")
			return &http.Response{
				StatusCode:    http.StatusPartialContent,
				Header:        header,
				Body:          io.NopCloser(strings.NewReader(full[:2])),
				ContentLength: 2,
				Request:       req,
			}, nil
		case "bytes=0-2":
			header.Set("Content-Range", "bytes 0-2/8")
			return &http.Response{
				StatusCode:    http.StatusPartialContent,
				Header:        header,
				Body:          io.NopCloser(strings.NewReader(full[:3])),
				ContentLength: 3,
				Request:       req,
			}, nil
		default:
			// Some CDNs invalidate or ignore Range after the first request. The
			// full response must replace the partial file instead of being appended.
			return &http.Response{
				StatusCode:    http.StatusOK,
				Header:        header,
				Body:          io.NopCloser(strings.NewReader(full)),
				ContentLength: int64(len(full)),
				Request:       req,
			}, nil
		}
	})

	result := runtime.fileDownload(goja.FunctionCall{Arguments: []goja.Value{
		runtime.vm.ToValue("https://cdn.example.com/track.flac"),
		runtime.vm.ToValue("out/track.flac"),
		runtime.vm.ToValue(map[string]any{"chunked": float64(3)}),
	}}).Export().(map[string]any)
	if result["success"] != true {
		t.Fatalf("chunked result = %#v", result)
	}
	data, err := os.ReadFile(filepath.Join(runtime.dataDir, "out", "track.flac"))
	if err != nil || string(data) != full {
		t.Fatalf("chunked file = %q, err=%v", data, err)
	}
	if got := requestedRanges[len(requestedRanges)-1]; got != "bytes=3-5" {
		t.Fatalf("last requested range = %q, all=%v", got, requestedRanges)
	}
}

func TestFileDownloadRejectsChangedValidatorDuringResume(t *testing.T) {
	runtime := newFileDownloadTestRuntime(t, func(req *http.Request) (*http.Response, error) {
		header := make(http.Header)
		header.Set("ETag", `"v2"`)
		header.Set("Content-Range", "bytes 3-5/6")
		return &http.Response{
			StatusCode:    http.StatusPartialContent,
			Header:        header,
			Body:          io.NopCloser(strings.NewReader("DEF")),
			ContentLength: 3,
			Request:       req,
		}, nil
	})
	fullPath := filepath.Join(runtime.dataDir, "out", "track.flac")
	if err := os.MkdirAll(filepath.Dir(fullPath), 0755); err != nil {
		t.Fatal(err)
	}
	stagedPath := stagedDownloadPath(fullPath)
	if err := os.WriteFile(stagedPath, []byte("ABC"), 0600); err != nil {
		t.Fatal(err)
	}
	url := "https://cdn.example.com/track.flac"
	if err := saveTransferCheckpoint(transferCheckpointPath(stagedPath), transferCheckpoint{
		Fingerprint: transferURLFingerprint(url),
		Validator:   `"v1"`,
		Bytes:       3,
		Total:       6,
	}); err != nil {
		t.Fatal(err)
	}

	result := runtime.fileDownload(goja.FunctionCall{Arguments: []goja.Value{
		runtime.vm.ToValue(url),
		runtime.vm.ToValue("out/track.flac"),
		runtime.vm.ToValue(map[string]any{
			"resume":               true,
			"persistentCheckpoint": true,
		}),
	}}).Export().(map[string]any)
	if result["success"] != false || result["error_type"] != "integrity_failed" {
		t.Fatalf("changed-validator result = %#v", result)
	}
	if _, err := os.Stat(fullPath); !os.IsNotExist(err) {
		t.Fatalf("changed entity was published: %v", err)
	}
}

func TestFileDownloadCallerRangeDoesNotReuseEngineCheckpoint(t *testing.T) {
	var observedRange string
	runtime := newFileDownloadTestRuntime(t, func(req *http.Request) (*http.Response, error) {
		observedRange = req.Header.Get("Range")
		header := make(http.Header)
		header.Set("Content-Range", "bytes 5-7/8")
		return &http.Response{
			StatusCode:    http.StatusPartialContent,
			Header:        header,
			Body:          io.NopCloser(strings.NewReader("NEW")),
			ContentLength: 3,
			Request:       req,
		}, nil
	})
	fullPath := filepath.Join(runtime.dataDir, "out", "fragment.bin")
	if err := os.MkdirAll(filepath.Dir(fullPath), 0755); err != nil {
		t.Fatal(err)
	}
	stagedPath := stagedDownloadPath(fullPath)
	if err := os.WriteFile(stagedPath, []byte("OLD"), 0600); err != nil {
		t.Fatal(err)
	}
	url := "https://cdn.example.com/track.flac"
	if err := saveTransferCheckpoint(transferCheckpointPath(stagedPath), transferCheckpoint{
		Fingerprint: transferURLFingerprint(url),
		Validator:   `"v1"`,
		Bytes:       3,
		Total:       8,
	}); err != nil {
		t.Fatal(err)
	}

	result := runtime.fileDownload(goja.FunctionCall{Arguments: []goja.Value{
		runtime.vm.ToValue(url),
		runtime.vm.ToValue("out/fragment.bin"),
		runtime.vm.ToValue(map[string]any{
			"headers":              map[string]any{"Range": "bytes=5-7"},
			"resume":               true,
			"persistentCheckpoint": true,
		}),
	}}).Export().(map[string]any)
	if result["success"] != true {
		t.Fatalf("caller-range result = %#v", result)
	}
	data, err := os.ReadFile(fullPath)
	if err != nil || string(data) != "NEW" {
		t.Fatalf("caller-range file = %q, err=%v", data, err)
	}
	if observedRange != "bytes=5-7" {
		t.Fatalf("observed Range = %q", observedRange)
	}
}

func TestFileDownloadPromotesFullyCheckpointedStagedFileWithoutNetwork(t *testing.T) {
	var networkCalls int
	runtime := newFileDownloadTestRuntime(t, func(req *http.Request) (*http.Response, error) {
		networkCalls++
		return nil, fmt.Errorf("network should not be called")
	})
	const full = "already-complete"
	fullPath := filepath.Join(runtime.dataDir, "out", "track.flac")
	if err := os.MkdirAll(filepath.Dir(fullPath), 0755); err != nil {
		t.Fatal(err)
	}
	stagedPath := stagedDownloadPath(fullPath)
	if err := os.WriteFile(stagedPath, []byte(full), 0600); err != nil {
		t.Fatal(err)
	}
	url := "https://cdn.example.com/track.flac"
	if err := saveTransferCheckpoint(transferCheckpointPath(stagedPath), transferCheckpoint{
		Fingerprint: transferURLFingerprint(url),
		Validator:   `"v1"`,
		Bytes:       int64(len(full)),
		Total:       int64(len(full)),
	}); err != nil {
		t.Fatal(err)
	}

	result := runtime.fileDownload(goja.FunctionCall{Arguments: []goja.Value{
		runtime.vm.ToValue(url),
		runtime.vm.ToValue("out/track.flac"),
		runtime.vm.ToValue(map[string]any{
			"resume":               true,
			"persistentCheckpoint": true,
		}),
	}}).Export().(map[string]any)
	if result["success"] != true || result["resumed"] != true {
		t.Fatalf("fully checkpointed result = %#v", result)
	}
	if networkCalls != 0 {
		t.Fatalf("network calls = %d", networkCalls)
	}
	data, err := os.ReadFile(fullPath)
	if err != nil || string(data) != full {
		t.Fatalf("promoted file = %q, err=%v", data, err)
	}
}
