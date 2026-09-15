package main

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"testing"

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
	_, err = copyToDescriptor(io.ReadCloser(&failingReader{}), int(destination.Fd()), duplicate)
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
