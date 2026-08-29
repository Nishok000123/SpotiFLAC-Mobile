package gobackend

import (
	"strings"
	"testing"

	"github.com/dop251/goja"
)

func TestWaitForPendingFFmpegCommandsClaimsCommandOnce(t *testing.T) {
	const commandID = "wait-claim-test"
	command := &FFmpegCommand{
		ExtensionID: "test-extension",
		Arguments:   []string{"-version"},
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

func TestExtensionFFmpegRejectsRawAndInjectedOptions(t *testing.T) {
	vm := goja.New()
	runtime := &extensionRuntime{
		extensionID: "ffmpeg-security",
		manifest: &ExtensionManifest{
			Permissions:  ExtensionPermissions{File: true},
			Capabilities: map[string]any{"rawFfmpeg": true},
		},
		dataDir: t.TempDir(),
		vm:      vm,
	}
	raw := runtime.ffmpegExecute(goja.FunctionCall{Arguments: []goja.Value{
		vm.ToValue("-i /private/secret -f data out"),
	}}).Export().(map[string]any)
	if raw["success"] != false || !strings.Contains(raw["error"].(string), "disabled") {
		t.Fatalf("raw FFmpeg was not rejected: %#v", raw)
	}

	injected := runtime.ffmpegConvert(goja.FunctionCall{Arguments: []goja.Value{
		vm.ToValue("input.flac"),
		vm.ToValue("output.flac"),
		vm.ToValue(map[string]any{"codec": "flac -i /private/secret"}),
	}}).Export().(map[string]any)
	if injected["success"] != false || !strings.Contains(injected["error"].(string), "unsupported") {
		t.Fatalf("FFmpeg option injection was not rejected: %#v", injected)
	}

	injectedBitrate := runtime.ffmpegConvert(goja.FunctionCall{Arguments: []goja.Value{
		vm.ToValue("input.flac"),
		vm.ToValue("output.m4a"),
		vm.ToValue(map[string]any{"bitrate": "320k -i /private/secret"}),
	}}).Export().(map[string]any)
	if injectedBitrate["success"] != false ||
		!strings.Contains(injectedBitrate["error"].(string), "bitrate") {
		t.Fatalf("FFmpeg bitrate injection was not rejected: %#v", injectedBitrate)
	}
}
