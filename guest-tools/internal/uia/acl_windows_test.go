//go:build windows

package uia

import (
	"os"
	"path/filepath"
	"strings"
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

const fileWriteAttributes = 0x00000100

// holdDir opens path itself with the rights to change its access list and its
// attributes and the given share mode, as a standard user's handle opened
// before the lock would be.
func holdDir(t *testing.T, path string, share uint32) syscall.Handle {
	t.Helper()
	name, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		t.Fatal(err)
	}
	h, err := syscall.CreateFile(name, readControl|writeDAC|fileWriteAttributes, share, nil, syscall.OPEN_EXISTING,
		syscall.FILE_FLAG_OPEN_REPARSE_POINT|syscall.FILE_FLAG_BACKUP_SEMANTICS, 0)
	if err != nil {
		t.Fatalf("open %s: %v", path, err)
	}
	return h
}

// Runs elevated: secureDir sets the owner to Administrators.
func TestSecureDirMovesAsideAnUnlockedFolderWhileAHandleIsOpenOnIt(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "uia")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	before := fileID(t, dir)

	held := holdDir(t, dir, syscall.FILE_SHARE_READ|syscall.FILE_SHARE_WRITE|syscall.FILE_SHARE_DELETE)
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
func TestAHelperStartFailsClosedWhileAHandleWithoutDeleteSharingIsOpenOnTheFolder(t *testing.T) {
	parent := filepath.Join(t.TempDir(), "Alcove")
	dir := filepath.Join(parent, "uia")
	if _, err := secureDir(parent, nil, map[string]bool{"uia": true}); err != nil {
		t.Fatalf("locking the parent: %v", err)
	}
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	before := fileID(t, dir)

	held := holdDir(t, dir, syscall.FILE_SHARE_READ|syscall.FILE_SHARE_WRITE)
	defer syscall.CloseHandle(held)

	_, _, _, err := DefaultLauncher(dir, t.Logf)(make(chan struct{}))
	if err == nil || !strings.Contains(err.Error(), "could not be moved aside") {
		t.Fatalf("the helper start answered %v; expected the folder to be reported as not moved aside", err)
	}
	if fileID(t, dir) != before {
		t.Fatalf("the folder at %s was replaced although the start failed", dir)
	}
	for _, name := range []string{"bootstrap.ps1", "helper.cs", "tmp"} {
		if _, statErr := os.Lstat(filepath.Join(dir, name)); !os.IsNotExist(statErr) {
			t.Errorf("%s was written into the unlocked folder (%v)", name, statErr)
		}
	}
	asides, globErr := filepath.Glob(dir + ".untrusted-*")
	if globErr != nil || len(asides) != 0 {
		t.Errorf("moved-aside folders %v (%v) after a failed move", asides, globErr)
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
