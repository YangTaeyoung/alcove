//go:build windows

package sysfolder

import (
	"fmt"
	"syscall"
	"unsafe"
)

var (
	procGetSystemWindowsDirectory = syscall.NewLazyDLL("kernel32.dll").NewProc("GetSystemWindowsDirectoryW")
	procRegEnumValue              = syscall.NewLazyDLL("advapi32.dll").NewProc("RegEnumValueW")
)

// errorNoMoreItems is ERROR_NO_MORE_ITEMS.
const errorNoMoreItems syscall.Errno = 259

// ProfileListKey holds the profile folder of each account of the machine.
const ProfileListKey = `SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList`

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

// MachineValues returns the REG_SZ and REG_EXPAND_SZ values of a key of
// HKEY_LOCAL_MACHINE in the order RegEnumValueW lists them, without expanding
// them; values of other types are left out.
func MachineValues(key string) ([]Value, error) {
	k, err := syscall.UTF16PtrFromString(key)
	if err != nil {
		return nil, err
	}
	var h syscall.Handle
	if err := syscall.RegOpenKeyEx(syscall.HKEY_LOCAL_MACHINE, k, 0, syscall.KEY_QUERY_VALUE, &h); err != nil {
		return nil, fmt.Errorf("HKLM\\%s: %v", key, err)
	}
	defer syscall.RegCloseKey(h)
	var nameMax, dataMax uint32
	if err := syscall.RegQueryInfoKey(h, nil, nil, nil, nil, nil, nil, nil, &nameMax, &dataMax, nil, nil); err != nil {
		return nil, fmt.Errorf("HKLM\\%s: %v", key, err)
	}
	name := make([]uint16, nameMax+1)
	data := make([]uint16, dataMax/2+1)
	var values []Value
	for i, grown := uint32(0), 0; ; {
		nameLen, dataLen := uint32(len(name)), uint32(2*len(data))
		var typ uint32
		r, _, _ := procRegEnumValue.Call(uintptr(h), uintptr(i), uintptr(unsafe.Pointer(&name[0])), uintptr(unsafe.Pointer(&nameLen)), 0,
			uintptr(unsafe.Pointer(&typ)), uintptr(unsafe.Pointer(&data[0])), uintptr(unsafe.Pointer(&dataLen)))
		switch e := syscall.Errno(r); {
		case e == errorNoMoreItems:
			return values, nil
		case e == syscall.ERROR_MORE_DATA && grown < 8:
			name, data = make([]uint16, 2*len(name)), make([]uint16, 2*len(data))
			grown++
			continue
		case e != 0:
			return nil, fmt.Errorf("HKLM\\%s: %v", key, e)
		}
		if typ == syscall.REG_SZ || typ == syscall.REG_EXPAND_SZ {
			values = append(values, Value{Name: syscall.UTF16ToString(name[:nameLen]),
				Text: syscall.UTF16ToString(data[:dataLen/2]), Expand: typ == syscall.REG_EXPAND_SZ})
		}
		i++
	}
}

// ProfileFolder returns the profile folder of the account whose SID string
// is sid: the ProfileImagePath value of its subkey of ProfileListKey,
// expanded by Expand with vars.
func ProfileFolder(sid string, vars map[string]string) (string, error) {
	raw, err := MachineString(ProfileListKey+`\`+sid, "ProfileImagePath")
	if err != nil {
		return "", err
	}
	return Expand(raw, vars)
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
