//go:build windows

package sysfolder

import (
	"fmt"
	"syscall"
	"unsafe"
)

var procGetSystemWindowsDirectory = syscall.NewLazyDLL("kernel32.dll").NewProc("GetSystemWindowsDirectoryW")

// currentVersionKey holds the Program Files folders of the machine.
const currentVersionKey = `SOFTWARE\Microsoft\Windows\CurrentVersion`

// programFilesValues maps the variables of the Program Files folders to their
// values under currentVersionKey.
var programFilesValues = map[string]string{
	"programfiles":            "ProgramFilesDir",
	"programfiles(x86)":       "ProgramFilesDir (x86)",
	"programw6432":            "ProgramW6432Dir",
	"commonprogramfiles":      "CommonFilesDir",
	"commonprogramfiles(x86)": "CommonFilesDir (x86)",
	"commonprogramw6432":      "CommonW6432Dir",
}

// MachineVars returns BaseVars of the system's Windows folder and the Program
// Files variables whose values under currentVersionKey expand with them. No
// environment variable is read.
func MachineVars() (map[string]string, error) {
	windows, err := WindowsFolder()
	if err != nil {
		return nil, err
	}
	vars, err := BaseVars(windows)
	if err != nil {
		return nil, err
	}
	for name, value := range programFilesValues {
		raw, err := MachineString(currentVersionKey, value)
		if err != nil || raw == "" {
			continue
		}
		if dir, err := Expand(raw, vars); err == nil {
			vars[name] = dir
		}
	}
	return vars, nil
}

// MachineString returns a REG_SZ or REG_EXPAND_SZ value of a key of
// HKEY_LOCAL_MACHINE without expanding it; name "" is the key's default value.
func MachineString(key, name string) (string, error) {
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

// WindowsFolder returns the system's Windows folder, the same for every user
// and session.
func WindowsFolder() (string, error) {
	buf := make([]uint16, syscall.MAX_PATH)
	n, _, e := procGetSystemWindowsDirectory.Call(uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	if n == 0 || int(n) >= len(buf) {
		return "", fmt.Errorf("GetSystemWindowsDirectoryW: %v", e)
	}
	return syscall.UTF16ToString(buf[:n]), nil
}
