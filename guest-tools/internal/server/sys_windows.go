//go:build windows

package server

import (
	"errors"
	"fmt"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

const createNoWindow = 0x08000000

// hideWindow starts the child without a console window.
func hideWindow(c *exec.Cmd) {
	if c.SysProcAttr == nil {
		c.SysProcAttr = &syscall.SysProcAttr{}
	}
	c.SysProcAttr.HideWindow = true
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

func taskkill(args ...string) ([]byte, error) {
	c := exec.Command("taskkill", args...)
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
	c, err := buildCommand(proto.Message{"cmd": script}, "windows")
	if err != nil {
		return nil, err
	}
	hideWindow(c)
	out, err := c.Output()
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
