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

// killEndWait bounds the wait of killByName for the processes it terminated
// to end.
const killEndWait = 5 * time.Second

// killByName terminates the nameKillTargets of the running processes through
// killListed and returns how many it terminated. Processes that refuse access
// make it answer killRefusal for the agent's token.
func killByName(name string, tree bool) (int, error) {
	procs, err := processEntries()
	if err != nil {
		return 0, err
	}
	killed, denied := killListed(nameKillTargets(procs, name, tree, os.Getpid()), openForKill, killEndWait)
	if denied > 0 {
		return 0, killRefusal(name, killed, denied, tokenElevated())
	}
	return killed, nil
}

// processQueryLimitedInformation is PROCESS_QUERY_LIMITED_INFORMATION.
const processQueryLimitedInformation = 0x1000

// processEntries lists the running processes with their image names and
// their creation times where they can be read.
func processEntries() ([]procEntry, error) {
	snap, err := syscall.CreateToolhelp32Snapshot(syscall.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return nil, err
	}
	defer syscall.CloseHandle(snap)
	var e syscall.ProcessEntry32
	e.Size = uint32(unsafe.Sizeof(e))
	var procs []procEntry
	for err := syscall.Process32First(snap, &e); err == nil; err = syscall.Process32Next(snap, &e) {
		p := procEntry{PID: int(e.ProcessID), PPID: int(e.ParentProcessID), Name: syscall.UTF16ToString(e.ExeFile[:])}
		if h, err := syscall.OpenProcess(processQueryLimitedInformation, false, e.ProcessID); err == nil {
			p.Created, _ = processCreation(h)
			syscall.CloseHandle(h)
		}
		procs = append(procs, p)
	}
	return procs, nil
}

// processCreation returns the creation time of the process of h, and false
// when it cannot be read.
func processCreation(h syscall.Handle) (time.Time, bool) {
	var creation, exit, kernel, user syscall.Filetime
	if syscall.GetProcessTimes(h, &creation, &exit, &kernel, &user) != nil {
		return time.Time{}, false
	}
	return time.Unix(0, creation.Nanoseconds()), true
}

// windowsKillHandle is a process opened for termination, waiting and reading
// its creation time.
type windowsKillHandle struct{ h syscall.Handle }

// openForKill opens pid for killListed; a refusal of access is errKillDenied.
func openForKill(pid int) (killHandle, error) {
	h, err := syscall.OpenProcess(syscall.PROCESS_TERMINATE|syscall.SYNCHRONIZE|processQueryLimitedInformation, false, uint32(pid))
	if err != nil {
		return nil, killError(err)
	}
	return windowsKillHandle{h}, nil
}

// killError returns errKillDenied for ERROR_ACCESS_DENIED and err otherwise.
func killError(err error) error {
	if errors.Is(err, syscall.ERROR_ACCESS_DENIED) {
		return errKillDenied
	}
	return err
}

func (w windowsKillHandle) creation() (time.Time, bool) { return processCreation(w.h) }

func (w windowsKillHandle) terminate() error {
	if err := syscall.TerminateProcess(w.h, 1); err != nil {
		return killError(err)
	}
	return nil
}

func (w windowsKillHandle) wait(d time.Duration) {
	_, _ = syscall.WaitForSingleObject(w.h, uint32(d.Milliseconds()))
}

func (w windowsKillHandle) close() { syscall.CloseHandle(w.h) }

// tokenElevation is TokenElevation of TOKEN_INFORMATION_CLASS.
const tokenElevation = 20

// tokenElevated reports whether the agent's token is elevated.
func tokenElevated() bool {
	t, err := syscall.OpenCurrentProcessToken()
	if err != nil {
		return false
	}
	defer t.Close()
	var elevated, n uint32
	if syscall.GetTokenInformation(t, tokenElevation, (*byte)(unsafe.Pointer(&elevated)), uint32(unsafe.Sizeof(elevated)), &n) != nil {
		return false
	}
	return elevated != 0
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
