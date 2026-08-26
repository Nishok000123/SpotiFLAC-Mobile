package gobackend

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/dop251/goja"
)

func segmentTestRuntime(t *testing.T, transport roundTripFunc) *extensionRuntime {
	t.Helper()
	runtime := newFileDownloadTestRuntime(t, transport)
	runtime.manifest.Capabilities = map[string]any{
		"downloadTransfer": map[string]any{
			"maxAttempts":          float64(3),
			"initialRetryDelayMs":  float64(100),
			"maxRetryDelayMs":      float64(100),
			"resumePolicy":         "validated",
			"persistentCheckpoint": true,
			"maxParallelSegments":  float64(3),
		},
	}
	return runtime
}

func TestFileDownloadSegmentsPreservesOrderRetriesAndRunsConcurrently(t *testing.T) {
	var active atomic.Int32
	var maxActive atomic.Int32
	var mu sync.Mutex
	attempts := map[string]int{}
	runtime := segmentTestRuntime(t, func(req *http.Request) (*http.Response, error) {
		name := strings.TrimPrefix(req.URL.Path, "/")
		mu.Lock()
		attempts[name]++
		attempt := attempts[name]
		mu.Unlock()

		current := active.Add(1)
		defer active.Add(-1)
		for {
			previous := maxActive.Load()
			if current <= previous || maxActive.CompareAndSwap(previous, current) {
				break
			}
		}
		time.Sleep(40 * time.Millisecond)
		if name == "segment-1" && attempt == 1 {
			return &http.Response{
				StatusCode: http.StatusServiceUnavailable,
				Header:     make(http.Header),
				Body:       io.NopCloser(strings.NewReader("retry")),
				Request:    req,
			}, nil
		}
		body := map[string]string{
			"segment-0": "A",
			"segment-1": "B",
			"segment-2": "C",
		}[name]
		return &http.Response{
			StatusCode:    http.StatusOK,
			Header:        make(http.Header),
			Body:          io.NopCloser(strings.NewReader(body)),
			ContentLength: int64(len(body)),
			Request:       req,
		}, nil
	})

	segments := []any{
		"https://cdn.example.com/segment-0",
		"https://cdn.example.com/segment-1",
		"https://cdn.example.com/segment-2",
	}
	result := runtime.fileDownloadSegments(goja.FunctionCall{Arguments: []goja.Value{
		runtime.vm.ToValue(segments),
		runtime.vm.ToValue("out/track.flac"),
	}}).Export().(map[string]any)
	if result["success"] != true {
		t.Fatalf("segmented result = %#v", result)
	}
	data, err := os.ReadFile(filepath.Join(runtime.dataDir, "out", "track.flac"))
	if err != nil || string(data) != "ABC" {
		t.Fatalf("assembled data = %q, err=%v", data, err)
	}
	if maxActive.Load() < 2 {
		t.Fatalf("segments did not overlap; max active = %d", maxActive.Load())
	}
	mu.Lock()
	segmentOneAttempts := attempts["segment-1"]
	mu.Unlock()
	if segmentOneAttempts != 2 {
		t.Fatalf("segment-1 attempts = %d, want 2", segmentOneAttempts)
	}
}

func TestFileDownloadSegmentsResumesAssembledCheckpoint(t *testing.T) {
	requested := make(chan string, 2)
	runtime := segmentTestRuntime(t, func(req *http.Request) (*http.Response, error) {
		name := strings.TrimPrefix(req.URL.Path, "/")
		requested <- name
		body := "B"
		return &http.Response{
			StatusCode:    http.StatusOK,
			Header:        make(http.Header),
			Body:          io.NopCloser(strings.NewReader(body)),
			ContentLength: int64(len(body)),
			Request:       req,
		}, nil
	})

	segments := []segmentTransferSpec{
		{Index: 0, URL: "https://cdn.example.com/segment-0"},
		{Index: 1, URL: "https://cdn.example.com/segment-1"},
	}
	fullPath := filepath.Join(runtime.dataDir, "out", "track.flac")
	if err := os.MkdirAll(filepath.Dir(fullPath), 0755); err != nil {
		t.Fatal(err)
	}
	stagedPath := stagedDownloadPath(fullPath)
	if err := os.WriteFile(stagedPath, []byte("A"), 0600); err != nil {
		t.Fatal(err)
	}
	checkpointPath := transferCheckpointPath(stagedPath) + ".segments"
	if err := saveSegmentCheckpoint(checkpointPath, segmentTransferCheckpoint{
		Fingerprint: segmentListFingerprint(segments),
		NextIndex:   1,
		Bytes:       1,
	}); err != nil {
		t.Fatal(err)
	}

	result := runtime.fileDownloadSegments(goja.FunctionCall{Arguments: []goja.Value{
		runtime.vm.ToValue([]any{segments[0].URL, segments[1].URL}),
		runtime.vm.ToValue("out/track.flac"),
	}}).Export().(map[string]any)
	if result["success"] != true {
		t.Fatalf("segmented resume result = %#v", result)
	}
	close(requested)
	requests := []string{}
	for name := range requested {
		requests = append(requests, name)
	}
	if len(requests) != 1 || requests[0] != "segment-1" {
		t.Fatalf("requests after checkpoint = %v", requests)
	}
	data, err := os.ReadFile(fullPath)
	if err != nil || string(data) != "AB" {
		t.Fatalf("resumed data = %q, err=%v", data, err)
	}
	if _, err := os.Stat(checkpointPath); !os.IsNotExist(err) {
		t.Fatalf("checkpoint not removed after publish: %v", err)
	}
}

