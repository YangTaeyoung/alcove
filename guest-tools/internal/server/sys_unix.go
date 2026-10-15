//go:build !windows

package server

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

// childEnvironment returns the agent's own environment.
func childEnvironment() ([]string, error) { return os.Environ(), nil }

// agentHome returns the home directory of the agent's user: $HOME, else the
// one in the user database.
func agentHome() string {
	if h, err := os.UserHomeDir(); err == nil && h != "" {
		return h
	}
	if u, err := user.Current(); err == nil {
		return u.HomeDir
	}
	return ""
}

func hideWindow(*exec.Cmd) {}

// windowsFolder answers that this system has no Windows folder.
func windowsFolder() (string, error) {
	return "", errors.New("this system has no Windows folder")
}

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
	return parseProcesses(string(out), kernelName), nil
}

// kernelName returns the name the kernel keeps for pid (/proc/<pid>/comm,
// at most 15 bytes), or false where there is none.
func kernelName(pid int) (string, bool) {
	b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/comm")
	if err != nil {
		return "", false
	}
	return strings.TrimSuffix(string(b), "\n"), true
}

// parseProcesses reads `ps axo pid=,ppid=,rss=,args=`. A process is named by
// comm, its kernel name; when that name is the base name of its first
// argument, or the first 15 bytes of it, by that base name; without a
// kernel name by that base name.
func parseProcesses(out string, comm func(int) (string, bool)) []procInfo {
	var procs []procInfo
	for _, line := range strings.Split(out, "\n") {
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
		base := filepath.Base(f[3])
		name := base
		if c, ok := comm(pid); ok && c != "" && c != base && !(len(c) == 15 && strings.HasPrefix(base, c)) {
			name = c
		}
		p := procInfo{PID: pid, PPID: ppid, MemKB: rss, Name: name, Cmd: strings.Join(f[3:], " ")}
		if filepath.IsAbs(f[3]) {
			p.Path = f[3]
		}
		procs = append(procs, p)
	}
	return procs
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

// resolveProgram returns the program to start for an app.launch path: path
// itself.
func resolveProgram(path string) (string, error) { return path, nil }

// processParents maps each running process to its parent.
func processParents() map[int]int {
	procs, err := listProcesses()
	if err != nil {
		return nil
	}
	parents := make(map[int]int, len(procs))
	for _, p := range procs {
		parents[p.PID] = p.PPID
	}
	return parents
}
