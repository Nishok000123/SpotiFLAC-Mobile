package gobackend

import (
	"encoding/json"
	"testing"
	"time"
)

func TestWaitForMultiProgressDeltaWakesOnRevision(t *testing.T) {
	ClearAllItemProgress()
	defer ClearAllItemProgress()

	multiMu.RLock()
	since := multiProgressSeq
	multiMu.RUnlock()
	result := make(chan string, 1)
	go func() {
		result <- WaitForMultiProgressDelta(since, 1_000)
	}()
	time.Sleep(10 * time.Millisecond)
	StartItemProgress("wait-progress")
	select {
	case payload := <-result:
		if payload == "" {
			t.Fatal("waiter woke without a progress delta")
		}
		var delta MultiProgressDelta
		if err := json.Unmarshal([]byte(payload), &delta); err != nil {
			t.Fatalf("decode delta: %v", err)
		}
		if delta.Items["wait-progress"] == nil {
			t.Fatalf("delta missing item: %#v", delta)
		}
	case <-time.After(time.Second):
		t.Fatal("progress waiter did not wake")
	}
}

func TestWaitForMultiProgressDeltaHeartbeatTimeout(t *testing.T) {
	ClearAllItemProgress()
	defer ClearAllItemProgress()
	multiMu.RLock()
	since := multiProgressSeq
	multiMu.RUnlock()
	startedAt := time.Now()
	if payload := WaitForMultiProgressDelta(since, 20); payload != "" {
		t.Fatalf("timeout payload = %q, want empty", payload)
	}
	if elapsed := time.Since(startedAt); elapsed < 15*time.Millisecond {
		t.Fatalf("wait returned too early after %v", elapsed)
	}
}

func TestItemTransferProgressReporterCoalescesHotPathUpdates(t *testing.T) {
	ClearAllItemProgress()
	defer ClearAllItemProgress()

	const itemID = "coalesced-transfer-progress"
	const total = int64(1024 * 1024)
	StartItemProgress(itemID)
	SetItemDownloading(itemID)
	SetItemBytesTotal(itemID, total)
	reporter := NewItemTransferProgressReporter(itemID, 0, total)

	reporter.Report(64*1024, total)
	if received := multiProgress.Items[itemID].BytesReceived; received != 0 {
		t.Fatalf("sub-threshold bytes = %d, want 0", received)
	}

	reporter.Report(progressUpdateThreshold, total)
	if received := multiProgress.Items[itemID].BytesReceived; received != progressUpdateThreshold {
		t.Fatalf("threshold bytes = %d, want %d", received, progressUpdateThreshold)
	}

	reporter.lastReportAt = time.Now().Add(-progressUpdateMaxInterval)
	reporter.Report(progressUpdateThreshold+1, total)
	if received := multiProgress.Items[itemID].BytesReceived; received != progressUpdateThreshold+1 {
		t.Fatalf("interval flush bytes = %d, want %d", received, progressUpdateThreshold+1)
	}
}

func TestItemProgressPreparingAndDownloadingStatuses(t *testing.T) {
	const itemID = "progress-phase-item"
	RemoveItemProgress(itemID)
	defer RemoveItemProgress(itemID)

	StartItemProgress(itemID)
	SetItemPreparing(itemID)

	if item := multiProgress.Items[itemID]; item == nil {
		t.Fatal("expected item progress entry to exist")
	} else {
		if item.Status != itemProgressStatusPreparing {
			t.Fatalf("status = %q, want %q", item.Status, itemProgressStatusPreparing)
		}
		if item.Progress != 0 {
			t.Fatalf("progress = %v, want 0", item.Progress)
		}
	}

	SetItemProgress(itemID, 0.05, 0, 0)
	if item := multiProgress.Items[itemID]; item == nil {
		t.Fatal("expected item progress entry to exist after update")
	} else if item.Status != itemProgressStatusPreparing {
		t.Fatalf("status after synthetic pre-download progress = %q, want %q", item.Status, itemProgressStatusPreparing)
	} else if item.Progress != 0 {
		t.Fatalf("progress after synthetic pre-download progress = %v, want 0", item.Progress)
	}

	SetItemDownloading(itemID)
	if item := multiProgress.Items[itemID]; item == nil {
		t.Fatal("expected item progress entry to exist after downloading status")
	} else if item.Status != itemProgressStatusDownloading {
		t.Fatalf("status after download start = %q, want %q", item.Status, itemProgressStatusDownloading)
	}

	SetItemProgress(itemID, 0.37, 0, 0)
	if item := multiProgress.Items[itemID]; item == nil {
		t.Fatal("expected item progress entry to exist after real update")
	} else if item.Status != itemProgressStatusDownloading {
		t.Fatalf("status after real progress update = %q, want %q", item.Status, itemProgressStatusDownloading)
	} else if item.Progress != 0.37 {
		t.Fatalf("progress after real update = %v, want 0.37", item.Progress)
	}
}