func TestFileDownloadSegmentsReturnsTypedExpiredStreamError(t *testing.T) {
	runtime := segmentTestRuntime(t, func(req *http.Request) (*http.Response, error) {
		return &http.Response{
			StatusCode: http.StatusForbidden,
			Header:     make(http.Header),
			Body:       io.NopCloser(strings.NewReader("expired")),
			Request:    req,
		}, nil
	})
	result := runtime.fileDownloadSegments(goja.FunctionCall{Arguments: []goja.Value{
		runtime.vm.ToValue([]any{"https://cdn.example.com/segment-0"}),
		runtime.vm.ToValue("out/track.flac"),
	}}).Export().(map[string]any)
	if result["success"] != false || result["error_type"] != "expired_stream" ||
		fmt.Sprint(result["http_status"]) != fmt.Sprint(http.StatusForbidden) {
		t.Fatalf("typed error = %#v", result)
	}
	if message := fmt.Sprint(result["error"]); !strings.Contains(message, "403") {
		t.Fatalf("typed error message = %q", message)
	}
}

func TestFileDownloadSegmentsRestartsWhenCheckpointExceedsStagedFile(t *testing.T) {
	var mu sync.Mutex
	requested := []string{}
	runtime := segmentTestRuntime(t, func(req *http.Request) (*http.Response, error) {
		name := strings.TrimPrefix(req.URL.Path, "/")
		mu.Lock()
		requested = append(requested, name)
		mu.Unlock()
		body := map[string]string{"segment-0": "A", "segment-1": "B"}[name]
		return &http.Response{
			StatusCode:    http.StatusOK,
			Header:        make(http.Header),
			Body:          io.NopCloser(strings.NewReader(body)),
			ContentLength: int64(len(body)),
			Request:       req,
		}, nil
	})
	segments := []segmentTransferSpec{
		{Index: 0, URL: "https://cdn.example.com/segment-0"},
		{Index: 1, URL: "https://cdn.example.com/segment-1"},
	}
	fullPath := filepath.Join(runtime.dataDir, "out", "track.flac")
	if err := os.MkdirAll(filepath.Dir(fullPath), 0755); err != nil {
		t.Fatal(err)
	}
	stagedPath := stagedDownloadPath(fullPath)
	if err := os.WriteFile(stagedPath, nil, 0600); err != nil {
		t.Fatal(err)
	}
	if err := saveSegmentCheckpoint(
		transferCheckpointPath(stagedPath)+".segments",
		segmentTransferCheckpoint{
			Fingerprint: segmentListFingerprint(segments),
			NextIndex:   1,
			Bytes:       1,
		},
	); err != nil {
		t.Fatal(err)
	}

	result := runtime.fileDownloadSegments(goja.FunctionCall{Arguments: []goja.Value{
		runtime.vm.ToValue([]any{segments[0].URL, segments[1].URL}),
		runtime.vm.ToValue("out/track.flac"),
	}}).Export().(map[string]any)
	if result["success"] != true {
		t.Fatalf("stale-checkpoint result = %#v", result)
	}
	data, err := os.ReadFile(fullPath)
	if err != nil || string(data) != "AB" {
		t.Fatalf("restarted segmented data = %q, err=%v", data, err)
	}
	mu.Lock()
	requestCount := len(requested)
	mu.Unlock()
	if requestCount != 2 {
		t.Fatalf("requested segments = %v", requested)
	}
}

func TestSegmentCheckpointFingerprintIncludesQueryIdentity(t *testing.T) {
	first := []segmentTransferSpec{{
		Index: 0,
		URL:   "https://cdn.example.com/audio?media=first",
	}}
	second := []segmentTransferSpec{{
		Index: 0,
		URL:   "https://cdn.example.com/audio?media=second",
	}}
	if segmentListFingerprint(first) == segmentListFingerprint(second) {
		t.Fatal("different segment query identities shared a checkpoint fingerprint")
	}
}
