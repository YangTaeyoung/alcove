//go:build !windows

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLogFolderIsCreatedForTheOwnerOnly(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "alcove")
	got, err := ownLogFolder(dir)
	if err != nil || got != dir {
		t.Fatalf("ownLogFolder = %q, %v", got, err)
	}
	if fi, err := os.Lstat(dir); err != nil || !fi.IsDir() || fi.Mode().Perm() != 0o700 {
		t.Fatalf("folder %v %v", fi.Mode(), err)
	}
}

func TestLogFolderOfOtherAccessIsNarrowed(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "alcove")
	if err := os.Mkdir(dir, 0o777); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o777); err != nil {
		t.Fatal(err)
	}
	if _, err := ownLogFolder(dir); err != nil {
		t.Fatal(err)
	}
	if fi, _ := os.Lstat(dir); fi.Mode().Perm() != 0o700 {
		t.Fatalf("mode %v", fi.Mode())
	}
}

func TestLogFolderThatIsALinkIsRefused(t *testing.T) {
	base := t.TempDir()
	real := filepath.Join(base, "real")
	if err := os.Mkdir(real, 0o700); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(base, "alcove")
	if err := os.Symlink(real, dir); err != nil {
		t.Fatal(err)
	}
	_, err := ownLogFolder(dir)
	want := dir + " is not a plain folder owned by this user; remove it and run alcove-agent --install again"
	if err == nil || err.Error() != want {
		t.Fatalf("err %v", err)
	}
}

func TestDataFolderLiesOutsideTheTemporaryFolder(t *testing.T) {
	if strings.HasPrefix(installLogFolder, os.TempDir()) || installLogFolder != "/var/log/alcove" {
		t.Fatalf("install log folder %q", installLogFolder)
	}
}
