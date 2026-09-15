package main

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"testing"
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
func TestFetchAndMissing(t *testing.T) {
	root := fixture(t)
	destination := filepath.Join(t.TempDir(), "output")
	response := fetch(context.Background(), root, "folder/nested.txt", destination)
	if !response.OK {
		t.Fatalf("fetch failed: %+v", response.Error)
	}
	got, err := os.ReadFile(destination)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "nested fixture\n" {
		t.Fatalf("content = %q", got)
	}
	missing := fetch(context.Background(), root, "missing.txt", filepath.Join(t.TempDir(), "missing"))
	if missing.OK || missing.Error == nil || missing.Error.Code != "not_found" {
		t.Fatalf("missing = %+v", missing)
	}
}

func TestIncompleteDestinationRemoved(t *testing.T) {
	destination := filepath.Join(t.TempDir(), "incomplete")
	err := copyToDestination(io.ReadCloser(&failingReader{}), destination)
	if err == nil {
		t.Fatal("expected forced read failure")
	}
	if _, statErr := os.Stat(destination); !os.IsNotExist(statErr) {
		t.Fatalf("incomplete destination remains: %v", statErr)
	}
}
