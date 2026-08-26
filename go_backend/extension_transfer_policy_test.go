package gobackend

import (
	"testing"
	"time"
)

func TestDownloadTransferPolicyParsesAndBoundsManifestCapability(t *testing.T) {
	manifest := &ExtensionManifest{Capabilities: map[string]any{
		"downloadTransfer": map[string]any{
			"maxAttempts":            float64(20),
			"initialRetryDelayMs":    float64(25),
			"maxRetryDelayMs":        float64(50),
			"resumePolicy":           "validated",
			"persistentCheckpoint":   true,
			"refreshStreamOnStatus":  []any{float64(401), float64(410)},
			"maxParallelSegments":    float64(99),
			"maxConcurrentDownloads": float64(99),
		},
	}}

	policy := manifest.DownloadTransferPolicy()
	if policy.MaxAttempts != 8 || policy.InitialRetryDelay != 100*time.Millisecond ||
		policy.MaxRetryDelay != 100*time.Millisecond || policy.ResumePolicy != "validated" ||
		!policy.PersistentCheckpoint || !policy.RefreshStreamOnStatus[401] ||
		!policy.RefreshStreamOnStatus[410] || policy.MaxParallelSegments != 8 ||
		policy.MaxConcurrentDownloads != 3 {
		t.Fatalf("unexpected policy: %#v", policy)
	}
}

func TestDownloadTransferCapabilityValidation(t *testing.T) {
	valid := map[string]any{"downloadTransfer": map[string]any{
		"resumePolicy":         "validated",
		"persistentCheckpoint": true,
	}}
	if err := validateDownloadTransferCapability(valid); err != nil {
		t.Fatalf("valid capability rejected: %v", err)
	}

	invalid := []map[string]any{
		{"downloadTransfer": "yes"},
		{"downloadTransfer": map[string]any{"resumePolicy": "unsafe"}},
		{"downloadTransfer": map[string]any{"persistentCheckpoint": "yes"}},
	}
	for _, capabilities := range invalid {
		if err := validateDownloadTransferCapability(capabilities); err == nil {
			t.Fatalf("invalid capability accepted: %#v", capabilities)
		}
	}
}
