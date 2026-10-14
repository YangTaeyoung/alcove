//go:build !windows

package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

func TestTheSavedKeyFileIsReadableByItsOwnerOnly(t *testing.T) {
	old := syscall.Umask(0)
	defer syscall.Umask(old)
	dir := filepath.Join(t.TempDir(), "alcove")
	path := filepath.Join(dir, "host.key")
	s := fileKeyStore{path: path, prepare: func() error { return ownKeyFolder(dir) }}
	if err := s.Save(sampleKey); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode() != 0o600 {
		t.Fatalf("key file mode %v", fi.Mode())
	}
	di, err := os.Lstat(dir)
	if err != nil {
		t.Fatal(err)
	}
	if di.Mode().Perm() != 0o700 || !di.IsDir() {
		t.Fatalf("folder mode %v", di.Mode())
	}
}

func TestOwnKeyFolderNarrowsAnExistingFolder(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "alcove")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o777); err != nil {
		t.Fatal(err)
	}
	if err := ownKeyFolder(dir); err != nil {
		t.Fatal(err)
	}
	if fi, _ := os.Lstat(dir); fi.Mode().Perm() != 0o700 {
		t.Fatalf("folder mode %v", fi.Mode())
	}
}

func TestOwnKeyFolderRefusesALink(t *testing.T) {
	base := t.TempDir()
	target := filepath.Join(base, "elsewhere")
	if err := os.Mkdir(target, 0o755); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(base, "alcove")
	if err := os.Symlink(target, dir); err != nil {
		t.Fatal(err)
	}
	err := ownKeyFolder(dir)
	if err == nil || err.Error() != dir+" is not a folder of this user; remove it and connect again" {
		t.Fatalf("err %v", err)
	}
	if fi, _ := os.Stat(target); fi.Mode().Perm() != 0o755 {
		t.Fatalf("the link target was changed to %v", fi.Mode())
	}
}

func TestSaveDoesNotWriteThroughALink(t *testing.T) {
	base := t.TempDir()
	target := filepath.Join(base, "target")
	if err := os.WriteFile(target, []byte("keep"), 0o644); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(base, "host.key")
	if err := os.Symlink(target, path); err != nil {
		t.Fatal(err)
	}
	if err := (fileKeyStore{path: path}).Save(sampleKey); err == nil {
		t.Fatal("Save wrote through a link")
	}
	if got, _ := os.ReadFile(target); string(got) != "keep" {
		t.Fatalf("the link target holds %q", got)
	}
}

func TestLoadRefusesALinkAndAFileOthersCanRead(t *testing.T) {
	base := t.TempDir()
	good := filepath.Join(base, "good")
	if err := os.WriteFile(good, []byte(strings.Repeat("3c", 32)+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if key, err := (fileKeyStore{path: good}).Load(); err != nil || !bytes.Equal(key, sampleKey) {
		t.Fatalf("Load of a good file = %x, %v", key, err)
	}
	link := filepath.Join(base, "link")
	if err := os.Symlink(good, link); err != nil {
		t.Fatal(err)
	}
	readable := filepath.Join(base, "readable")
	if err := os.WriteFile(readable, []byte(strings.Repeat("3c", 32)+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(readable, 0o644); err != nil {
		t.Fatal(err)
	}
	folder := filepath.Join(base, "folder")
	if err := os.Mkdir(folder, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{link, readable, folder} {
		key, err := fileKeyStore{path: path}.Load()
		want := path + " is not a regular file of this user that only it can read; run alcove-agent --forget-host-key as an administrator and connect again"
		if key != nil || err == nil || err.Error() != want {
			t.Fatalf("%s: Load = %x, %v", path, key, err)
		}
	}
}
