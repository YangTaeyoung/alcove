package server

import (
	"context"
	"errors"
	"reflect"
	"runtime"
	"strings"
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

// testSystem is a commandSystem of goos whose Windows folder is D:\WINDOWS,
// whose base environment is environ and which has no files.
func testSystem(goos string, environ ...string) commandSystem {
	return commandSystem{goos: goos, environ: environ, windows: func() (string, error) { return `D:\WINDOWS`, nil },
		isFile: func(string) bool { return false }}
}

// testPowerShellPrefix is the text before the command of every -Command the
// agent passes to Windows PowerShell.
const testPowerShellPrefix = `$env:PSModulePath = $PSHOME + '\Modules'; [Console]::InputEncoding=[Text.UTF8Encoding]::new($false); [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $OutputEncoding=[Console]::OutputEncoding; `

func TestBuildCommandForms(t *testing.T) {
	cmd, err := buildCommand(proto.Message{"cmd": "dir"}, testSystem("windows"))
	if err != nil {
		t.Fatal(err)
	}
	want := []string{`D:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe`, "-NoProfile", "-NonInteractive",
		"-ExecutionPolicy", "Restricted", "-Command", testPowerShellPrefix + "dir"}
	if !reflect.DeepEqual(cmd.Args, want) {
		t.Fatalf("windows default args %q", cmd.Args)
	}

	cmd, err = buildCommand(proto.Message{"cmd": "dir", "shell": "cmd"}, testSystem("windows", `PSModulePath=C:\Users\alcove\Documents\WindowsPowerShell\Modules`))
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{`D:\WINDOWS\System32\cmd.exe`, "/D", "/S", "/C", "dir"}; cmd.Path != want[0] || !reflect.DeepEqual(cmd.Args, want) ||
		!reflect.DeepEqual(cmd.Env, []string{`PSModulePath=C:\Users\alcove\Documents\WindowsPowerShell\Modules`}) {
		t.Fatalf("cmd path %q, args %q, env %q", cmd.Path, cmd.Args, cmd.Env)
	}

	cmd, err = buildCommand(proto.Message{"shell": "none", "argv": []any{"git", "status", "-s"}}, windowsTestSystem(t, `C:\Tools\git.exe`))
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"git", "status", "-s"}; !reflect.DeepEqual(cmd.Args, want) || cmd.Path != `C:\Tools\git.exe` {
		t.Fatalf("none path %q, args %q", cmd.Path, cmd.Args)
	}

	_, err = buildCommand(proto.Message{"shell": "none", "cmd": "ls"}, testSystem("linux"))
	if err == nil || err.Error() != "shell 'none' needs argv" {
		t.Fatalf("none without argv: %v", err)
	}

	cmd, err = buildCommand(proto.Message{"cmd": "ls -l"}, testSystem("linux"))
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"/bin/sh", "-c", "ls -l"}; !reflect.DeepEqual(cmd.Args, want) {
		t.Fatalf("linux args %q", cmd.Args)
	}

	cmd, err = buildCommand(proto.Message{"cmd": "ls", "cwd": "/work", "env": map[string]any{"B": "2", "A": "1"}}, testSystem("linux", "HOME=/root", "PATH=/bin"))
	if err != nil {
		t.Fatal(err)
	}
	if cmd.Dir != "/work" {
		t.Fatalf("dir %q", cmd.Dir)
	}
	if want := []string{"HOME=/root", "PATH=/bin", "A=1", "B=2"}; !reflect.DeepEqual(cmd.Env, want) {
		t.Fatalf("env %q", cmd.Env)
	}

	_, err = buildCommand(proto.Message{}, testSystem("linux"))
	if err == nil || err.Error() != "missing cmd or argv" {
		t.Fatalf("empty request: %v", err)
	}

	_, err = buildCommand(proto.Message{"cmd": "ls", "argv": []any{"ls"}}, testSystem("linux"))
	if err == nil || err.Error() != "pass cmd or argv, not both" {
		t.Fatalf("cmd with argv: %v", err)
	}
	_, err = buildCommand(proto.Message{"shell": "powershell", "argv": []any{"git"}}, testSystem("windows"))
	if err == nil || err.Error() != "shell 'powershell' does not run argv; pass shell 'none' or leave shell out" {
		t.Fatalf("shell with argv: %v", err)
	}
	if cmd, err := buildCommand(proto.Message{"argv": []any{"git"}}, windowsTestSystem(t, `C:\Tools\git.exe`)); err != nil || !reflect.DeepEqual(cmd.Args, []string{"git"}) {
		t.Fatalf("argv without shell: %v %v", cmd, err)
	}
}

func TestWindowsCmdWithoutAReadableWindowsFolderIsNotStarted(t *testing.T) {
	sys := testSystem("windows")
	sys.windows = func() (string, error) { return "", errors.New("GetSystemWindowsDirectoryW: access denied") }
	_, err := buildCommand(proto.Message{"cmd": "dir", "shell": "cmd"}, sys)
	if want := "cmd.exe could not be located (GetSystemWindowsDirectoryW: access denied); restart alcove-agent and retry"; err == nil || err.Error() != want {
		t.Fatalf("err %v", err)
	}
}

