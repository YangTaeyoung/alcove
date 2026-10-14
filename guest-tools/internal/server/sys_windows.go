//go:build windows

package server

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/sysfolder"
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

// sessionEnvironmentKey holds the machine's PATH.
const sessionEnvironmentKey = `SYSTEM\CurrentControlSet\Control\Session Manager\Environment`

// resolveProgram returns systemProgramPath of path with the folders of the
// machine's PATH, read from the registry, and the HKLM App Paths keys. Their
// values are expanded with sysfolder.MachineVars; a folder or program that
// names any other variable is left out.
func resolveProgram(path string) (string, error) {
	if strings.ContainsAny(path, `\/:`) {
		return path, nil
	}
	vars, err := sysfolder.MachineVars()
	if err != nil {
		return "", fmt.Errorf("the system folders could not be read (%v); pass the full path of the program", err)
	}
	raw, _ := sysfolder.MachineString(sessionEnvironmentKey, "Path")
	var dirs []string
	for _, dir := range strings.Split(raw, ";") {
		if full, err := sysfolder.Expand(strings.TrimSpace(dir), vars); err == nil {
			dirs = append(dirs, full)
		}
	}
	exists := func(p string) bool {
		fi, err := os.Stat(p)
		return err == nil && fi.Mode().IsRegular()
	}
	return systemProgramPath(path, dirs, exists, func(key string) string {
		raw, err := sysfolder.MachineString(key, "")
		if err != nil {
			return ""
		}
		full, err := sysfolder.Expand(strings.Trim(strings.TrimSpace(raw), `"`), vars)
		if err != nil {
			return ""
		}
		return full
	})
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
