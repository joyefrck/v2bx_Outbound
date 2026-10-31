package task

import (
	"log"
	"sync/atomic"
	"testing"
	"time"
)

func TestTask(t *testing.T) {
	ts := Task{Execute: func() error {
		log.Println("q")
		return nil
	}, Interval: time.Second}
	ts.Start(false)
}

func TestIntervalCanChangeInsideCallback(t *testing.T) {
	done := make(chan struct{}, 1)
	var ts Task
	ts.Interval = time.Hour
	ts.Execute = func() error {
		ts.SetInterval(time.Millisecond)
		select {
		case done <- struct{}{}:
		default:
		}
		return nil
	}
	ts.SetInterval(time.Millisecond)
	if err := ts.Start(false); err != nil {
		t.Fatal(err)
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("callback deadlocked while setting interval")
	}
	ts.Close()
}

func TestClosePreventsFurtherCallbacks(t *testing.T) {
	for range 10 {
		count := &atomic.Int64{}
		task := &Task{Interval: time.Microsecond, Execute: func() error { count.Add(1); return nil }}
		if err := task.Start(false); err != nil {
			t.Fatal(err)
		}
		time.Sleep(time.Millisecond)
		task.Close()
		stopped := count.Load()
		time.Sleep(time.Millisecond)
		if count.Load() != stopped {
			t.Fatal("task executed after Close returned")
		}
	}
}