func TestWindowsPowerShellGetsTheBaseEnvironmentWithOnlyItsOwnModuleFolder(t *testing.T) {
	sys := testSystem("windows",
		`PSModulePath=C:\Users\alcove\Documents\WindowsPowerShell\Modules;C:\Program Files\WindowsPowerShell\Modules`,
		`Path=C:\WINDOWS\system32;C:\Users\alcove\bin`,
		`psmodulepath=C:\Users\alcove\mods`,
		`=C:=C:\Users\alcove`,
		`PSExecutionPolicyPreference=Bypass`)
	cmd, err := buildCommand(proto.Message{"cmd": "dir"}, sys)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{`Path=C:\WINDOWS\system32;C:\Users\alcove\bin`, `=C:=C:\Users\alcove`, `PSExecutionPolicyPreference=Bypass`,
		`PSModulePath=D:\WINDOWS\System32\WindowsPowerShell\v1.0\Modules`}
	if !reflect.DeepEqual(cmd.Env, want) {
		t.Fatalf("env\n got %q\nwant %q", cmd.Env, want)
	}

	cmd, err = buildCommand(proto.Message{"cmd": "dir", "env": map[string]any{"PSModulePath": `E:\mods`, "A": "1"}}, sys)
	if err != nil {
		t.Fatal(err)
	}
	want = append(append([]string{}, want...), "A=1", `PSModulePath=E:\mods`)
	if !reflect.DeepEqual(cmd.Env, want) {
		t.Fatalf("env with the request's env\n got %q\nwant %q", cmd.Env, want)
	}
	if !reflect.DeepEqual(sys.environ[:1], []string{`PSModulePath=C:\Users\alcove\Documents\WindowsPowerShell\Modules;C:\Program Files\WindowsPowerShell\Modules`}) {
		t.Fatalf("building the command changed the base environment: %q", sys.environ)
	}
}

func TestWindowsPowerShellWithoutAReadableWindowsFolderIsNotStarted(t *testing.T) {
	sys := testSystem("windows")
	sys.windows = func() (string, error) { return "", errors.New("GetSystemWindowsDirectoryW: access denied") }
	_, err := buildCommand(proto.Message{"cmd": "dir"}, sys)
	want := "Windows PowerShell could not be located (GetSystemWindowsDirectoryW: access denied); restart alcove-agent and retry"
	if err == nil || err.Error() != want {
		t.Fatalf("err %v", err)
	}
	sys.windows = func() (string, error) { return `WINDOWS`, nil }
	if _, err := buildCommand(proto.Message{"cmd": "dir"}, sys); err == nil || !strings.HasPrefix(err.Error(), "Windows PowerShell could not be located (") {
		t.Fatalf("a Windows folder without a drive gave %v", err)
	}
}

func TestTheAgentsPowerShellRecipeRunsInAnEnvironmentOfTheSystemFoldersOnly(t *testing.T) {
	t.Setenv("PSModulePath", `C:\Users\alcove\Documents\WindowsPowerShell\Modules`)
	cmd, err := recipeCommand(context.Background(), func() (string, error) { return `D:\WINDOWS`, nil }, "Get-Date")
	if err != nil {
		t.Fatal(err)
	}
	wantArgs := []string{`D:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe`, "-NoProfile", "-NonInteractive",
		"-ExecutionPolicy", "Restricted", "-Command", testPowerShellPrefix + "Get-Date"}
	if !reflect.DeepEqual(cmd.Args, wantArgs) {
		t.Fatalf("args %q", cmd.Args)
	}
	wantEnv := []string{
		`SystemRoot=D:\WINDOWS`,
		`windir=D:\WINDOWS`,
		`SystemDrive=D:`,
		`ComSpec=D:\WINDOWS\System32\cmd.exe`,
		`PATH=D:\WINDOWS\System32;D:\WINDOWS;D:\WINDOWS\System32\Wbem;D:\WINDOWS\System32\WindowsPowerShell\v1.0`,
		`PSModulePath=D:\WINDOWS\System32\WindowsPowerShell\v1.0\Modules`,
	}
	if !reflect.DeepEqual(cmd.Env, wantEnv) {
		t.Fatalf("env\n got %q\nwant %q", cmd.Env, wantEnv)
	}
	_, err = recipeCommand(context.Background(), func() (string, error) { return "", errors.New("GetSystemWindowsDirectoryW: access denied") }, "Get-Date")
	if want := "Windows PowerShell could not be located (GetSystemWindowsDirectoryW: access denied); restart alcove-agent and retry"; err == nil || err.Error() != want {
		t.Fatalf("err %v", err)
	}
}

func TestCmdExeLineWrapsCommandInOuterQuotes(t *testing.T) {
	for cmdline, want := range map[string]string{
		`dir`:                         `cmd.exe /D /S /C "dir"`,
		`echo hello & dir "C:\a b"`:   `cmd.exe /D /S /C "echo hello & dir "C:\a b""`,
		`"C:\a b\x.exe" /C "echo ok"`: `cmd.exe /D /S /C ""C:\a b\x.exe" /C "echo ok""`,
		`"C:\a b\x.exe"`:              `cmd.exe /D /S /C ""C:\a b\x.exe""`,
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
