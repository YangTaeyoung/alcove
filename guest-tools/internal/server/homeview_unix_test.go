//go:build !windows

package server

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
	"github.com/YangTaeyoung/alcove/guest-tools/internal/session"
)

func TestAnAbsoluteLinkInTheHomeIsRefusedAsSuch(t *testing.T) {
	home, _ := linkedHome(t)
	if err := os.Mkdir(filepath.Join(home, "real"), 0o755); err != nil {
		t.Fatal(err)
	}
	symlink(t, filepath.Join(home, "real"), filepath.Join(home, "abs"))
	c := sessionClient(t, session.Session{User: "alcove", Home: home}, true)
	res := c.call("fs.write", proto.Message{"path": "abs/a.txt", "data": base64.StdEncoding.EncodeToString([]byte("a")), "truncate": true})
	link := filepath.Join(home, "abs")
	want := "cannot open '" + filepath.Join(home, "abs", "a.txt") + "' for writing: '" + link + "' is a link with the absolute target '" +
		filepath.Join(home, "real") + "', and the agent follows only relative links inside the home folder of the desktop user; make it a relative link or pass the path it leads to"
	if res["ok"] != false || res["error"] != want {
		t.Fatalf("fs.write %v\nwant %s", res["error"], want)
	}
	if _, err := os.Stat(filepath.Join(home, "real", "a.txt")); err == nil {
		t.Fatal("the file was written through the absolute link")
	}
}

func TestAWriteThroughAHardLinkOfAnotherOwnerIsRefused(t *testing.T) {
	home, outside := linkedHome(t)
	secret := filepath.Join(outside, "shadow")
	if err := os.Link(secret, filepath.Join(home, "x")); err != nil {
		t.Skipf("hard links cannot be made here: %v", err)
	}
	c := sessionClient(t, session.Session{User: "alcove", UID: uint32(os.Getuid() + 4242), Home: home}, true)
	data := base64.StdEncoding.EncodeToString([]byte("host text"))
	for _, extra := range []proto.Message{{"truncate": true}, {"append": true}, {}} {
		req := proto.Message{"path": "x", "data": data}
		for k, v := range extra {
			req[k] = v
		}
		res := c.call("fs.write", req)
		want := "cannot open '" + filepath.Join(home, "x") + "' for writing: it has other hard links and does not belong to alcove, so it may be a file outside the home folder of the desktop user; write to that file's own path"
		if res["ok"] != false || res["error"] != want {
			t.Fatalf("fs.write %v %v", extra, res["error"])
		}
	}
	untouched(t, outside)
}

func TestARootHomeCountsAsNoHome(t *testing.T) {
	want, err := os.UserHomeDir()
	if err != nil {
		t.Skip("this user has no home directory")
	}
	for _, bad := range []string{"/", "relative/home"} {
		c := sessionClient(t, session.Session{User: "odd", UID: 4242, Home: bad}, true)
		if got := c.ok("fs.stat", proto.Message{"path": "~"}).String("path"); got != filepath.Clean(want) {
			t.Fatalf("with home %q fs.stat ~ = %q, want %q", bad, got, want)
		}
	}
}

func TestARequestReadsTheSessionOnce(t *testing.T) {
	home, outside := linkedHome(t)
	symlink(t, filepath.Join(outside, "shadow"), filepath.Join(home, "x"))
	var calls atomic.Int64
	_, r, w, _ := startServerS(t, Options{Clipboard: &fakeClipboard{}, AllowExec: true,
		Session: func() (session.Session, bool) {
			if calls.Add(1) == 1 {
				return session.Session{User: "alcove", Home: home}, true
			}
			return session.Session{}, false
		}})
	expect(t, r, "hello")
	c := &rpcClient{t: t, r: r, w: w}
	res := c.call("fs.write", proto.Message{"path": "x", "data": base64.StdEncoding.EncodeToString([]byte("host text")), "truncate": true})
	if res["ok"] != false || !strings.Contains(res.String("error"), "home folder of the desktop user") {
		t.Fatalf("fs.write %v", res)
	}
	untouched(t, outside)
}

func TestTheScopeCheckFindsARelativeProgramInTheLaunchFolder(t *testing.T) {
	home := t.TempDir()
	apps := filepath.Join(home, "apps")
	if err := os.Mkdir(apps, 0o755); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(home, "ran.txt")
	if err := os.WriteFile(filepath.Join(apps, "run.sh"), []byte("#!/bin/sh\necho ran > \""+out+"\"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	runner := filepath.Join(home, "runner")
	script := "#!/bin/sh\necho scoped > \"$HOME/runner-ran\"\nwhile [ \"$1\" != -- ]; do shift; done\nshift\nexec \"$@\"\n"
	if err := os.WriteFile(runner, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	c := sessionClient(t, session.Session{User: "alcove", Home: home, Env: []string{"HOME=" + home, "PATH=/usr/bin:/bin"}, ScopeRunner: runner, ScopeVersion: 259}, true)
	c.ok("app.launch", proto.Message{"path": "./run.sh", "cwd": "apps", "wait_window_ms": 0})
	c.event("process.exited")
	if b, _ := os.ReadFile(out); string(b) != "ran\n" {
		t.Fatalf("run.sh wrote %q", b)
	}
	if _, err := os.Stat(filepath.Join(home, "runner-ran")); err != nil {
		t.Fatal("run.sh did not start through the scope")
	}
}
