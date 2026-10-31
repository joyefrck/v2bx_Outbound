package task

import (
	"sync"
	"sync/atomic"
	"time"
)

// Task is a task that runs periodically.
type Task struct {
	// Interval of the task being run
	Interval time.Duration
	// Execute is the task function
	Execute func() error

	access   sync.Mutex
	timer    *time.Timer
	running  bool
	interval atomic.Int64
}

func (t *Task) checkedExecute(first bool) error {
	t.access.Lock()
	defer t.access.Unlock()
	if !t.running {
		return nil
	}
	if first {
		if err := t.Execute(); err != nil {
			t.running = false
			return err
		}
	}
	if !t.running {
		return nil
	}
	delay := t.Interval
	if value := t.interval.Load(); value > 0 {
		delay = time.Duration(value)
	}
	t.timer = time.AfterFunc(delay, func() {
		t.checkedExecute(true)
	})

	return nil
}

func (t *Task) SetInterval(interval time.Duration) {
	if interval > 0 {
		t.interval.Store(int64(interval))
	}
}

// Start implements common.Runnable.
func (t *Task) Start(first bool) error {
	t.access.Lock()
	if t.running {
		t.access.Unlock()
		return nil
	}
	t.running = true
	t.access.Unlock()
	if err := t.checkedExecute(first); err != nil {
		t.access.Lock()
		t.running = false
		t.access.Unlock()
		return err
	}
	return nil
}

// Close implements common.Closable.
func (t *Task) Close() {
	t.access.Lock()
	defer t.access.Unlock()

	t.running = false
	if t.timer != nil {
		t.timer.Stop()
		t.timer = nil
	}
}
