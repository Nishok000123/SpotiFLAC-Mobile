package gobackend

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/dop251/goja"
)

func TestLogBufferExportedHelpersAndRedaction(t *testing.T) {
	ClearLogs()
	SetLoggingEnabled(false)
	LogInfo("test", "ignored access_token=secret")
	LogError("test", "Authorization: Bearer secret-token api_key=value")
	if GetLogBuffer().Count() != 1 {
		t.Fatalf("disabled logging should keep errors only, got %d", GetLogBuffer().Count())
	}

	SetLoggingEnabled(true)
	defer SetLoggingEnabled(false)
	LogDebug("debug", "client_secret=secret")
	LogWarn("warn", "warning password=secret")
	GoLog("[GoTag] success token=abc")
	LogError("json", `{"access_token":"json-secret","session_secret":"session-secret"}`)
	LogError("query", "https://example.test/?X-Amz-Signature=signed-secret&X-Amz-Security-Token=session-token")
	LogError("ffmpeg", "-decryption_key raw-media-key -i https://example.test/audio")
	LogError("bounded", "%s", strings.Repeat("x", maxLogMessageLength+500))

	var entries []LogEntry
	if err := json.Unmarshal([]byte(GetLogBuffer().GetAll()), &entries); err != nil {
		t.Fatalf("GetAll JSON: %v", err)
	}
	if len(entries) < 4 {
		t.Fatalf("expected log entries, got %#v", entries)
	}
	for _, entry := range entries {
		if strings.Contains(entry.Message, "secret-token") || strings.Contains(entry.Message, "api_key=value") || strings.Contains(entry.Message, "password=secret") || strings.Contains(entry.Message, "json-secret") || strings.Contains(entry.Message, "session-secret") || strings.Contains(entry.Message, "signed-secret") || strings.Contains(entry.Message, "session-token") || strings.Contains(entry.Message, "raw-media-key") {
			t.Fatalf("log was not redacted: %#v", entry)
		}
		if len(entry.Message) > maxLogMessageLength+len("...[truncated]") {
			t.Fatalf("log was not bounded: %d bytes", len(entry.Message))
		}
	}

	sinceJSON := GetLogsSince(1)
	if !strings.Contains(sinceJSON, `"next_index"`) || !strings.Contains(sinceJSON, `"logs"`) {
		t.Fatalf("GetLogsSince = %q", sinceJSON)
	}
	if emptyJSON := GetLogsSince(999); !strings.Contains(emptyJSON, `"logs":[]`) {
		t.Fatalf("GetLogsSince empty = %q", emptyJSON)
	}
	if negativeJSON := GetLogsSince(-5); !strings.Contains(negativeJSON, `"logs"`) {
		t.Fatalf("GetLogsSince negative = %q", negativeJSON)
	}

	ClearLogs()
	if GetLogBuffer().Count() != 0 || GetLogBuffer().GetAll() != "[]" {
		t.Fatalf("logs were not cleared: count=%d logs=%s", GetLogBuffer().Count(), GetLogBuffer().GetAll())
	}
}

func TestLogBufferCursorSurvivesRollover(t *testing.T) {
	lb := &LogBuffer{
		entries:        make([]LogEntry, 3),
		maxSize:        3,
		loggingEnabled: true,
	}
	for _, message := range []string{"one", "two", "three"} {
		lb.Add("INFO", "Test", message)
	}
	initial, cursor := lb.getSince(0)
	if cursor != 3 || len(initial) != 3 || initial[0].Message != "one" {
		t.Fatalf("initial logs/cursor = %#v/%d", initial, cursor)
	}

	lb.Add("INFO", "Test", "four")
	newLogs, cursor := lb.getSince(cursor)
	if cursor != 4 || len(newLogs) != 1 || newLogs[0].Message != "four" {
		t.Fatalf("rollover logs/cursor = %#v/%d", newLogs, cursor)
	}

	lb.Add("INFO", "Test", "five")
	lb.Add("INFO", "Test", "six")
	retained, cursor := lb.getSince(1)
	if cursor != 6 || len(retained) != 3 || retained[0].Message != "four" || retained[2].Message != "six" {
		t.Fatalf("retained logs/cursor = %#v/%d", retained, cursor)
	}

	lb.Clear()
	lb.Add("INFO", "Test", "seven")
	afterClear, cursor := lb.getSince(6)
	if cursor != 7 || len(afterClear) != 1 || afterClear[0].Message != "seven" {
		t.Fatalf("after clear logs/cursor = %#v/%d", afterClear, cursor)
	}
}

