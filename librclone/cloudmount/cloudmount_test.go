package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

type failingReader struct{ read bool }

func (reader *failingReader) Read(buffer []byte) (int, error) {
	if reader.read {
		return 0, errors.New("forced read failure")
	}
	reader.read = true
	return copy(buffer, "partial"), nil
}
func (reader *failingReader) Close() error { return nil }

func fixture(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "folder"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "root.txt"), []byte("root fixture\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "folder", "nested.txt"), []byte("nested fixture\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return root
}
func findItem(t *testing.T, response bridgeResponse, name string) itemMetadata {
	t.Helper()
	if !response.OK {
		t.Fatalf("operation failed: %+v", response.Error)
	}
	for _, item := range response.Items {
		if item.Filename == name {
			return item
		}
	}
	t.Fatalf("item %q not found", name)
	return itemMetadata{}
}
func TestListRootAndNested(t *testing.T) {
	root := fixture(t)
	rootList := list(context.Background(), root, "")
	if findItem(t, rootList, "root.txt").IsDirectory {
		t.Fatal("file classified as directory")
	}
	if !findItem(t, rootList, "folder").IsDirectory {
		t.Fatal("directory classified as file")
	}
	nested := list(context.Background(), root, "folder")
	if got := findItem(t, nested, "nested.txt").Path; got != "folder/nested.txt" {
		t.Fatalf("path = %q", got)
	}
}
func TestStatFileAndDirectory(t *testing.T) {
	root := fixture(t)
	file := stat(context.Background(), root, "folder/nested.txt", false)
	if !file.OK || file.Item == nil || file.Item.IsDirectory {
		t.Fatalf("file stat = %+v", file)
	}
	directory := stat(context.Background(), root, "folder", true)
	if !directory.OK || directory.Item == nil || !directory.Item.IsDirectory {
		t.Fatalf("directory stat = %+v", directory)
	}
}
func TestFetchFDAndMissing(t *testing.T) {
	root := fixture(t)
	destination, err := os.CreateTemp(t.TempDir(), "output")
	if err != nil {
		t.Fatal(err)
	}
	defer destination.Close()
	response := fetchFD(context.Background(), root, "folder/nested.txt", int(destination.Fd()))
	if !response.OK {
		t.Fatalf("fetch failed: %+v", response.Error)
	}
	if _, err := destination.Seek(0, io.SeekStart); err != nil {
		t.Fatalf("caller descriptor was closed: %v", err)
	}
	got, err := io.ReadAll(destination)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "nested fixture\n" {
		t.Fatalf("content = %q", got)
	}
	missing := fetchFD(context.Background(), root, "missing.txt", int(destination.Fd()))
	if missing.OK || missing.Error == nil || missing.Error.Code != "not_found" {
		t.Fatalf("missing = %+v", missing)
	}
}

func TestDuplicateClosedAfterFailure(t *testing.T) {
	destination, err := os.CreateTemp(t.TempDir(), "incomplete")
	if err != nil {
		t.Fatal(err)
	}
	defer destination.Close()
	captured := -1
	duplicate := func(fd int) (int, error) { value, err := unix.Dup(fd); captured = value; return value, err }
	_, err = copyToDescriptor(context.Background(), io.ReadCloser(&failingReader{}), int(destination.Fd()), duplicate)
	if err == nil {
		t.Fatal("expected forced read failure")
	}
	if _, err := unix.FcntlInt(uintptr(captured), unix.F_GETFD, 0); !errors.Is(err, unix.EBADF) {
		t.Fatalf("duplicated descriptor remains open: %v", err)
	}
	if _, err := destination.Seek(0, io.SeekStart); err != nil {
		t.Fatalf("caller descriptor was closed: %v", err)
	}
}

func rangeFixture(t *testing.T) (string, []byte) {
	t.Helper()
	data := make([]byte, 16384)
	for index := range data {
		data[index] = byte(index % 251)
	}
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "range.bin"), data, 0o644); err != nil {
		t.Fatal(err)
	}
	return root, data
}

func fetchTestRange(t *testing.T, root string, offset, length int64) (*os.File, bridgeResponse) {
	t.Helper()
	destination, err := os.CreateTemp(t.TempDir(), "range-output")
	if err != nil {
		t.Fatal(err)
	}
	response := fetchRangeFD(context.Background(), root, "range.bin", int(destination.Fd()), offset, length)
	return destination, response
}

