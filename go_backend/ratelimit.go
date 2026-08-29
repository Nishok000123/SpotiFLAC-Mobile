package gobackend

import (
	"context"
	"sync"
	"time"
)

type RateLimiter struct {
	mu          sync.Mutex
	maxRequests int
	window      time.Duration
	timestamps  []time.Time
}

func NewRateLimiter(maxRequests int, window time.Duration) *RateLimiter {
	return &RateLimiter{
		maxRequests: maxRequests,
		window:      window,
		timestamps:  make([]time.Time, 0, maxRequests),
	}
}

func (r *RateLimiter) WaitForSlot() {
	_ = r.WaitForSlotContext(context.Background())

}

// WaitForSlotContext reserves exactly one slot, rechecking the window after
// every wake-up. Multiple waiters may wake together, but only the first one
// that reacquires the mutex can consume the newly available slot.
func (r *RateLimiter) WaitForSlotContext(ctx context.Context) error {
	if ctx == nil {
		ctx = context.Background()
	}
	for {
		r.mu.Lock()
		now := time.Now()
		r.cleanOldTimestamps(now)
		if len(r.timestamps) < r.maxRequests {
			r.timestamps = append(r.timestamps, now)
			r.mu.Unlock()
			return nil
		}

		waitDuration := r.timestamps[0].Add(r.window).Sub(now)
		r.mu.Unlock()
		if waitDuration <= 0 {
			continue
		}

		timer := time.NewTimer(waitDuration)
		select {
		case <-ctx.Done():
			if !timer.Stop() {
				<-timer.C
			}
			return ctx.Err()
		case <-timer.C:
		}
	}
}

func (r *RateLimiter) cleanOldTimestamps(now time.Time) {
	cutoff := now.Add(-r.window)
	validStart := 0

	for i, ts := range r.timestamps {
		if ts.After(cutoff) {
			validStart = i
			break
		}
		validStart = i + 1
	}

	if validStart > 0 {
		r.timestamps = r.timestamps[validStart:]
	}
}

func (r *RateLimiter) TryAcquire() bool {
	r.mu.Lock()
	defer r.mu.Unlock()

	now := time.Now()
	r.cleanOldTimestamps(now)

	if len(r.timestamps) < r.maxRequests {
		r.timestamps = append(r.timestamps, now)
		return true
	}

	return false
}

func (r *RateLimiter) Available() int {
	r.mu.Lock()
	defer r.mu.Unlock()

	r.cleanOldTimestamps(time.Now())
	return r.maxRequests - len(r.timestamps)
}

// Global SongLink rate limiter - 9 requests per minute (to be safe, limit is 10)
var songLinkRateLimiter = NewRateLimiter(9, time.Minute)
