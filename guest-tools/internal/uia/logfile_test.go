package uia

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func readFile(t *testing.T, path string) []byte {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestCappedLogAppendsToAnExistingFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "helper.log")
	if err := os.WriteFile(path, []byte("old\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	l, err := openCappedLog(path, 100)
	if err != nil {
		t.Fatal(err)
	}
	if n, err := l.Write([]byte("new\n")); n != 4 || err != nil {
		t.Fatalf("Write returned %d, %v", n, err)
	}
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	if got := string(readFile(t, path)); got != "old\nnew\n" {
		t.Fatalf("file holds %q", got)
	}
}

func TestCappedLogMovesAFullFileAside(t *testing.T) {
	path := filepath.Join(t.TempDir(), "helper.log")
	l, err := openCappedLog(path, 10)
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	for _, s := range []string{"aaaaaa", "bbbbbb", "cccc", "dddddd", "eeeeee"} {
		if n, err := l.Write([]byte(s)); n != len(s) || err != nil {
			t.Fatalf("Write(%q) returned %d, %v", s, n, err)
		}
		for _, p := range []string{path, path + ".1"} {
			if st, err := os.Stat(p); err == nil && st.Size() > 10 {
				t.Fatalf("%s has %d bytes after writing %q", filepath.Base(p), st.Size(), s)
			}
		}
	}
	if got := string(readFile(t, path)); got != "eeeeee" {
		t.Fatalf("current file holds %q", got)
	}
	if got := string(readFile(t, path+".1")); got != "dddddd" {
		t.Fatalf("previous file holds %q", got)
	}
}

func TestCappedLogKeepsTheEndOfAnOversizedWrite(t *testing.T) {
	path := filepath.Join(t.TempDir(), "helper.log")
	l, err := openCappedLog(path, 8)
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	if n, err := l.Write([]byte("0123456789abcdef")); n != 16 || err != nil {
		t.Fatalf("Write returned %d, %v", n, err)
	}
	if got := readFile(t, path); !bytes.Equal(got, []byte("89abcdef")) {
		t.Fatalf("file holds %q", got)
	}
}

func TestCappedLogStartsOverWhenTheFileCannotBeMoved(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "helper.log")
	if err := os.MkdirAll(filepath.Join(path+".1", "blocker"), 0o755); err != nil {
		t.Fatal(err)
	}
	l, err := openCappedLog(path, 10)
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	for _, s := range []string{"aaaaaa", "bbbbbb"} {
		if _, err := l.Write([]byte(s)); err != nil {
			t.Fatal(err)
		}
	}
	if got := string(readFile(t, path)); got != "bbbbbb" {
		t.Fatalf("file holds %q", got)
	}
}

func TestCappedLogWriteAfterCloseFails(t *testing.T) {
	l, err := openCappedLog(filepath.Join(t.TempDir(), "helper.log"), 10)
	if err != nil {
		t.Fatal(err)
	}
	l.Close()
	if _, err := l.Write([]byte("x")); err == nil {
		t.Fatal("Write after Close succeeded")
	}
}
