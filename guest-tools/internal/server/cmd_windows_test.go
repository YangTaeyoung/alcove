//go:build windows

package server

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

// plantAutoRun sets the AutoRun value of the account's Command Processor
// key to a command that writes a marker file, removes it when the test ends,
// checks that cmd.exe without /D runs it, and returns the marker's path. The
// test is skipped when the account already has such a value.
func plantAutoRun(t *testing.T) string {
	t.Helper()
	const key = `HKCU\Software\Microsoft\Command Processor`
	reg := systemProgram("reg.exe")
	if exec.Command(reg, "query", key, "/v", "AutoRun").Run() == nil {
		t.Skipf(`%s\AutoRun is already set for this account`, key)
	}
	marker := filepath.Join(t.TempDir(), "autorun.txt")
	if out, err := exec.Command(reg, "add", key, "/v", "AutoRun", "/t", "REG_SZ", "/d", `echo autorun> "`+marker+`"`, "/f").CombinedOutput(); err != nil {
		t.Fatalf("reg add: %v: %s", err, out)
	}
	t.Cleanup(func() { _ = exec.Command(reg, "delete", key, "/v", "AutoRun", "/f").Run() })
	if out, err := exec.Command(systemProgram("cmd.exe"), "/c", "echo", "control").CombinedOutput(); err != nil {
		t.Fatalf("cmd /c: %v: %s", err, out)
	}
	if _, err := os.Stat(marker); err != nil {
		t.Fatalf("cmd.exe without /D did not run the AutoRun command: %v", err)
	}
	if err := os.Remove(marker); err != nil {
		t.Fatal(err)
	}
	return marker
}

// expectNoAutoRun fails the test when the AutoRun command wrote marker.
func expectNoAutoRun(t *testing.T, what, marker string) {
	t.Helper()
	if _, err := os.Stat(marker); err == nil {
		t.Fatalf("%s ran the AutoRun command", what)
	}
}

func TestExecCmdDoesNotRunTheAutoRunCommandOfTheAccount(t *testing.T) {
	marker := plantAutoRun(t)
	c, _ := newRPCClient(t, Options{})
	res := c.ok("exec.run", proto.Message{"cmd": "echo ok", "shell": "cmd"})
	if got := strings.TrimSpace(res.String("stdout")); got != "ok" || res.Int("code") != 0 {
		t.Fatalf("exec.run printed %q, stderr %q, code %d", got, res.String("stderr"), res.Int("code"))
	}
	expectNoAutoRun(t, "exec.run with shell cmd", marker)
}

func TestABatchFileRunsWithItsArgumentsAndWithoutTheAutoRunCommand(t *testing.T) {
	marker := plantAutoRun(t)
	dir := t.TempDir()
	script := filepath.Join(dir, "alcovebatch.bat")
	out := filepath.Join(dir, "out.txt")
	body := "@echo [%~1][%~2][%~3]\r\n@echo [%~1][%~2][%~3]> \"" + out + "\"\r\n"
	if err := os.WriteFile(script, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	args := []any{"a b", "100%", "%PATH%"}
	const want = "[a b][100%][%PATH%]"
	c, _ := newRPCClient(t, Options{})

	res := c.ok("exec.run", proto.Message{"argv": append([]any{script}, args...)})
	if got := strings.TrimSpace(res.String("stdout")); got != want || res.Int("code") != 0 {
		t.Fatalf("exec.run of the batch file printed %q, stderr %q, code %d", got, res.String("stderr"), res.Int("code"))
	}
	expectNoAutoRun(t, "exec.run of a batch file", marker)

	res = c.ok("exec.run", proto.Message{"argv": append([]any{"alcovebatch"}, args...), "env": map[string]any{"PATH": dir}})
	if got := strings.TrimSpace(res.String("stdout")); got != want || res.Int("code") != 0 {
		t.Fatalf("exec.run of the batch file by its name printed %q, stderr %q, code %d", got, res.String("stderr"), res.Int("code"))
	}
	expectNoAutoRun(t, "exec.run of a batch file by its name", marker)

	res = c.call("exec.run", proto.Message{"argv": []any{script, "a\nb"}})
	if res["ok"] != false || !strings.Contains(res.String("error"), "holds a line break or NUL") {
		t.Fatalf("an argument with a line break gave %v", res)
	}

	if err := os.Remove(out); err != nil {
		t.Fatal(err)
	}
	c.ok("app.launch", proto.Message{"path": script, "args": args, "wait_window_ms": 0})
	ev := c.event("process.exited")
	if !strings.EqualFold(ev.String("path"), script) || ev.Int("code") != 0 {
		t.Fatalf("the launched batch file ended with %v", ev)
	}
	b, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSpace(string(b)); got != want {
		t.Fatalf("the launched batch file wrote %q", got)
	}
	expectNoAutoRun(t, "app.launch of a batch file", marker)
}
