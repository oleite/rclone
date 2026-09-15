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
	"time"

	"github.com/rclone/rclone/fs"
	"github.com/rclone/rclone/fs/cache"
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

func fetch(ctx context.Context, remote, remotePath, destinationPath string) bridgeResponse {
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
	if err := copyToDestination(source, destinationPath); err != nil {
		return failure(err)
	}
	return bridgeResponse{OK: true}
}

func copyToDestination(source io.ReadCloser, destinationPath string) (result error) {
	sourceClosed := false
	defer func() {
		if !sourceClosed {
			_ = source.Close()
		}
		if result != nil {
			_ = os.Remove(destinationPath)
		}
	}()
	destination, err := os.Create(destinationPath)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(destination, source)
	sourceCloseErr := source.Close()
	sourceClosed = true
	destinationCloseErr := destination.Close()
	if copyErr != nil {
		return copyErr
	}
	if sourceCloseErr != nil {
		return sourceCloseErr
	}
	if destinationCloseErr != nil {
		return destinationCloseErr
	}
	return nil
}
func encodeResponse(response bridgeResponse) string {
	data, err := json.Marshal(response)
	if err != nil {
		return `{"ok":false,"error":{"code":"internal_error","message":"failed to encode response"}}`
	}
	return string(data)
}
