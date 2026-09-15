package main

/* #include <stdlib.h> */
import "C"

import (
	"context"
	"fmt"
	"sync"
	"unsafe"

	_ "github.com/rclone/rclone/backend/all"
	_ "github.com/rclone/rclone/lib/plugin"
	"github.com/rclone/rclone/librclone/librclone"
)

var initializeOnce sync.Once

func initialize() { initializeOnce.Do(librclone.Initialize) }
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
func main()                                    {}
