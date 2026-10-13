package main

import (
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rclone/rclone/fs"
	"github.com/rclone/rclone/fstest/mockfs"
)

func TestWatchUnsupportedAndResolutionFailure(t *testing.T) {
	registry := newWatchRegistry(getFs)
	result := registry.start(context.Background(), t.TempDir(), time.Second)
	if !result.OK || result.Supported || result.Handle != 0 {
		t.Fatalf("unsupported = %+v", result)
	}
	registry = newWatchRegistry(func(context.Context, string) (fs.Fs, error) { return nil, fmt.Errorf("private-selector-and-token") })
	result = registry.start(context.Background(), "private:", time.Second)
	if result.OK || result.Error == nil || strings.Contains(result.Error.Message, "private") {
		t.Fatal("watch startup failed to sanitize backend error")
	}
}

func TestWatchDeliveryOverflowStopAndConcurrency(t *testing.T) {
	backend, err := mockfs.NewFs(context.Background(), "fixture", "", nil)
	if err != nil {
		t.Fatal(err)
	}
	callbacks := make(chan func(string, fs.EntryType), 4)
	intervals := make(chan time.Duration, 4)
	ended := make(chan struct{}, 4)
	backend.Features().ChangeNotify = func(ctx context.Context, notify func(string, fs.EntryType), interval <-chan time.Duration) {
		callbacks <- notify
		go func() {
			defer func() { ended <- struct{}{} }()
			for {
				select {
				case value, open := <-interval:
					if !open {
						return
					}
					intervals <- value
				case <-ctx.Done():
					return
				}
			}
		}()
	}
	registry := newWatchRegistry(func(context.Context, string) (fs.Fs, error) { return backend, nil })
	a := registry.start(context.Background(), "a:", time.Second)
	b := registry.start(context.Background(), "b:", time.Second)
	if !a.OK || !a.Supported || a.Handle == 0 || a.Handle == b.Handle {
		t.Fatal("watch handles not independent")
	}
	first := <-callbacks
	second := <-callbacks
	for range 2 {
		if value := <-intervals; value != time.Second {
			t.Fatal("initial interval lost")
		}
	}
	first("dir/file.txt", fs.EntryObject)
	value := registry.next(a.Handle, time.Second)
	if !value.OK || value.Event == nil || value.Event.Path != "dir/file.txt" || value.Event.IsDirectory {
		t.Fatalf("event = %+v", value)
	}
	second("folder", fs.EntryDirectory)
	value = registry.next(b.Handle, time.Second)
	if !value.OK || value.Event == nil || !value.Event.IsDirectory {
		t.Fatal("directory event crossed watches")
	}
	for i := range 1_000 {
		first(fmt.Sprintf("item-%d", i), fs.EntryObject)
	}
	value = registry.next(a.Handle, time.Second)
	if value.Event == nil || !value.Event.Rescan {
		t.Fatal("overflow silently lost notifications")
	}
	if value.Received != 1001 {
		t.Fatal("raw hint count lost during queue overflow")
	}
	// Drain old hints before proving a blocked consumer is woken by Stop.
	for registry.next(a.Handle, 0).Event != nil {
	}
	started := make(chan struct{})
	done := make(chan watchResponse, 1)
	go func() { close(started); done <- registry.next(a.Handle, 30*time.Second) }()
	<-started
	registry.stop(a.Handle)
	registry.stop(a.Handle)
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("blocked Next not unblocked by Stop")
	}
	first("late", fs.EntryObject)
	if registry.next(a.Handle, 0).OK {
		t.Fatal("released handle remains accessible")
	}
	second("still-alive", fs.EntryObject)
	if registry.next(b.Handle, time.Second).Event == nil {
		t.Fatal("stopping A killed B")
	}
	registry.stop(b.Handle)
	for range 2 {
		select {
		case <-ended:
		case <-time.After(time.Second):
			t.Fatal("backend did not stop")
		}
	}
	registry.mu.Lock()
	count := len(registry.watches)
	registry.mu.Unlock()
	if count != 0 {
		t.Fatal("watch handle leak")
	}
}

func TestConcurrentWatchNextStop(t *testing.T) {
	backend, _ := mockfs.NewFs(context.Background(), "fixture", "", nil)
	backend.Features().ChangeNotify = func(ctx context.Context, notify func(string, fs.EntryType), interval <-chan time.Duration) {
		go func() {
			for {
				select {
				case _, ok := <-interval:
					if !ok {
						return
					}
					notify("fixture", fs.EntryObject)
				case <-ctx.Done():
					return
				}
			}
		}()
	}
	registry := newWatchRegistry(func(context.Context, string) (fs.Fs, error) { return backend, nil })
	var workers sync.WaitGroup
	for range 16 {
		workers.Add(1)
		go func() {
			defer workers.Done()
			value := registry.start(context.Background(), "fixture:", time.Second)
			_ = registry.next(value.Handle, time.Second)
			registry.stop(value.Handle)
		}()
	}
	workers.Wait()
}

func TestEmbeddedBackendLogsDoNotExposeSecrets(t *testing.T) {
	var output bytes.Buffer
	handler := redactedBackendHandler{destination: slog.NewTextHandler(&output, nil)}
	logger := slog.New(handler).With("selector", "secret:").WithGroup("credentials")
	logger.Error("delta-token-secret", "object", "private-host/path", "token", "secret-token")
	text := output.String()
	for _, secret := range []string{"delta-token", "secret:", "private-host", "secret-token", "credentials"} {
		if strings.Contains(text, secret) {
			t.Fatal("backend diagnostic leaked private data")
		}
	}
	if !strings.Contains(text, "ERROR") {
		t.Fatal("diagnostic severity lost")
	}
}
