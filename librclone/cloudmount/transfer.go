package main

import (
	"context"
	"sync"
)

type transferState struct {
	context context.Context
	cancel  context.CancelFunc
}

type transferRegistry struct {
	mu        sync.Mutex
	next      uint64
	transfers map[uint64]transferState
}

func newTransferRegistry() *transferRegistry {
	return &transferRegistry{transfers: make(map[uint64]transferState)}
}

func (registry *transferRegistry) create() uint64 {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	registry.next++
	if registry.next == 0 {
		registry.next++
	}
	ctx, cancel := context.WithCancel(context.Background())
	registry.transfers[registry.next] = transferState{context: ctx, cancel: cancel}
	return registry.next
}

func (registry *transferRegistry) context(id uint64) (context.Context, bool) {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	transfer, ok := registry.transfers[id]
	return transfer.context, ok
}

func (registry *transferRegistry) cancel(id uint64) bool {
	registry.mu.Lock()
	transfer, ok := registry.transfers[id]
	registry.mu.Unlock()
	if ok {
		transfer.cancel()
	}
	return ok
}

func (registry *transferRegistry) release(id uint64) bool {
	registry.mu.Lock()
	transfer, ok := registry.transfers[id]
	if ok {
		delete(registry.transfers, id)
	}
	registry.mu.Unlock()
	if ok {
		transfer.cancel()
	}
	return ok
}

func (registry *transferRegistry) count() int {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	return len(registry.transfers)
}

var cloudMountTransfers = newTransferRegistry()
