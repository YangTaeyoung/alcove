//go:build !windows

package server

import (
	"errors"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// pidAlive reports whether pid names a process that has not ended: one that
// signal 0 reaches and whose ps state is not Z.
func pidAlive(pid int) bool {
	if syscall.Kill(pid, 0) != nil {
		return false
	}
	out, err := exec.Command("ps", "-o", "stat=", "-p", strconv.Itoa(pid)).Output()
	state := strings.TrimSpace(string(out))
	var exit *exec.ExitError
	if errors.As(err, &exit) && state == "" {
		return false
	}
	return !strings.HasPrefix(state, "Z")
}

func killPIDForce(pid int) { _ = syscall.Kill(pid, syscall.SIGKILL) }

func TestPidAliveReportsAKilledChildThatWasNotWaitedForAsGone(t *testing.T) {
	c := exec.Command("sleep", "30")
	if err := c.Start(); err != nil {
		t.Fatal(err)
	}
	defer c.Wait()
	pid := c.Process.Pid
	if !pidAlive(pid) {
		t.Fatal("a running process is reported as gone")
	}
	if err := c.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for pidAlive(pid) {
		if time.Now().After(deadline) {
			t.Fatalf("process %d is reported as alive after it was killed", pid)
		}
		time.Sleep(20 * time.Millisecond)
	}
}
