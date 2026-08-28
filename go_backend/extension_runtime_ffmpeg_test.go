package gobackend

import (
	"strings"
	"testing"
)

func TestWaitForPendingFFmpegCommandsClaimsCommandOnce(t *testing.T) {
	const commandID = "wait-claim-test"
	command := &FFmpegCommand{
		ExtensionID: "test-extension",
		Command:     "ffmpeg -version",
		done:        make(chan struct{}),
	}
	ffmpegCommandsMu.Lock()
	ffmpegCommands[commandID] = command
	ffmpegCommandsMu.Unlock()
	notifyFFmpegCommandQueued()
	t.Cleanup(func() { ClearFFmpegCommand(commandID) })

	first, err := WaitForPendingFFmpegCommandsJSON(50)
	if err != nil || !strings.Contains(first, commandID) {
		t.Fatalf("first wait = %q, %v", first, err)
	}
	second, err := WaitForPendingFFmpegCommandsJSON(1)
	if err != nil || second != "[]" {
		t.Fatalf("claimed command returned twice: %q, %v", second, err)
	}

	SetFFmpegCommandResult(commandID, true, "ok", "")
	select {
	case <-command.done:
	default:
		t.Fatal("command completion did not signal waiter")
	}
}
