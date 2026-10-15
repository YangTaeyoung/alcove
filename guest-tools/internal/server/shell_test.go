package server

import (
	"reflect"
	"runtime"
	"testing"

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
