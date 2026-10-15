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

func TestExecCmdDoesNotRunTheAutoRunCommandOfTheAccount(t *testing.T) {
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

	c, _ := newRPCClient(t, Options{})
	res := c.ok("exec.run", proto.Message{"cmd": "echo ok", "shell": "cmd"})
	if got := strings.TrimSpace(res.String("stdout")); got != "ok" || res.Int("code") != 0 {
		t.Fatalf("exec.run printed %q, stderr %q, code %d", got, res.String("stderr"), res.Int("code"))
	}
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("exec.run with shell cmd ran the AutoRun command")
	}
}
