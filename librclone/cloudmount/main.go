package main

/* #include <stdlib.h> */
import "C"

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"sync"
	"time"
	"unsafe"

	_ "github.com/rclone/rclone/backend/all"
	"github.com/rclone/rclone/fs"
	_ "github.com/rclone/rclone/lib/plugin"
	"github.com/rclone/rclone/librclone/librclone"
)

var initializeOnce sync.Once

func initialize() {
	initializeOnce.Do(func() {
		librclone.Initialize()
		handler := redactedBackendHandler{destination: slog.NewTextHandler(os.Stderr, nil)}
		fs.SetLogger(handler)
		slog.SetDefault(slog.New(handler))
	})
}
func exported(operation func() bridgeResponse) (result *C.char) {
	defer func() {
		if recovered := recover(); recovered != nil {
			result = C.CString(encodeResponse(failure(fmt.Errorf("panic: %v", recovered))))
		}
	}()
	initialize()
	return C.CString(encodeResponse(operation()))
}

//export RcloneCloudMountList
func RcloneCloudMountList(remote, directory *C.char) *C.char {
	return exported(func() bridgeResponse { return list(context.Background(), C.GoString(remote), C.GoString(directory)) })
}

//export RcloneCloudMountStat
func RcloneCloudMountStat(remote, remotePath *C.char, isDirectory C.int) *C.char {
	return exported(func() bridgeResponse {
		return stat(context.Background(), C.GoString(remote), C.GoString(remotePath), isDirectory != 0)
	})
}

//export RcloneCloudMountTransferCreate
func RcloneCloudMountTransferCreate() C.ulonglong { return C.ulonglong(cloudMountTransfers.create()) }

//export RcloneCloudMountTransferCancel
func RcloneCloudMountTransferCancel(transfer C.ulonglong) {
	cloudMountTransfers.cancel(uint64(transfer))
}

//export RcloneCloudMountTransferRelease
func RcloneCloudMountTransferRelease(transfer C.ulonglong) {
	cloudMountTransfers.release(uint64(transfer))
}

// RcloneCloudMountFetchFD duplicates fd; Go owns and closes only the duplicate.
//
//export RcloneCloudMountFetchFD
func RcloneCloudMountFetchFD(remote, remotePath *C.char, fd C.int, transfer C.ulonglong) *C.char {
	return exported(func() bridgeResponse {
		ctx, ok := cloudMountTransfers.context(uint64(transfer))
		if !ok {
			return failure(errInvalidTransfer)
		}
		return fetchFD(ctx, C.GoString(remote), C.GoString(remotePath), int(fd))
	})
}

// RcloneCloudMountFetchRangeFD writes a sparse range at its original offset.
// Go duplicates fd and owns/closes only the duplicate.
//
//export RcloneCloudMountFetchRangeFD
func RcloneCloudMountFetchRangeFD(remote, remotePath *C.char, fd C.int, offset, length C.longlong, transfer C.ulonglong) *C.char {
	return exported(func() bridgeResponse {
		ctx, ok := cloudMountTransfers.context(uint64(transfer))
		if !ok {
			return failure(errInvalidTransfer)
		}
		return fetchRangeFD(ctx, C.GoString(remote), C.GoString(remotePath), int(fd), int64(offset), int64(length))
	})
}

//export RcloneCloudMountFreeString
func RcloneCloudMountFreeString(value *C.char) { C.free(unsafe.Pointer(value)) }

func watchExported(operation func() watchResponse) (result *C.char) {
	defer func() {
		if recover() != nil {
			result = C.CString(`{"ok":false,"error":{"code":"internal_error","message":"change watch unavailable"}}`)
		}
	}()
	initialize()
	data, err := json.Marshal(operation())
	if err != nil {
		return C.CString(`{"ok":false,"error":{"code":"internal_error","message":"change watch unavailable"}}`)
	}
	return C.CString(string(data))
}

// RcloneCloudMountWatchStart creates an Agent-private ChangeNotify handle.
//
//export RcloneCloudMountWatchStart
func RcloneCloudMountWatchStart(remote *C.char, intervalSeconds C.int) *C.char {
	return watchExported(func() watchResponse {
		if intervalSeconds < 1 || intervalSeconds > 3600 {
			return watchFailure("invalid_interval")
		}
		return cloudMountWatches.start(context.Background(), C.GoString(remote), time.Duration(intervalSeconds)*time.Second)
	})
}

// RcloneCloudMountWatchNext returns a private hint or a bounded timeout.
//
//export RcloneCloudMountWatchNext
func RcloneCloudMountWatchNext(handle C.ulonglong, timeoutMilliseconds C.int) *C.char {
	return watchExported(func() watchResponse {
		if timeoutMilliseconds < 0 || timeoutMilliseconds > 2000 {
			return watchFailure("invalid_timeout")
		}
		return cloudMountWatches.next(uint64(handle), time.Duration(timeoutMilliseconds)*time.Millisecond)
	})
}

// RcloneCloudMountWatchStop releases the handle and wakes blocked consumers.
//
//export RcloneCloudMountWatchStop
func RcloneCloudMountWatchStop(handle C.ulonglong) { cloudMountWatches.stop(uint64(handle)) }
func main()                                        {}
