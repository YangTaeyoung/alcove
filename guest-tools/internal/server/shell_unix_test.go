//go:build !windows

package server

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

func TestExecRunEndsTheCommandWhenItsConnectionCloses(t *testing.T) {
	home := t.TempDir()
	_, r, w, conn := startServerS(t, Options{Clipboard: &fakeClipboard{}, HomeDir: home, AllowExec: true})
	expect(t, r, "hello")
	send(t, w, proto.Message{"t": "req", "id": 1, "op": "exec.run", "shell": "sh",
		"cmd": "echo $$ > pid.tmp && mv pid.tmp pid && exec sleep 30", "cwd": home, "timeout_ms": 60000})

	pidFile := filepath.Join(home, "pid")
	var pid int
	deadline := time.Now().Add(5 * time.Second)
	for pid == 0 {
		if b, err := os.ReadFile(pidFile); err == nil {
			pid, _ = strconv.Atoi(strings.TrimSpace(string(b)))
		}
		if time.Now().After(deadline) {
			t.Fatal("the command did not write its pid")
		}
		time.Sleep(10 * time.Millisecond)
	}
	conn.Close()
	deadline = time.Now().Add(5 * time.Second)
	for pidAlive(pid) {
		if time.Now().After(deadline) {
			killPIDForce(pid)
			t.Fatalf("command %d still runs after its connection closed", pid)
		}
		time.Sleep(20 * time.Millisecond)
	}
}
