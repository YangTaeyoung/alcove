//go:build !windows

package server

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

func hideWindow(*exec.Cmd) {}

// setRawCommandLine has no effect outside Windows.
func setRawCommandLine(*exec.Cmd, string) {}

// prepareTree puts the child in its own process group.
func prepareTree(c *exec.Cmd) {
	if c.SysProcAttr == nil {
		c.SysProcAttr = &syscall.SysProcAttr{}
	}
	c.SysProcAttr.Setpgid = true
}

// killTree sends SIGKILL to the process group led by pid, or to pid alone
// when it leads no group.
func killTree(pid int) error {
	if pid <= 1 {
		return fmt.Errorf("refusing to kill pid %d", pid)
	}
	if err := syscall.Kill(-pid, syscall.SIGKILL); err == nil {
		return nil
	}
	return syscall.Kill(pid, syscall.SIGKILL)
}

func listProcesses() ([]procInfo, error) {
	out, err := exec.Command("ps", "axo", "pid=,ppid=,rss=,args=").Output()
	if err != nil {
		return nil, err
	}
	var procs []procInfo
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) < 4 {
			continue
		}
		pid, err1 := strconv.Atoi(f[0])
		ppid, err2 := strconv.Atoi(f[1])
		rss, err3 := strconv.Atoi(f[2])
		if err1 != nil || err2 != nil || err3 != nil {
			continue
		}
		p := procInfo{PID: pid, PPID: ppid, MemKB: rss, Name: filepath.Base(f[3]), Cmd: strings.Join(f[3:], " ")}
		if filepath.IsAbs(f[3]) {
			p.Path = f[3]
		}
		procs = append(procs, p)
	}
	return procs, nil
}

// killByName kills every process whose name equals name (case-insensitive)
// and returns how many were signalled.
func killByName(name string, tree bool) (int, error) {
	procs, err := listProcesses()
	if err != nil {
		return 0, err
	}
	self := os.Getpid()
	killed := 0
	for _, p := range procs {
		if p.PID == self || !strings.EqualFold(p.Name, name) {
			continue
		}
		var err error
		if gid, gerr := syscall.Getpgid(p.PID); tree && gerr == nil && gid == p.PID {
			err = killTree(p.PID)
		} else {
			err = syscall.Kill(p.PID, syscall.SIGKILL)
		}
		if err == nil {
			killed++
		}
	}
	return killed, nil
}
