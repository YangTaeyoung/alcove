//go:build windows

package server

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

// adminShare returns path, which starts with a drive letter, through the
// administrative share of its drive on host.
func adminShare(host, path string) string {
	return `\\` + host + `\` + path[:1] + `$` + path[2:]
}

func TestFsDeleteRefusesTheHomeDirectoryThroughTheAdminShare(t *testing.T) {
	base := t.TempDir()
	home := filepath.Join(base, "home")
	if err := os.MkdirAll(filepath.Join(home, "keep"), 0o755); err != nil {
		t.Fatal(err)
	}
	if len(home) < 3 || home[1] != ':' {
		t.Skipf("the temporary folder %s has no drive letter", home)
	}
	if _, err := os.Stat(adminShare("localhost", home)); err != nil {
		t.Skipf("the administrative share is not reachable (%v); the Server service may be off", err)
	}
	held, err := os.Open(home)
	if err != nil {
		t.Fatal(err)
	}
	defer held.Close()
	inside := exec.Command(systemProgram("PING.EXE"), "-n", "60", "127.0.0.1")
	inside.Dir = home
	hideWindow(inside)
	if err := inside.Start(); err != nil {
		t.Fatal(err)
	}
	exited := make(chan struct{})
	go func() { inside.Wait(); close(exited) }()
	t.Cleanup(func() { inside.Process.Kill(); <-exited })
	c, _ := newRPCClient(t, Options{HomeDir: home})
	want := "it is the home directory or contains it; delete its contents instead, or use exec.run if this is intended"
	for _, tc := range []struct {
		path      string
		recursive bool
	}{
		{adminShare("localhost", home), true},
		{adminShare("127.0.0.1", home), true},
		{`\\?\UNC\localhost\` + home[:1] + `$` + home[2:], true},
		{adminShare("localhost", base), false},
		{adminShare("localhost", home[:3]), false},
		{adminShare("127.0.0.1", home[:3]), false},
	} {
		res := c.call("fs.delete", proto.Message{"path": tc.path, "recursive": tc.recursive})
		if res["ok"] != false || res.String("error") != "refusing to delete '"+filepath.Clean(tc.path)+"': "+want {
			t.Fatalf("%q recursive=%v: %v", tc.path, tc.recursive, res)
		}
	}
	if _, err := os.Stat(filepath.Join(home, "keep")); err != nil {
		t.Fatalf("home content deleted: %v", err)
	}
}