func TestProgressItemHelpersAndWriter(t *testing.T) {
	ClearAllItemProgress()
	itemID := "progress-writer"
	StartItemProgress(itemID)
	SetItemBytesTotal(itemID, int64(progressUpdateThreshold*2))
	SetItemBytesReceived(itemID, int64(progressUpdateThreshold))

	progressJSON := GetItemProgress(itemID)
	if !strings.Contains(progressJSON, `"bytes_received":131072`) || !strings.Contains(progressJSON, `"progress":0.5`) {
		t.Fatalf("GetItemProgress = %q", progressJSON)
	}
	if missing := GetItemProgress("missing"); missing != "{}" {
		t.Fatalf("missing progress = %q", missing)
	}

	var out bytes.Buffer
	writer := NewItemProgressWriter(&out, itemID)
	payload := bytes.Repeat([]byte("x"), progressUpdateThreshold+1)
	n, err := writer.Write(payload)
	if err != nil || n != len(payload) {
		t.Fatalf("progress writer = %d/%v", n, err)
	}
	if out.Len() != len(payload) {
		t.Fatalf("writer output length = %d", out.Len())
	}
	if progressJSON = GetItemProgress(itemID); !strings.Contains(progressJSON, `"bytes_received":131073`) {
		t.Fatalf("progress after writer = %q", progressJSON)
	}

	cancelDownload(itemID)
	defer clearDownloadCancel(itemID)
	n, err = writer.Write([]byte("cancelled"))
	if n != 0 || !errors.Is(err, ErrDownloadCancelled) {
		t.Fatalf("cancelled writer = %d/%v", n, err)
	}

	ClearAllItemProgress()
}

func TestRunWithTimeoutBranches(t *testing.T) {
	timeoutVM := goja.New()
	_, err := RunWithTimeoutAndRecover(timeoutVM, "for (;;) {}", 10*time.Millisecond)
	if err == nil {
		t.Fatal("expected timeout error")
	}
	if !IsTimeoutError(&JSExecutionError{Message: "timeout", IsTimeout: true}) {
		t.Fatal("JSExecutionError should be recognized as timeout")
	}
	if IsTimeoutError(errors.New("plain")) {
		t.Fatal("plain error should not be timeout")
	}
	if (&JSExecutionError{Message: "boom"}).Error() != "boom" {
		t.Fatal("JSExecutionError Error mismatch")
	}
}

func TestRunWithTimeoutQuarantinesUnresponsiveRuntime(t *testing.T) {
	previousGrace := jsInterruptGracePeriod
	jsInterruptGracePeriod = 10 * time.Millisecond
	defer func() { jsInterruptGracePeriod = previousGrace }()

	vm := goja.New()
	release := make(chan struct{})
	if err := vm.Set("block", func() { <-release }); err != nil {
		t.Fatal(err)
	}
	_, err := RunWithTimeoutAndRecover(vm, "block()", 10*time.Millisecond)
	if !IsRuntimeUnsafeError(err) {
		close(release)
		t.Fatalf("expected unsafe runtime error, got %v", err)
	}
	done := runtimeCompletion(err)
	if done == nil {
		close(release)
		t.Fatal("unsafe runtime error should expose a completion signal")
	}
	select {
	case <-done:
		close(release)
		t.Fatal("completion signal closed while the JS goroutine was blocked")
	default:
	}
	close(release)
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("completion signal did not close after the JS goroutine exited")
	}
}

func TestRunWithTimeoutQuarantinesUnresponsiveCancelledRuntime(t *testing.T) {
	previousGrace := jsInterruptGracePeriod
	jsInterruptGracePeriod = 10 * time.Millisecond
	defer func() { jsInterruptGracePeriod = previousGrace }()

	vm := goja.New()
	entered := make(chan struct{})
	release := make(chan struct{})
	if err := vm.Set("block", func() {
		close(entered)
		<-release
	}); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	result := make(chan error, 1)
	go func() {
		_, err := RunWithTimeoutContextAndRecover(ctx, vm, "block()", time.Second)
		result <- err
	}()
	<-entered
	cancel()
	err := <-result
	if !IsRuntimeUnsafeError(err) || !errors.Is(err, ErrExtensionRequestCancelled) {
		close(release)
		t.Fatalf("expected unsafe cancellation error, got %v", err)
	}
	done := runtimeCompletion(err)
	if done == nil {
		close(release)
		t.Fatal("unsafe cancellation should expose a completion signal")
	}
	close(release)
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("cancelled runtime did not report completion")
	}
}

func TestQuarantinedRuntimeBlocksReplacementUntilExecutionStops(t *testing.T) {
	vm := goja.New()
	runtime := &extensionRuntime{}
	ext := &loadedExtension{
		ID:          "quarantine-test",
		VM:          vm,
		runtime:     runtime,
		initialized: true,
	}
	done := make(chan struct{})
	err := &JSExecutionError{
		Message:       "runtime quarantined",
		RuntimeUnsafe: true,
		runtimeDone:   done,
	}

	quarantineRuntimeLocked(ext, vm, err)
	if ext.VM != nil || ext.runtime != nil || ext.initialized {
		t.Fatal("quarantine should detach the unsafe runtime")
	}
	if !hasQuarantinedRuntime(ext) {
		t.Fatal("extension should remain gated while execution is still running")
	}
	if err := ensureRuntimeReadyLocked(ext, false); err == nil ||
		!strings.Contains(err.Error(), "still stopping") {
		t.Fatalf("replacement runtime should be blocked, got %v", err)
	}

	close(done)
	deadline := time.Now().Add(time.Second)
	for hasQuarantinedRuntime(ext) && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if hasQuarantinedRuntime(ext) {
		t.Fatal("extension remained gated after the old execution stopped")
	}
	runtime.storageMu.RLock()
	closed := runtime.storageClosed
	runtime.storageMu.RUnlock()
	if !closed {
		t.Fatal("quarantined runtime resources were not closed after completion")
	}
}
