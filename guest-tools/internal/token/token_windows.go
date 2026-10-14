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

// OEMStrings returns the SMBIOS type 11 strings of the firmware table, or nil.
func OEMStrings() []string {
	size, _, _ := procGetSystemFirmwareTbl.Call(rsmb, 0, 0, 0)
	if size == 0 {
		return nil
	}
	buf := make([]byte, size)
	n, _, _ := procGetSystemFirmwareTbl.Call(rsmb, 0, uintptr(unsafe.Pointer(&buf[0])), size)
	if n == 0 || n > size {
		return nil
	}
	// RawSMBIOSData header: Used20CallingMethod, MajorVersion, MinorVersion, DmiRevision, Length(4), then the table
	if n < 8 {
		return nil
	}
	return ParseType11(buf[8:n])
}
