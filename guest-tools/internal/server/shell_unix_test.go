//go:build !windows

package server

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

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

func TestExecRunWithoutCwdRunsInTheHomeDirectory(t *testing.T) {
	home := t.TempDir()
	real, _ := filepath.EvalSymlinks(home)
	c, _ := newRPCClient(t, Options{HomeDir: home})
	res := c.ok("exec.run", proto.Message{"cmd": "pwd"})
	got, err := filepath.EvalSymlinks(strings.TrimSpace(res.String("stdout")))
	if err != nil || got != real {
		t.Fatalf("stdout %q, expected %q", res.String("stdout"), real)
	}
}

func TestExecRunSeparatesStreams(t *testing.T) {
	c, _ := newRPCClient(t, Options{})
	res := c.ok("exec.run", proto.Message{"cmd": "echo out; echo err 1>&2; exit 3"})
	if res.String("stdout") != "out\n" || res.String("stderr") != "err\n" || res.Int("code") != 3 || res.Bool("timed_out") {
		t.Fatalf("res %v", res)
	}
}

func TestExecRunStdinCwdEnv(t *testing.T) {
	c, _ := newRPCClient(t, Options{})
	dir := t.TempDir()
	real, err := filepath.EvalSymlinks(dir)
	if err != nil {
		t.Fatal(err)
	}
	res := c.ok("exec.run", proto.Message{"cmd": "cat; pwd; echo $FOO", "stdin": "typed\n", "cwd": dir,
		"env": map[string]any{"FOO": "bar"}})
	if want := "typed\n" + real + "\nbar\n"; res.String("stdout") != want {
		t.Fatalf("stdout %q want %q", res.String("stdout"), want)
	}
}

func TestExecRunWithoutStdinGivesEmptyPipe(t *testing.T) {
	c, _ := newRPCClient(t, Options{})
	res := c.ok("exec.run", proto.Message{"cmd": `read x; echo "got:$x"; [ -p /dev/stdin ] && echo pipe`, "timeout_ms": 10000})
	if res.String("stdout") != "got:\npipe\n" || res["timed_out"] != false || res.Int("code") != 0 {
		t.Fatalf("res %v", res)
	}
}

func TestV1ExecWithoutStdinGivesEmptyPipe(t *testing.T) {
	r, w, c := startServer(t, Options{Clipboard: &fakeClipboard{}, HomeDir: t.TempDir(), AllowExec: true})
	c.SetDeadline(time.Now().Add(10 * time.Second))
	expect(t, r, "hello")
	w.Send(proto.Message{"t": "exec", "cmd": `read x; echo "got:$x"; [ -p /dev/stdin ] && echo pipe`})
	res := expect(t, r, "exec.result")
	if res.String("out") != "got:\npipe\n" || res.Int("code") != 0 {
		t.Fatalf("res %v", res)
	}
}

func TestExecRunRelativeCwdUsesHome(t *testing.T) {
	home := t.TempDir()
	if err := os.Mkdir(filepath.Join(home, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	real, _ := filepath.EvalSymlinks(filepath.Join(home, "sub"))
	c, _ := newRPCClient(t, Options{HomeDir: home})
	res := c.ok("exec.run", proto.Message{"cmd": "pwd", "cwd": "sub"})
	got, err := filepath.EvalSymlinks(strings.TrimSpace(res.String("stdout")))
	if err != nil || got != real {
		t.Fatalf("stdout %q", res.String("stdout"))
	}
}

func TestExecRunUTF8(t *testing.T) {
	c, _ := newRPCClient(t, Options{})
	res := c.ok("exec.run", proto.Message{"cmd": `printf '한글\377'`})
	out := res.String("stdout")
	if !strings.HasPrefix(out, "한글") || !utf8.ValidString(out) {
		t.Fatalf("stdout %q", out)
	}
}

func TestExecRunTimeoutKillsTree(t *testing.T) {
	c, _ := newRPCClient(t, Options{})
	started := time.Now()
	res := c.ok("exec.run", proto.Message{"cmd": "sleep 30 & echo $!; wait", "timeout_ms": 300})
	if time.Since(started) > 3*time.Second {
		t.Fatalf("timeout took %v", time.Since(started))
	}
	if !res.Bool("timed_out") || res.Int("code") != -1 {
		t.Fatalf("res %v", res)
	}
	var pid int
	for _, f := range strings.Fields(res.String("stdout")) {
		if n := atoiOr0(f); n > 0 {
			pid = n
		}
	}
	if pid == 0 {
		t.Fatalf("no child pid in stdout %q", res.String("stdout"))
	}
	deadline := time.Now().Add(3 * time.Second)
	for pidAlive(pid) {
		if time.Now().After(deadline) {
			killPIDForce(pid)
			t.Fatalf("child %d survived the timeout", pid)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func atoiOr0(s string) int {
	n := 0
	for _, r := range s {
		if r < '0' || r > '9' {
			return 0
		}
		n = n*10 + int(r-'0')
	}
	return n
}

func TestExecRunTruncatesToTail(t *testing.T) {
	c, _ := newRPCClient(t, Options{})
	res := c.ok("exec.run", proto.Message{"cmd": "head -c 300000 /dev/zero | tr '\\0' 'a'; echo END"})
	out := res.String("stdout")
	if !res.Bool("truncated") || !strings.HasSuffix(out, "END\n") || len(out) > 200000 {
		t.Fatalf("truncated=%v len=%d tail=%q", res.Bool("truncated"), len(out), out[max(0, len(out)-8):])
	}
}

func TestV1ExecStillWorks(t *testing.T) {
	r, w, c := startServer(t, Options{Clipboard: &fakeClipboard{}, HomeDir: t.TempDir(), AllowExec: true})
	c.SetDeadline(time.Now().Add(10 * time.Second))
	expect(t, r, "hello")
	w.Send(proto.Message{"t": "exec", "cmd": "echo out; echo err 1>&2; exit 2"})
	res := expect(t, r, "exec.result")
	if res.Int("code") != 2 || !strings.Contains(res.String("out"), "out") || !strings.Contains(res.String("out"), "err") {
		t.Fatalf("exec.result %v", res)
	}
}
