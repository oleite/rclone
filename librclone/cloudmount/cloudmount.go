package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"strings"
	"sync"
	"time"

	"github.com/rclone/rclone/fs"
	"github.com/rclone/rclone/fs/cache"
	"golang.org/x/sys/unix"
)

var (
	errInvalidRange    = errors.New("invalid range")
	errShortRangeRead  = errors.New("short range read")
	errInvalidTransfer = errors.New("invalid transfer handle")
)

type bridgeError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}
type itemMetadata struct {
	Path             string `json:"path"`
	Filename         string `json:"filename"`
	IsDirectory      bool   `json:"isDirectory"`
	Size             *int64 `json:"size,omitempty"`
	ModificationTime string `json:"modificationTime,omitempty"`
	BackendID        string `json:"backendID,omitempty"`
	Version          string `json:"version"`
}
type bridgeResponse struct {
	OK    bool           `json:"ok"`
	Items []itemMetadata `json:"items,omitempty"`
	Item  *itemMetadata  `json:"item,omitempty"`
	Error *bridgeError   `json:"error,omitempty"`
}

func errorCode(err error) string {
	switch {
	case errors.Is(err, context.Canceled):
		return "cancelled"
	case errors.Is(err, errInvalidRange):
		return "invalid_range"
	case errors.Is(err, errShortRangeRead):
		return "short_range_read"
	case errors.Is(err, errInvalidTransfer):
		return "invalid_transfer"
	case errors.Is(err, fs.ErrorObjectNotFound), errors.Is(err, fs.ErrorDirNotFound):
		return "not_found"
	case errors.Is(err, fs.ErrorPermissionDenied):
		return "permission_denied"
	default:
		return "backend_error"
	}
}
func failure(err error) bridgeResponse {
	return bridgeResponse{Error: &bridgeError{Code: errorCode(err), Message: err.Error()}}
}
func backendID(entry fs.DirEntry) string {
	if v, ok := entry.(interface{ ID() string }); ok {
		return v.ID()
	}
	return ""
}

func metadata(ctx context.Context, entry fs.DirEntry, isDirectory bool) itemMetadata {
	remotePath := entry.Remote()
	item := itemMetadata{Path: remotePath, Filename: path.Base(remotePath), IsDirectory: isDirectory, BackendID: backendID(entry)}
	modTime := entry.ModTime(ctx)
	if !modTime.IsZero() {
		item.ModificationTime = modTime.UTC().Format(time.RFC3339Nano)
	}
	if object, ok := entry.(fs.Object); ok {
		size := object.Size()
		if size >= 0 {
			item.Size = &size
		}
	}
	input := fmt.Sprintf("%t\x00%s\x00%s\x00%s", isDirectory, item.Path, item.ModificationTime, item.BackendID)
	if item.Size != nil {
		input += fmt.Sprintf("\x00%d", *item.Size)
	}
	sum := sha256.Sum256([]byte(input))
	item.Version = hex.EncodeToString(sum[:])
	return item
}
func getFs(ctx context.Context, remote string) (fs.Fs, error) {
	if strings.TrimSpace(remote) == "" {
		return nil, errors.New("remote is empty")
	}
	return cache.Get(ctx, remote)
}

func list(ctx context.Context, remote, directory string) bridgeResponse {
	f, err := getFs(ctx, remote)
	if err != nil {
		return failure(err)
	}
	entries, err := f.List(ctx, directory)
	if err != nil {
		return failure(err)
	}
	items := make([]itemMetadata, 0, len(entries))
	for _, entry := range entries {
		switch entry.(type) {
		case fs.Object:
			items = append(items, metadata(ctx, entry, false))
		case fs.Directory:
			items = append(items, metadata(ctx, entry, true))
		default:
			return failure(fmt.Errorf("unexpected directory entry type %T", entry))
		}
	}
	return bridgeResponse{OK: true, Items: items}
}

func stat(ctx context.Context, remote, remotePath string, isDirectory bool) bridgeResponse {
	f, err := getFs(ctx, remote)
	if err != nil {
		return failure(err)
	}
	if !isDirectory {
		object, err := f.NewObject(ctx, remotePath)
		if err != nil {
			return failure(err)
		}
		item := metadata(ctx, object, false)
		return bridgeResponse{OK: true, Item: &item}
	}
	clean := strings.Trim(remotePath, "/")
	if clean == "" {
		return failure(fs.ErrorDirNotFound)
	}
	parent := path.Dir(clean)
	if parent == "." {
		parent = ""
	}
	entries, err := f.List(ctx, parent)
	if err != nil {
		return failure(err)
	}
	for _, entry := range entries {
		if entry.Remote() == clean {
			if directory, ok := entry.(fs.Directory); ok {
				item := metadata(ctx, directory, true)
				return bridgeResponse{OK: true, Item: &item}
			}
			return failure(fs.ErrorDirNotFound)
		}
	}
	return failure(fs.ErrorDirNotFound)
}

