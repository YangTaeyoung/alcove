package server

import (
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

// rpcClient issues requests on one connection and keeps events that arrive
// while it waits for a reply.
type rpcClient struct {
	t      *testing.T
	r      *proto.Reader
	w      *proto.Writer
	nextID int
	events []proto.Message
}

func newRPCClient(t *testing.T, opt Options) (*rpcClient, *Server) {
	t.Helper()
	if opt.Clipboard == nil {
		opt.Clipboard = &fakeClipboard{}
	}
	if opt.HomeDir == "" {
		opt.HomeDir = t.TempDir()
	}
	opt.AllowExec = true
	s, r, w, _ := startServerS(t, opt)
	expect(t, r, "hello")
	return &rpcClient{t: t, r: r, w: w}, s
}

func (c *rpcClient) call(op string, fields proto.Message) proto.Message {
	c.t.Helper()
	c.nextID++
	req := proto.Message{"t": "req", "id": c.nextID, "op": op}
	for k, v := range fields {
		req[k] = v
	}
	if err := c.w.Send(req); err != nil {
		c.t.Fatal(err)
	}
	for {
		m, err := c.r.Next()
		if err != nil {
			c.t.Fatalf("waiting for %s reply: %v", op, err)
		}
		switch m.Type() {
		case "ev":
			c.events = append(c.events, m)
		case "res":
			if m.Int("id") == c.nextID {
				return m
			}
		}
	}
}

func (c *rpcClient) ok(op string, fields proto.Message) proto.Message {
	c.t.Helper()
	res := c.call(op, fields)
	if res["ok"] != true {
		c.t.Fatalf("%s failed: %v", op, res)
	}
	return res
}

func (c *rpcClient) event(name string) proto.Message {
	c.t.Helper()
	for {
		for _, e := range c.events {
			if e.String("name") == name {
				return e
			}
		}
		m, err := c.r.Next()
		if err != nil {
			c.t.Fatalf("waiting for event %s: %v", name, err)
		}
		if m.Type() == "ev" {
			c.events = append(c.events, m)
		}
	}
}

func TestBuildCommandForms(t *testing.T) {
	const prefix = "[Console]::InputEncoding=[Text.UTF8Encoding]::new($false); [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $OutputEncoding=[Console]::OutputEncoding; "

	cmd, err := buildCommand(proto.Message{"cmd": "dir"}, "windows")
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"powershell.exe", "-NoProfile", "-NonInteractive", "-Command", prefix + "dir"}
	if !reflect.DeepEqual(cmd.Args, want) {
		t.Fatalf("windows default args %q", cmd.Args)
	}

	cmd, err = buildCommand(proto.Message{"cmd": "dir", "shell": "cmd"}, "windows")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"cmd.exe", "/S", "/C", "dir"}; !reflect.DeepEqual(cmd.Args, want) {
		t.Fatalf("cmd args %q", cmd.Args)
	}

	cmd, err = buildCommand(proto.Message{"shell": "none", "argv": []any{"git", "status", "-s"}}, "windows")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"git", "status", "-s"}; !reflect.DeepEqual(cmd.Args, want) {
		t.Fatalf("none args %q", cmd.Args)
	}

	_, err = buildCommand(proto.Message{"shell": "none", "cmd": "ls"}, "linux")
	if err == nil || err.Error() != "shell 'none' needs argv" {
		t.Fatalf("none without argv: %v", err)
	}

	cmd, err = buildCommand(proto.Message{"cmd": "ls -l"}, "linux")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"/bin/sh", "-c", "ls -l"}; !reflect.DeepEqual(cmd.Args, want) {
		t.Fatalf("linux args %q", cmd.Args)
	}

	cmd, err = buildCommand(proto.Message{"cmd": "ls", "cwd": "/work", "env": map[string]any{"A": "1"}}, "linux")
	if err != nil {
		t.Fatal(err)
	}
	if cmd.Dir != "/work" {
		t.Fatalf("dir %q", cmd.Dir)
	}
	if len(cmd.Env) == 0 || cmd.Env[len(cmd.Env)-1] != "A=1" {
		t.Fatalf("env does not end with A=1: %v", cmd.Env[max(0, len(cmd.Env)-2):])
	}
	if len(cmd.Env) < 2 {
		t.Fatalf("env dropped the inherited variables: %v", cmd.Env)
	}

	_, err = buildCommand(proto.Message{}, "linux")
	if err == nil || err.Error() != "missing cmd or argv" {
		t.Fatalf("empty request: %v", err)
	}

	_, err = buildCommand(proto.Message{"cmd": "ls", "argv": []any{"ls"}}, "linux")
	if err == nil || err.Error() != "pass cmd or argv, not both" {
		t.Fatalf("cmd with argv: %v", err)
	}
	_, err = buildCommand(proto.Message{"shell": "powershell", "argv": []any{"git"}}, "windows")
	if err == nil || err.Error() != "shell 'powershell' does not run argv; pass shell 'none' or leave shell out" {
		t.Fatalf("shell with argv: %v", err)
	}
	if cmd, err := buildCommand(proto.Message{"argv": []any{"git"}}, "windows"); err != nil || !reflect.DeepEqual(cmd.Args, []string{"git"}) {
		t.Fatalf("argv without shell: %v %v", cmd, err)
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

func TestCmdExeLineWrapsCommandInOuterQuotes(t *testing.T) {
	for cmdline, want := range map[string]string{
		`dir`:                         `cmd.exe /S /C "dir"`,
		`echo hello & dir "C:\a b"`:   `cmd.exe /S /C "echo hello & dir "C:\a b""`,
		`"C:\a b\x.exe" /C "echo ok"`: `cmd.exe /S /C ""C:\a b\x.exe" /C "echo ok""`,
		`"C:\a b\x.exe"`:              `cmd.exe /S /C ""C:\a b\x.exe""`,
	} {
		if got := cmdExeLine(cmdline); got != want {
			t.Errorf("cmdExeLine(%s) = %s, want %s", cmdline, got, want)
		}
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

func TestExecRunStartFailure(t *testing.T) {
	c, _ := newRPCClient(t, Options{})
	res := c.call("exec.run", proto.Message{"shell": "none", "argv": []any{"/nonexistent/binary"}})
	if res["ok"] != false || res.String("error") == "" {
		t.Fatalf("res %v", res)
	}
	res = c.call("exec.run", proto.Message{})
	if res["ok"] != false || res.String("error") != "missing cmd or argv" {
		t.Fatalf("res %v", res)
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

func TestEventNeverPrecedesHello(t *testing.T) {
	s, r, _, _ := startServerS(t, Options{Clipboard: &fakeClipboard{}, HomeDir: t.TempDir()})
	stop := make(chan struct{})
	t.Cleanup(func() { close(stop) })
	go func() {
		for {
			select {
			case <-stop:
				return
			default:
				s.emit("tick", proto.Message{})
				runtime.Gosched()
			}
		}
	}()
	m, err := r.Next()
	if err != nil {
		t.Fatal(err)
	}
	if m.Type() != "hello" {
		t.Fatalf("first message %v", m)
	}
}
