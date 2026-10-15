//go:build !windows

package logfile

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCappedLogKeepsAcceptingWritesWhileTheFileCannotBeOpened(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "uia")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "helper.log")
	l, err := Open(path, 10, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	if _, err := l.Write([]byte("aaaaaa")); err != nil {
		t.Fatal(err)
	}
	if err := os.RemoveAll(dir); err != nil {
		t.Fatal(err)
	}
	for _, s := range []string{"bbbbbb", "cccccc"} {
		if n, err := l.Write([]byte(s)); n != len(s) || err != nil {
			t.Fatalf("Write(%q) without the folder returned %d, %v", s, n, err)
		}
	}
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if n, err := l.Write([]byte("dddddd")); n != 6 || err != nil {
		t.Fatalf("Write with the folder back returned %d, %v", n, err)
	}
	if got := string(readFile(t, path)); got != "dddddd" {
		t.Fatalf("file holds %q", got)
	}
}