func assertRange(t *testing.T, offset, length int64) {
	t.Helper()
	root, data := rangeFixture(t)
	destination, response := fetchTestRange(t, root, offset, length)
	defer destination.Close()
	if !response.OK {
		t.Fatalf("range fetch failed: %+v", response.Error)
	}
	info, err := destination.Stat()
	if err != nil {
		t.Fatal(err)
	}
	if info.Size() != offset+length {
		t.Fatalf("logical size = %d", info.Size())
	}
	got := make([]byte, length)
	if _, err := destination.ReadAt(got, offset); err != nil {
		t.Fatal(err)
	}
	if string(got) != string(data[offset:offset+length]) {
		t.Fatal("range bytes differ")
	}
	if _, err := destination.Seek(0, io.SeekStart); err != nil {
		t.Fatalf("caller descriptor closed: %v", err)
	}
}

func TestFetchRangeBeginningMiddleAndEnd(t *testing.T) {
	for _, test := range []struct{ offset, length int64 }{{0, 1024}, {4096, 4096}, {12000, 512}, {15360, 1024}} {
		t.Run(fmt.Sprintf("%d-%d", test.offset, test.length), func(t *testing.T) { assertRange(t, test.offset, test.length) })
	}
}

func TestFetchRangeInvalid(t *testing.T) {
	root, _ := rangeFixture(t)
	for _, test := range []struct{ offset, length int64 }{{-1, 1}, {0, 0}, {16384, 1}, {16380, 8}, {1, int64(^uint64(0) >> 1)}} {
		destination, response := fetchTestRange(t, root, test.offset, test.length)
		destination.Close()
		if response.OK || response.Error == nil || response.Error.Code != "invalid_range" {
			t.Fatalf("range %d,%d = %+v", test.offset, test.length, response)
		}
	}
}

func TestConcurrentIndependentRanges(t *testing.T) {
	var wait sync.WaitGroup
	for _, offset := range []int64{1024, 8192} {
		wait.Add(1)
		go func(offset int64) { defer wait.Done(); assertRange(t, offset, 2048) }(offset)
	}
	wait.Wait()
}

type blockingReadCloser struct {
	closed chan struct{}
	once   sync.Once
}

func (reader *blockingReadCloser) Read([]byte) (int, error) {
	<-reader.closed
	return 0, context.Canceled
}
func (reader *blockingReadCloser) Close() error {
	reader.once.Do(func() { close(reader.closed) })
	return nil
}

func TestTransferCancellationClosesSource(t *testing.T) {
	registry := newTransferRegistry()
	id := registry.create()
	ctx, ok := registry.context(id)
	if !ok {
		t.Fatal("missing transfer")
	}
	reader := &blockingReadCloser{closed: make(chan struct{})}
	destination, err := os.CreateTemp(t.TempDir(), "cancel")
	if err != nil {
		t.Fatal(err)
	}
	defer destination.Close()
	baseline := runtime.NumGoroutine()
	result := make(chan error, 1)
	go func() { _, err := copyToDescriptor(ctx, reader, int(destination.Fd()), unix.Dup); result <- err }()
	registry.cancel(id)
	select {
	case err := <-result:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("error = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("cancelled copy did not return")
	}
	if !registry.release(id) || registry.count() != 0 {
		t.Fatal("transfer was not released")
	}
	time.Sleep(10 * time.Millisecond)
	if runtime.NumGoroutine() > baseline+1 {
		t.Fatalf("possible goroutine leak: before=%d after=%d", baseline, runtime.NumGoroutine())
	}
}

func TestCancelBeforeFetch(t *testing.T) {
	registry := newTransferRegistry()
	id := registry.create()
	registry.cancel(id)
	ctx, ok := registry.context(id)
	if !ok {
		t.Fatal("missing cancelled transfer")
	}
	reader := &blockingReadCloser{closed: make(chan struct{})}
	destination, err := os.CreateTemp(t.TempDir(), "cancel-before")
	if err != nil {
		t.Fatal(err)
	}
	defer destination.Close()
	_, err = copyToDescriptor(ctx, reader, int(destination.Fd()), unix.Dup)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("error = %v", err)
	}
	registry.release(id)
}

func TestShortRangeRead(t *testing.T) {
	destination, err := os.CreateTemp(t.TempDir(), "short")
	if err != nil {
		t.Fatal(err)
	}
	defer destination.Close()
	_, err = copyRangeToDescriptor(context.Background(), io.NopCloser(strings.NewReader("short")), int(destination.Fd()), 10, 20, unix.Dup)
	if !errors.Is(err, errShortRangeRead) {
		t.Fatalf("error = %v", err)
	}
}
