//go:build windows

package server

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

// copySystemProgram copies a program of the system folder to name in a
// temporary folder and returns its path.
func copySystemProgram(t *testing.T, program, name string) string {
	t.Helper()
	data, err := os.ReadFile(systemProgram(program))
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, data, 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

// openForWait opens pid for waiting on its end.
func openForWait(t *testing.T, pid int) syscall.Handle {
	t.Helper()
	h, err := syscall.OpenProcess(syscall.SYNCHRONIZE, false, uint32(pid))
	if err != nil {
		t.Fatalf("open process %d: %v", pid, err)
	}
	t.Cleanup(func() { syscall.CloseHandle(h) })
	return h
}

// expectEnded fails the test when the process of h does not end within 10 s.
func expectEnded(t *testing.T, h syscall.Handle, pid int) {
	t.Helper()
	if ev, _ := syscall.WaitForSingleObject(h, 10000); ev != syscall.WAIT_OBJECT_0 {
		t.Fatalf("process %d still runs after proc.kill", pid)
	}
}

// startHidden starts path with args without a window and kills it at the
// end of the test.
func startHidden(t *testing.T, path string, args ...string) *exec.Cmd {
	t.Helper()
	c := exec.Command(path, args...)
	hideWindow(c)
	if err := c.Start(); err != nil {
		t.Fatal(err)
	}
	exited := make(chan struct{})
	go func() { c.Wait(); close(exited) }()
	t.Cleanup(func() {
		c.Process.Kill()
		<-exited
	})
	return c
}

func TestProcKillByNameCountsWithoutReadingTaskkillText(t *testing.T) {
	path := copySystemProgram(t, "PING.EXE", "alcove-victim.exe")
	var waits []syscall.Handle
	var pids []int
	for i := 0; i < 2; i++ {
		c := startHidden(t, path, "-n", "60", "127.0.0.1")
		pids = append(pids, c.Process.Pid)
		waits = append(waits, openForWait(t, c.Process.Pid))
	}
	c, _ := newRPCClient(t, Options{})
	if res := c.ok("proc.kill", proto.Message{"name": "alcove-victim"}); res.Int("killed") != 2 {
		t.Fatalf("res %v", res)
	}
	for i, h := range waits {
		expectEnded(t, h, pids[i])
	}
	if res := c.ok("proc.kill", proto.Message{"name": "alcove-victim"}); res.Int("killed") != 0 {
		t.Fatalf("a second kill answered %v", res)
	}
}

func TestProcKillByNameWithTreeEndsTheChildren(t *testing.T) {
	parent := startHidden(t, copySystemProgram(t, "cmd.exe", "alcove-parent.exe"), "/c", systemProgram("PING.EXE"), "-n", "60", "127.0.0.1")
	child := 0
	deadline := time.Now().Add(10 * time.Second)
	for child == 0 {
		running, err := processEntries(false)
		if err != nil {
			t.Fatal(err)
		}
		for _, p := range running {
			if p.PPID == parent.Process.Pid && strings.EqualFold(p.Name, "PING.EXE") {
				child = p.PID
			}
		}
		if child == 0 && time.Now().After(deadline) {
			t.Fatal("the child did not start")
		}
		time.Sleep(20 * time.Millisecond)
	}
	childWait := openForWait(t, child)
	parentWait := openForWait(t, parent.Process.Pid)
	c, _ := newRPCClient(t, Options{})
	if res := c.ok("proc.kill", proto.Message{"name": "alcove-parent", "tree": true}); res.Int("killed") < 2 {
		t.Fatalf("res %v", res)
	}
	expectEnded(t, childWait, child)
	expectEnded(t, parentWait, parent.Process.Pid)
}
