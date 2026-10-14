//go:build windows

package server

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

const createNoWindow = 0x08000000

// hideWindow starts the child without a console window; windows the child
// creates itself keep their normal show state.
func hideWindow(c *exec.Cmd) {
	if c.SysProcAttr == nil {
		c.SysProcAttr = &syscall.SysProcAttr{}
	}
	c.SysProcAttr.CreationFlags |= createNoWindow
}

// setRawCommandLine makes the child receive line verbatim instead of
// re-escaped arguments.
func setRawCommandLine(c *exec.Cmd, line string) {
	if c.SysProcAttr == nil {
		c.SysProcAttr = &syscall.SysProcAttr{}
	}
	c.SysProcAttr.CmdLine = line
}

func prepareTree(*exec.Cmd) {}

// listTimeout bounds the PowerShell run that lists the processes.
const listTimeout = 30 * time.Second

var procGetSystemDirectory = syscall.NewLazyDLL("kernel32.dll").NewProc("GetSystemDirectoryW")

// systemProgram returns the path of a program in the Windows system folder,
// or name alone when that folder cannot be read.
func systemProgram(name string) string {
	buf := make([]uint16, syscall.MAX_PATH)
	n, _, _ := procGetSystemDirectory.Call(uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	if n == 0 || int(n) >= len(buf) {
		return name
	}
	return filepath.Join(syscall.UTF16ToString(buf[:n]), name)
}

func taskkill(args ...string) ([]byte, error) {
	c := exec.Command(systemProgram("taskkill.exe"), args...)
	hideWindow(c)
	return c.CombinedOutput()
}

func killTree(pid int) error {
	out, err := taskkill("/F", "/T", "/PID", strconv.Itoa(pid))
	if err != nil {
		return fmt.Errorf("taskkill: %v: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func listProcesses() ([]procInfo, error) {
	script := "Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,Name,ExecutablePath,CommandLine,WorkingSetSize | ConvertTo-Json -Compress"
	ctx, cancel := context.WithTimeout(context.Background(), listTimeout)
	defer cancel()
	c := exec.CommandContext(ctx, systemProgram(`WindowsPowerShell\v1.0\powershell.exe`),
		"-NoProfile", "-NonInteractive", "-Command", powershellUTF8Prefix+script)
	hideWindow(c)
	out, err := c.Output()
	if ctx.Err() != nil {
		return nil, fmt.Errorf("listing the processes took longer than %d s; retry", int(listTimeout.Seconds()))
	}
	if err != nil {
		return nil, err
	}
	return parseWindowsProcesses(out)
}

// killByName runs taskkill on the image name and counts its SUCCESS lines.
func killByName(name string, tree bool) (int, error) {
	if filepath.Ext(name) == "" {
		name += ".exe"
	}
	args := []string{"/F"}
	if tree {
		args = append(args, "/T")
	}
	out, err := taskkill(append(args, "/IM", name)...)
	killed := 0
	for _, line := range strings.Split(string(out), "\n") {
		if l := strings.TrimSpace(line); strings.HasPrefix(l, "SUCCESS") || strings.HasPrefix(l, "성공") {
			killed++
		}
	}
	var ee *exec.ExitError
	if err != nil && killed == 0 && !errors.As(err, &ee) {
		return 0, err
	}
	return killed, nil
}

// resolveProgram returns the program to start for an app.launch path. A bare
// file name that is not on the search path is looked up under the App Paths
// registry keys, where programs such as msedge.exe register themselves.
func resolveProgram(path string) string {
	if strings.ContainsAny(path, `\/:`) {
		return path
	}
	if _, err := exec.LookPath(path); err == nil {
		return path
	}
	name := path
	if filepath.Ext(name) == "" {
		name += ".exe"
	}
	keys := []string{
		`SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\` + name,
		`SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\` + name,
	}
	for _, root := range []syscall.Handle{syscall.HKEY_CURRENT_USER, syscall.HKEY_LOCAL_MACHINE} {
		for _, key := range keys {
			if full := registryString(root, key, ""); full != "" {
				return strings.Trim(full, `"`)
			}
		}
	}
	return path
}

var procExpandEnvironmentStrings = syscall.NewLazyDLL("kernel32.dll").NewProc("ExpandEnvironmentStringsW")

// expandEnv replaces %VAR% references in a REG_EXPAND_SZ value with their
// environment values.
func expandEnv(s string) string {
	src, err := syscall.UTF16PtrFromString(s)
	if err != nil {
		return s
	}
	n, _, _ := procExpandEnvironmentStrings.Call(uintptr(unsafe.Pointer(src)), 0, 0)
	if n == 0 {
		return s
	}
	buf := make([]uint16, n)
	r, _, _ := procExpandEnvironmentStrings.Call(uintptr(unsafe.Pointer(src)), uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	if r == 0 {
		return s
	}
	return syscall.UTF16ToString(buf)
}

// registryString reads a string value; it returns "" when the key or the
// value is missing. A REG_EXPAND_SZ value has its %VAR% references expanded.
func registryString(root syscall.Handle, key, value string) string {
	keyPtr, err := syscall.UTF16PtrFromString(key)
	if err != nil {
		return ""
	}
	var h syscall.Handle
	if syscall.RegOpenKeyEx(root, keyPtr, 0, syscall.KEY_READ, &h) != nil {
		return ""
	}
	defer syscall.RegCloseKey(h)
	valuePtr, err := syscall.UTF16PtrFromString(value)
	if err != nil {
		return ""
	}
	var kind, size uint32
	if syscall.RegQueryValueEx(h, valuePtr, nil, &kind, nil, &size) != nil || size == 0 {
		return ""
	}
	if kind != syscall.REG_SZ && kind != syscall.REG_EXPAND_SZ {
		return ""
	}
	buf := make([]uint16, size/2+1)
	if syscall.RegQueryValueEx(h, valuePtr, nil, &kind, (*byte)(unsafe.Pointer(&buf[0])), &size) != nil {
		return ""
	}
	out := syscall.UTF16ToString(buf)
	if kind == syscall.REG_EXPAND_SZ {
		out = expandEnv(out)
	}
	return out
}

// processParents maps each running process to its parent.
func processParents() map[int]int {
	snap, err := syscall.CreateToolhelp32Snapshot(syscall.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return nil
	}
	defer syscall.CloseHandle(snap)
	var e syscall.ProcessEntry32
	e.Size = uint32(unsafe.Sizeof(e))
	parents := map[int]int{}
	for err := syscall.Process32First(snap, &e); err == nil; err = syscall.Process32Next(snap, &e) {
		parents[int(e.ProcessID)] = int(e.ParentProcessID)
	}
	return parents
}