func fetchFD(ctx context.Context, remote, remotePath string, descriptor int) bridgeResponse {
	f, err := getFs(ctx, remote)
	if err != nil {
		return failure(err)
	}
	object, err := f.NewObject(ctx, remotePath)
	if err != nil {
		return failure(err)
	}
	source, err := object.Open(ctx)
	if err != nil {
		return failure(err)
	}
	if _, err := copyToDescriptor(ctx, source, descriptor, unix.Dup); err != nil {
		return failure(err)
	}
	return bridgeResponse{OK: true}
}

func fetchRangeFD(ctx context.Context, remote, remotePath string, descriptor int, offset, length int64) bridgeResponse {
	f, err := getFs(ctx, remote)
	if err != nil {
		return failure(err)
	}
	object, err := f.NewObject(ctx, remotePath)
	if err != nil {
		return failure(err)
	}
	size := object.Size()
	if offset < 0 || length <= 0 || size < 0 || offset >= size || length > size-offset {
		return failure(errInvalidRange)
	}
	end := offset + length - 1
	source, err := object.Open(ctx, &fs.RangeOption{Start: offset, End: end})
	if err != nil {
		return failure(err)
	}
	if _, err := copyRangeToDescriptor(ctx, source, descriptor, offset, length, unix.Dup); err != nil {
		return failure(err)
	}
	return bridgeResponse{OK: true}
}

type onceReadCloser struct {
	source io.ReadCloser
	once   sync.Once
}

func (source *onceReadCloser) Read(buffer []byte) (int, error) { return source.source.Read(buffer) }
func (source *onceReadCloser) Close() error {
	var err error
	source.once.Do(func() { err = source.source.Close() })
	return err
}

func copyWithCancellation(ctx context.Context, destination io.Writer, source io.ReadCloser, length *int64) error {
	closer := &onceReadCloser{source: source}
	done := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			_ = closer.Close()
		case <-done:
		}
	}()
	var copyErr error
	if length == nil {
		_, copyErr = io.Copy(destination, closer)
	} else {
		written, err := io.CopyN(destination, closer, *length)
		if err != nil || written != *length {
			copyErr = errShortRangeRead
		}
	}
	close(done)
	closeErr := closer.Close()
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if copyErr != nil {
		return copyErr
	}
	return closeErr
}

func duplicateDestination(descriptor int, duplicate func(int) (int, error)) (int, *os.File, error) {
	duplicateDescriptor, err := duplicate(descriptor)
	if err != nil {
		return -1, nil, err
	}
	destination := os.NewFile(uintptr(duplicateDescriptor), "rclone-cloudmount-destination")
	if destination == nil {
		_ = unix.Close(duplicateDescriptor)
		return duplicateDescriptor, nil, errors.New("failed to wrap duplicated destination descriptor")
	}
	return duplicateDescriptor, destination, nil
}

func copyToDescriptor(ctx context.Context, source io.ReadCloser, descriptor int, duplicate func(int) (int, error)) (duplicateDescriptor int, result error) {
	duplicateDescriptor, destination, err := duplicateDestination(descriptor, duplicate)
	if err != nil {
		_ = source.Close()
		return duplicateDescriptor, err
	}
	defer destination.Close()
	if err := destination.Truncate(0); err != nil {
		_ = source.Close()
		return duplicateDescriptor, err
	}
	if _, err := destination.Seek(0, io.SeekStart); err != nil {
		_ = source.Close()
		return duplicateDescriptor, err
	}
	if err := copyWithCancellation(ctx, destination, source, nil); err != nil {
		return duplicateDescriptor, err
	}
	if err := destination.Sync(); err != nil {
		return duplicateDescriptor, err
	}
	return duplicateDescriptor, nil
}

func copyRangeToDescriptor(ctx context.Context, source io.ReadCloser, descriptor int, offset, length int64, duplicate func(int) (int, error)) (duplicateDescriptor int, result error) {
	duplicateDescriptor, destination, err := duplicateDestination(descriptor, duplicate)
	if err != nil {
		_ = source.Close()
		return duplicateDescriptor, err
	}
	defer destination.Close()
	// File Provider partial temp files preserve source offsets but end at the
	// retrieved range; fileproviderd rejects a trailing hole to the source EOF.
	if err := destination.Truncate(offset + length); err != nil {
		_ = source.Close()
		return duplicateDescriptor, err
	}
	if _, err := destination.Seek(offset, io.SeekStart); err != nil {
		_ = source.Close()
		return duplicateDescriptor, err
	}
	if err := copyWithCancellation(ctx, destination, source, &length); err != nil {
		return duplicateDescriptor, err
	}
	if err := destination.Sync(); err != nil {
		return duplicateDescriptor, err
	}
	return duplicateDescriptor, nil
}
func encodeResponse(response bridgeResponse) string {
	data, err := json.Marshal(response)
	if err != nil {
		return `{"ok":false,"error":{"code":"internal_error","message":"failed to encode response"}}`
	}
	return string(data)
}
