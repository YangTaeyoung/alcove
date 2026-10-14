//go:build windows

package server

import (
	"sync"
	"syscall"
	"unsafe"
)

var (
	procGetSecurityInfo = syscall.NewLazyDLL("advapi32.dll").NewProc("GetSecurityInfo")
	procLocalFree       = syscall.NewLazyDLL("kernel32.dll").NewProc("LocalFree")
)

const (
	seFileObject      = 1
	ownerSecurityInfo = 0x00000001
	readControl       = 0x00020000
	fileShareDelete   = 0x00000004
)

// processUserSID is the SID string of the account the agent runs as, or ""
// when it cannot be read.
var processUserSID = sync.OnceValue(func() string {
	token, err := syscall.OpenCurrentProcessToken()
	if err != nil {
		return ""
	}
	defer token.Close()
	user, err := token.GetTokenUser()
	if err != nil {
		return ""
	}
	sid, err := user.User.Sid.String()
	if err != nil {
		return ""
	}
	return sid
})

// platformEntryOwner returns ownerName of the owner of the entry at path
// itself, read through a handle opened without following a reparse point,
// or "unknown" when the owner cannot be read.
func platformEntryOwner(path string) (string, bool) {
	sid, err := entryOwnerSID(path)
	if err != nil {
		return "unknown", true
	}
	return ownerName(sid, processUserSID()), true
}

func entryOwnerSID(path string) (string, error) {
	name, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return "", err
	}
	h, err := syscall.CreateFile(name, readControl,
		syscall.FILE_SHARE_READ|syscall.FILE_SHARE_WRITE|fileShareDelete, nil, syscall.OPEN_EXISTING,
		syscall.FILE_FLAG_OPEN_REPARSE_POINT|syscall.FILE_FLAG_BACKUP_SEMANTICS, 0)
	if err != nil {
		return "", err
	}
	defer syscall.CloseHandle(h)
	var owner *syscall.SID
	var sd uintptr
	if r, _, _ := procGetSecurityInfo.Call(uintptr(h), seFileObject, ownerSecurityInfo,
		uintptr(unsafe.Pointer(&owner)), 0, 0, 0, uintptr(unsafe.Pointer(&sd))); r != 0 {
		return "", syscall.Errno(r)
	}
	defer procLocalFree.Call(sd)
	if owner == nil {
		return "", syscall.Errno(13)
	}
	return owner.String()
}