func TestItemProgressPreparationStageIsObservable(t *testing.T) {
	ClearAllItemProgress()
	defer ClearAllItemProgress()

	itemID := "stage-item"
	StartItemProgress(itemID)
	SetItemPreparingStage(itemID, "resolving_metadata")

	var progress ItemProgress
	if err := json.Unmarshal([]byte(GetItemProgress(itemID)), &progress); err != nil {
		t.Fatalf("decode progress: %v", err)
	}
	if progress.Status != itemProgressStatusPreparing || progress.Stage != "resolving_metadata" {
		t.Fatalf("unexpected preparation progress: %#v", progress)
	}

	SetItemDownloading(itemID)
	progress = ItemProgress{}
	if err := json.Unmarshal([]byte(GetItemProgress(itemID)), &progress); err != nil {
		t.Fatalf("decode downloading progress: %v", err)
	}
	if progress.Stage != "" {
		t.Fatalf("download stage was not cleared: %#v", progress)
	}
}

func TestItemProgressFinalizingAndCompletedStatuses(t *testing.T) {
	const itemID = "progress-finalizing-item"
	RemoveItemProgress(itemID)
	defer RemoveItemProgress(itemID)

	StartItemProgress(itemID)
	SetItemFinalizing(itemID)

	if item := multiProgress.Items[itemID]; item == nil {
		t.Fatal("expected item progress entry to exist")
	} else if item.Status != itemProgressStatusFinalizing {
		t.Fatalf("status = %q, want %q", item.Status, itemProgressStatusFinalizing)
	}

	CompleteItemProgress(itemID)
	if item := multiProgress.Items[itemID]; item == nil {
		t.Fatal("expected item progress entry to exist after completion")
	} else if item.Status != itemProgressStatusCompleted {
		t.Fatalf("status = %q, want %q", item.Status, itemProgressStatusCompleted)
	}
}

func TestMultiProgressDeltaResetChangedAndRemoved(t *testing.T) {
	ClearAllItemProgress()
	defer ClearAllItemProgress()

	StartItemProgress("item-a")
	SetItemBytesTotal("item-a", 1000)

	var initial MultiProgressDelta
	if err := json.Unmarshal([]byte(GetMultiProgressDelta(0)), &initial); err != nil {
		t.Fatalf("initial delta parse failed: %v", err)
	}
	if !initial.Reset {
		t.Fatal("initial delta should reset")
	}
	if initial.Seq <= 0 {
		t.Fatalf("initial seq = %d, want > 0", initial.Seq)
	}
	if _, ok := initial.Items["item-a"]; !ok {
		t.Fatal("initial delta missing item-a")
	}

	if delta := GetMultiProgressDelta(initial.Seq); delta != "" {
		t.Fatalf("delta after same seq = %q, want empty", delta)
	}

	SetItemBytesReceivedWithSpeed("item-a", 256*1024, 2.5)
	var changed MultiProgressDelta
	if err := json.Unmarshal([]byte(GetMultiProgressDelta(initial.Seq)), &changed); err != nil {
		t.Fatalf("changed delta parse failed: %v", err)
	}
	if changed.Reset {
		t.Fatal("changed delta should not reset")
	}
	if _, ok := changed.Items["item-a"]; !ok {
		t.Fatal("changed delta missing item-a")
	}

	RemoveItemProgress("item-a")
	var removed MultiProgressDelta
	if err := json.Unmarshal([]byte(GetMultiProgressDelta(changed.Seq)), &removed); err != nil {
		t.Fatalf("removed delta parse failed: %v", err)
	}
	if len(removed.Removed) != 1 || removed.Removed[0] != "item-a" {
		t.Fatalf("removed = %#v, want item-a", removed.Removed)
	}
}
