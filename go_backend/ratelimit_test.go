package gobackend

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

func TestRateLimiterRechecksCapacityAfterConcurrentWait(t *testing.T) {
	const (
		waiters = 4
		window  = 25 * time.Millisecond
	)
	limiter := NewRateLimiter(1, window)
	if !limiter.TryAcquire() {
		t.Fatal("failed to consume initial slot")
	}

	started := make(chan struct{})
	admitted := make(chan time.Time, waiters)
	var ready sync.WaitGroup
	ready.Add(waiters)
	for i := 0; i < waiters; i++ {
		go func() {
			ready.Done()
			<-started
			limiter.WaitForSlot()
			admitted <- time.Now()
		}()
	}
	ready.Wait()
	start := time.Now()
	close(started)

	previous := start
	for i := 0; i < waiters; i++ {
		select {
		case admittedAt := <-admitted:
			if gap := admittedAt.Sub(previous); gap < window/2 {
				t.Fatalf("waiters %d and %d admitted only %v apart", i, i+1, gap)
			}
			previous = admittedAt
		case <-time.After(time.Second):
			t.Fatal("timed out waiting for rate-limiter admission")
		}
	}
}

func TestRateLimiterWaitCanBeCancelled(t *testing.T) {
	limiter := NewRateLimiter(1, time.Hour)
	if !limiter.TryAcquire() {
		t.Fatal("failed to consume initial slot")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	startedAt := time.Now()
	err := limiter.WaitForSlotContext(ctx)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("WaitForSlotContext error = %v, want context.Canceled", err)
	}
	if elapsed := time.Since(startedAt); elapsed > 100*time.Millisecond {
		t.Fatalf("cancelled wait took %v", elapsed)
	}
}
