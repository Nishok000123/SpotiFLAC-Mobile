package gobackend

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestRetryHardening(t *testing.T) {
	resp := &http.Response{Header: http.Header{"Retry-After": []string{"3600"}}}
	if d := getRetryAfterDuration(resp); d != maxRetryAfterDelay {
		t.Fatalf("Retry-After 3600s clamped to %v, want %v", d, maxRetryAfterDelay)
	}

	// A 403 without ISP-blocking markers must reach the caller with a
	// readable body even though the marker scan consumed the original.
	client := &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		return &http.Response{
			StatusCode: 403,
			Header:     make(http.Header),
			Body:       io.NopCloser(strings.NewReader("quota exceeded")),
			Request:    req,
		}, nil
	})}
	got, err := DoRequestWithRetry(client, mustNewRequest(t, "https://example.com/x"), DefaultRetryConfig())
	if err != nil || got.StatusCode != 403 {
		t.Fatalf("DoRequestWithRetry = %#v/%v", got, err)
	}
	body, err := io.ReadAll(got.Body)
	got.Body.Close()
	if err != nil || string(body) != "quota exceeded" {
		t.Fatalf("403 body = %q/%v, want restored body", body, err)
	}

	// Backoff sleeps must abort on context cancellation.
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(10 * time.Millisecond)
		cancel()
	}()
	start := time.Now()
	if err := sleepRetry(ctx, 5*time.Second); err == nil {
		t.Fatal("sleepRetry ignored cancellation")
	}
	if time.Since(start) > time.Second {
		t.Fatal("sleepRetry did not abort promptly on cancel")
	}
}

func TestRetryDrainsSmallFailureBodyForConnectionReuse(t *testing.T) {
	failedBody := bytes.NewBufferString("temporary failure")
	attempts := 0
	client := &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		attempts++
		if attempts == 1 {
			return &http.Response{
				StatusCode: http.StatusServiceUnavailable,
				Header:     make(http.Header),
				Body:       io.NopCloser(failedBody),
				Request:    req,
			}, nil
		}
		return &http.Response{
			StatusCode: http.StatusNoContent,
			Header:     make(http.Header),
			Body:       io.NopCloser(strings.NewReader("")),
			Request:    req,
		}, nil
	})}
	resp, err := DoRequestWithRetry(
		client,
		mustNewRequest(t, "https://example.com/reuse"),
		RetryConfig{MaxRetries: 1},
	)
	if err != nil || resp.StatusCode != http.StatusNoContent {
		t.Fatalf("DoRequestWithRetry = %#v/%v", resp, err)
	}
	resp.Body.Close()
	if failedBody.Len() != 0 {
		t.Fatalf("retry body retained %d unread bytes", failedBody.Len())
	}
}

func TestRetryCapsInspectedForbiddenBody(t *testing.T) {
	huge := strings.Repeat("x", int(maxRetryResponseBodyBytes)+1024)
	client := &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		return &http.Response{
			StatusCode: http.StatusForbidden,
			Header:     make(http.Header),
			Body:       io.NopCloser(strings.NewReader(huge)),
			Request:    req,
		}, nil
	})}
	resp, err := DoRequestWithRetry(
		client,
		mustNewRequest(t, "https://example.com/capped"),
		RetryConfig{MaxRetries: 0},
	)
	if err != nil {
		t.Fatalf("DoRequestWithRetry returned error: %v", err)
	}
	body, readErr := io.ReadAll(resp.Body)
	resp.Body.Close()
	if readErr != nil || int64(len(body)) != maxRetryResponseBodyBytes {
		t.Fatalf("capped body length = %d/%v, want %d", len(body), readErr, maxRetryResponseBodyBytes)
	}
}
