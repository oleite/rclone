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

//export RcloneCloudMountFetch
func RcloneCloudMountFetch(remote, remotePath, destinationPath *C.char) *C.char {
	return exported(func() bridgeResponse {
		return fetch(context.Background(), C.GoString(remote), C.GoString(remotePath), C.GoString(destinationPath))
	})
}

//export RcloneCloudMountFreeString
func RcloneCloudMountFreeString(value *C.char) { C.free(unsafe.Pointer(value)) }
func main()                                    {}
