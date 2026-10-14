//go:build windows

package main

import (
	"fmt"
	"syscall"
	"unsafe"
)

var (
	procSHGetKnownFolderPath = syscall.NewLazyDLL("shell32.dll").NewProc("SHGetKnownFolderPath")
	procCoTaskMemFree        = syscall.NewLazyDLL("ole32.dll").NewProc("CoTaskMemFree")
)

// folderIDProgramData is FOLDERID_ProgramData, {62AB5D82-FDC1-4DC3-A9DD-070D1D495D97}.
var folderIDProgramData = syscall.GUID{Data1: 0x62ab5d82, Data2: 0xfdc1, Data3: 0x4dc3,
	Data4: [8]byte{0xa9, 0xdd, 0x07, 0x0d, 0x1d, 0x49, 0x5d, 0x97}}

// programDataFolder returns the folder Windows names as ProgramData
// (SHGetKnownFolderPath with FOLDERID_ProgramData); the ProgramData
// environment variable is not read.
func programDataFolder() (string, error) {
	var p *uint16
	r, _, _ := procSHGetKnownFolderPath.Call(uintptr(unsafe.Pointer(&folderIDProgramData)), 0, 0, uintptr(unsafe.Pointer(&p)))
	if p != nil {
		defer procCoTaskMemFree.Call(uintptr(unsafe.Pointer(p)))
	}
	if r != 0 {
		return "", fmt.Errorf("SHGetKnownFolderPath: HRESULT 0x%08x", uint32(r))
	}
	if p == nil {
		return "", fmt.Errorf("SHGetKnownFolderPath returned no path")
	}
	n := 0
	for *(*uint16)(unsafe.Add(unsafe.Pointer(p), 2*n)) != 0 {
		n++
	}
	return syscall.UTF16ToString(unsafe.Slice(p, n)), nil
}
