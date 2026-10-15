//go:build !windows

package server

import (
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

func TestLaunchRunsInTheProgramDirectoryWithArgsAndEnv(t *testing.T) {
	home := t.TempDir()
	c, _ := newRPCClient(t, Options{HomeDir: home})
	out := filepath.Join(home, "out.txt")
	script := `printf '%s|%s|%s' "$PWD" "$1" "$ALCOVE_LAUNCH_TEST" > "$0"`
	c.ok("app.launch", proto.Message{"path": "/bin/sh", "args": []string{"-c", script, out, "두 번째"},
		"env": map[string]any{"ALCOVE_LAUNCH_TEST": "set"}, "wait_window_ms": 0})
	c.event("process.exited")
	got := c.ok("fs.read", proto.Message{"path": out})
	text := string(decode(t, got))
	parts := strings.SplitN(text, "|", 3)
	wantDir, _ := filepath.EvalSymlinks("/bin")
	gotDir, _ := filepath.EvalSymlinks(parts[0])
	if len(parts) != 3 || gotDir != wantDir || parts[1] != "두 번째" || parts[2] != "set" {
		t.Fatalf("the program saw %q", text)
	}
	c.events = nil
	c.ok("app.launch", proto.Message{"path": "/bin/sh", "args": []string{"-c", script, out, "x"}, "cwd": "~", "wait_window_ms": 0})
	c.event("process.exited")
	got = c.ok("fs.read", proto.Message{"path": out})
	if text := string(decode(t, got)); !strings.HasSuffix(strings.SplitN(text, "|", 2)[0], filepath.Base(home)) {
		t.Fatalf("with cwd ~ the program saw %q", text)
	}
}

// exitProgram returns the app.launch path and args of a program that exits
// with code.
func exitProgram(code int) (string, []string) {
	return "sh", []string{"-c", "exit " + strconv.Itoa(code)}
}
