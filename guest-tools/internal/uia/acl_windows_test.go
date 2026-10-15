//go:build windows

package uia

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

// fileID returns a directory's identity, so a rename-and-recreate is told from
// a change of access list on the same directory.
func fileID(t *testing.T, path string) uint64 {
	t.Helper()
	h, err := openDir(path)
	if err != nil {
		t.Fatalf("openDir %s: %v", path, err)
	}
	defer syscall.CloseHandle(h)
	var info syscall.ByHandleFileInformation
	if err := syscall.GetFileInformationByHandle(h, &info); err != nil {
		t.Fatalf("GetFileInformationByHandle %s: %v", path, err)
	}
	return uint64(info.FileIndexHigh)<<32 | uint64(info.FileIndexLow)
}

// Runs elevated: secureDir sets the owner to Administrators.
func TestSecureDirMovesAsideAFolderInsteadOfRelockingItWhileAHandleIsOpen(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "uia")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	before := fileID(t, dir)

	// The rights a standard user's pre-lock handle keeps: writing the DACL and
	// the attributes. If secureDir relocked in place, this handle would still
	// let its holder change the locked folder.
	held, err := openDir(dir)
	if err != nil {
		t.Fatalf("openDir: %v", err)
	}
	defer syscall.CloseHandle(held)

	moved, err := secureDir(dir, map[string]bool{"helper.log": true, "helper.log.1": true}, nil)
	if err != nil {
		t.Fatalf("secureDir: %v", err)
	}
	if moved == "" {
		t.Fatalf("the folder was not moved aside")
	}
	if filepath.Dir(moved) != filepath.Dir(dir) || fileID(t, moved) != before {
		t.Fatalf("moved aside to %s, which is not the original folder", moved)
	}
	if fileID(t, dir) == before {
		t.Fatalf("the folder was relocked in place; its identity did not change")
	}
	hh, have, err := openPlainDir(dir)
	if err != nil {
		t.Fatalf("openPlainDir after the lock: %v", err)
	}
	syscall.CloseHandle(hh)
	if !isLockedSDDL(have) {
		t.Fatalf("the new folder is not locked: %s", have)
	}
}

// Runs elevated.
func TestSecureDirKeepsAnAlreadyLockedFolderInPlace(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "uia")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := secureDir(dir, nil, nil); err != nil {
		t.Fatalf("first secureDir: %v", err)
	}
	id := fileID(t, dir)
	log := filepath.Join(dir, "helper.log")
	if err := os.WriteFile(log, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	moved, err := secureDir(dir, map[string]bool{"helper.log": true, "helper.log.1": true}, nil)
	if err != nil {
		t.Fatalf("second secureDir: %v", err)
	}
	if moved != "" {
		t.Fatalf("a locked folder was moved to %s", moved)
	}
	if fileID(t, dir) != id {
		t.Fatalf("a locked folder was recreated")
	}
	if _, err := os.Stat(log); err != nil {
		t.Fatalf("helper.log was not kept: %v", err)
	}
}

// Runs elevated.
func TestSecureDirKeepsAtMostOneMovedAsideFolder(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "uia")
	stale := dir + ".untrusted-20200101000000"
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(stale, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := secureDir(dir, nil, nil); err != nil {
		t.Fatalf("secureDir: %v", err)
	}
	asides, err := filepath.Glob(dir + ".untrusted-*")
	if err != nil {
		t.Fatal(err)
	}
	if len(asides) != 1 {
		t.Fatalf("%d moved-aside folders remain: %v", len(asides), asides)
	}
}
