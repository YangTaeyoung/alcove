//go:build windows

package main

import (
	"fmt"
	"syscall"
	"unsafe"
)

var procGetSystemWindowsDirectory = syscall.NewLazyDLL("kernel32.dll").NewProc("GetSystemWindowsDirectoryW")

// profileListKey holds the ProgramData value of the machine.
const profileListKey = `SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList`

// programDataFolder returns the folder Windows names as ProgramData: the
// ProgramData value of the ProfileList key of HKEY_LOCAL_MACHINE, expanded
// by expandSystemFolder with the system's Windows folder. No environment
// variable is read.
func programDataFolder() (string, error) {
	raw, err := machineString(profileListKey, "ProgramData")
	if err != nil {
		return "", err
	}
	windows, err := systemWindowsFolder()
	if err != nil {
		return "", err
	}
	return expandSystemFolder(raw, windows)
}

// machineString returns a REG_SZ or REG_EXPAND_SZ value of a key of
// HKEY_LOCAL_MACHINE without expanding it.
func machineString(key, name string) (string, error) {
	k, err := syscall.UTF16PtrFromString(key)
	if err != nil {
		return "", err
	}
	var h syscall.Handle
	if err := syscall.RegOpenKeyEx(syscall.HKEY_LOCAL_MACHINE, k, 0, syscall.KEY_QUERY_VALUE, &h); err != nil {
		return "", fmt.Errorf("HKLM\\%s: %v", key, err)
	}
	defer syscall.RegCloseKey(h)
	n, err := syscall.UTF16PtrFromString(name)
	if err != nil {
		return "", err
	}
	var typ, size uint32
	if err := syscall.RegQueryValueEx(h, n, nil, &typ, nil, &size); err != nil {
		return "", fmt.Errorf("HKLM\\%s\\%s: %v", key, name, err)
	}
	if typ != syscall.REG_SZ && typ != syscall.REG_EXPAND_SZ {
		return "", fmt.Errorf("HKLM\\%s\\%s is not a string", key, name)
	}
	if size < 2 {
		return "", nil
	}
	buf := make([]uint16, size/2)
	if err := syscall.RegQueryValueEx(h, n, nil, &typ, (*byte)(unsafe.Pointer(&buf[0])), &size); err != nil {
		return "", fmt.Errorf("HKLM\\%s\\%s: %v", key, name, err)
	}
	return syscall.UTF16ToString(buf), nil
}

// systemWindowsFolder returns the system's Windows folder, the same for
// every user and session.
func systemWindowsFolder() (string, error) {
	buf := make([]uint16, syscall.MAX_PATH)
	n, _, e := procGetSystemWindowsDirectory.Call(uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	if n == 0 || int(n) >= len(buf) {
		return "", fmt.Errorf("GetSystemWindowsDirectoryW: %v", e)
	}
	return syscall.UTF16ToString(buf[:n]), nil
}
