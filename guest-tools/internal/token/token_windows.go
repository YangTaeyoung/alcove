//go:build windows

package token

import (
	"syscall"
	"unsafe"
)

var (
	kernel32                 = syscall.NewLazyDLL("kernel32.dll")
	procGetSystemFirmwareTbl = kernel32.NewProc("GetSystemFirmwareTable")
)

const rsmb = 0x52534D42 // 'RSMB'

// Read returns the token from the SMBIOS table, or "".
func Read() string {
	size, _, _ := procGetSystemFirmwareTbl.Call(rsmb, 0, 0, 0)
	if size == 0 {
		return ""
	}
	buf := make([]byte, size)
	n, _, _ := procGetSystemFirmwareTbl.Call(rsmb, 0, uintptr(unsafe.Pointer(&buf[0])), size)
	if n == 0 || n > size {
		return ""
	}
	// RawSMBIOSData header: Used20CallingMethod, MajorVersion, MinorVersion, DmiRevision, Length(4), then the table
	if n < 8 {
		return ""
	}
	return FromOEMStrings(ParseType11(buf[8:n]))
}
