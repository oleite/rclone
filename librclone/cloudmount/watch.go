package main

import (
	"context"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/rclone/rclone/fs"
)

type watchEvent struct {
	Path        string `json:"path,omitempty"`
	IsDirectory bool   `json:"isDirectory"`
	Rescan      bool   `json:"rescan"`
}

type watchResponse struct {
	OK        bool         `json:"ok"`
	Supported bool         `json:"supported"`
	Handle    uint64       `json:"handle,omitempty"`
	Event     *watchEvent  `json:"event,omitempty"`
	Error     *bridgeError `json:"error,omitempty"`
	Received  uint64       `json:"received"`
}

type changeWatch struct {
	ctx      context.Context
	cancel   context.CancelFunc
	interval chan time.Duration
	events   chan watchEvent
	overflow chan struct{}
	once     sync.Once
	received atomic.Uint64
}

type watchRegistry struct {
	mu      sync.Mutex
	nextID  uint64
	watches map[uint64]*changeWatch
	resolve func(context.Context, string) (fs.Fs, error)
}

func newWatchRegistry(resolve func(context.Context, string) (fs.Fs, error)) *watchRegistry {
	return &watchRegistry{watches: make(map[uint64]*changeWatch), resolve: resolve}
}

func watchFailure(code string) watchResponse {
	return watchResponse{Error: &bridgeError{Code: code, Message: "backend change watch unavailable"}}
}

func (registry *watchRegistry) start(ctx context.Context, remote string, interval time.Duration) (result watchResponse) {
	if interval <= 0 {
		return watchFailure("invalid_interval")
	}
	f, err := registry.resolve(ctx, remote)
	if err != nil {
		return watchFailure(errorCode(err))
	}
	if f.Features() == nil || f.Features().ChangeNotify == nil {
		return watchResponse{OK: true}
	}
	watchCtx, cancel := context.WithCancel(ctx)
	watch := &changeWatch{ctx: watchCtx, cancel: cancel, interval: make(chan time.Duration, 1),
		events: make(chan watchEvent, 128), overflow: make(chan struct{}, 1)}
	watch.interval <- interval
	registry.mu.Lock()
	registry.nextID++
	if registry.nextID == 0 {
		registry.nextID++
	}
	id := registry.nextID
	registry.watches[id] = watch
	registry.mu.Unlock()
	defer func() {
		if recover() != nil {
			registry.stop(id)
			result = watchFailure("backend_error")
		}
	}()
	f.Features().ChangeNotify(watchCtx, func(path string, kind fs.EntryType) {
		if watchCtx.Err() != nil {
			return
		}
		watch.received.Add(1)
		event := watchEvent{Path: path, IsDirectory: kind == fs.EntryDirectory}
		if kind != fs.EntryDirectory && kind != fs.EntryObject {
			event = watchEvent{Rescan: true}
		}
		select {
		case watch.events <- event:
		default:
			// A bounded queue may collapse hints, never silently lose the need to rescan.
			select {
			case watch.overflow <- struct{}{}:
			default:
			}
		}
	}, watch.interval)
	return watchResponse{OK: true, Supported: true, Handle: id}
}

func (registry *watchRegistry) next(id uint64, timeout time.Duration) watchResponse {
	registry.mu.Lock()
	watch := registry.watches[id]
	registry.mu.Unlock()
	if watch == nil {
		return watchFailure("invalid_watch")
	}
	if watch.ctx.Err() != nil {
		return watchFailure("cancelled")
	}
	reply := func(event *watchEvent) watchResponse {
		return watchResponse{OK: true, Event: event, Received: watch.received.Load()}
	}
	// Prioritize overflow so a busy queue cannot starve its catch-up marker.
	select {
	case <-watch.overflow:
		return reply(&watchEvent{Rescan: true})
	default:
	}
	if timeout <= 0 {
		select {
		case event := <-watch.events:
			return reply(&event)
		default:
			return reply(nil)
		}
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-watch.ctx.Done():
		return watchFailure("cancelled")
	case <-watch.overflow:
		return reply(&watchEvent{Rescan: true})
	case event := <-watch.events:
		return reply(&event)
	case <-timer.C:
		return reply(nil)
	}
}

func (registry *watchRegistry) stop(id uint64) {
	registry.mu.Lock()
	watch := registry.watches[id]
	delete(registry.watches, id)
	registry.mu.Unlock()
	if watch != nil {
		watch.once.Do(func() { watch.cancel(); close(watch.interval) })
	}
}

// Backend diagnostics can contain selectors, filenames and Graph tokens. The
// Agent publishes useful sanitized operation outcomes; this sink keeps only severity.
type redactedBackendHandler struct{ destination slog.Handler }

func (handler redactedBackendHandler) Enabled(ctx context.Context, level slog.Level) bool {
	return handler.destination.Enabled(ctx, level)
}
func (handler redactedBackendHandler) Handle(ctx context.Context, record slog.Record) error {
	return handler.destination.Handle(ctx, slog.NewRecord(record.Time, record.Level, "rclone backend diagnostic (details withheld)", 0))
}
func (handler redactedBackendHandler) WithAttrs([]slog.Attr) slog.Handler { return handler }
func (handler redactedBackendHandler) WithGroup(string) slog.Handler      { return handler }

var cloudMountWatches = newWatchRegistry(getFs)
