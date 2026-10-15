//go:build !windows

package server

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
	"github.com/YangTaeyoung/alcove/guest-tools/internal/session"
)

// linkedHome returns a session home and a folder outside it that holds
// shadow, a file with the text "secret".
func linkedHome(t *testing.T) (home, outside string) {
	t.Helper()
	base := t.TempDir()
	home, outside = filepath.Join(base, "home"), filepath.Join(base, "etc")
	for _, d := range []string{home, outside} {
		if err := os.Mkdir(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(outside, "shadow"), []byte("secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	return home, outside
}

// untouched fails the test when outside holds anything but shadow with its
// text.
func untouched(t *testing.T, outside string) {
	t.Helper()
	entries, err := os.ReadDir(outside)
	if err != nil || len(entries) != 1 || entries[0].Name() != "shadow" {
		t.Fatalf("the folder outside the home holds %v (%v)", entries, err)
	}
	if b, _ := os.ReadFile(filepath.Join(outside, "shadow")); string(b) != "secret" {
		t.Fatalf("shadow holds %q", b)
	}
}

func TestDropThroughALinkedDownloadsFolderFails(t *testing.T) {
	home, outside := linkedHome(t)
	symlink(t, outside, filepath.Join(home, "Downloads"))
	c := sessionClient(t, session.Session{User: "alcove", Home: home}, true)
	payload := []byte("APT::Update::Pre-Invoke {\"id\"};")
	sum := sha256.Sum256(payload)
	send(t, c.w, proto.Message{"t": "file.begin", "id": "d1", "name": "build-log", "size": len(payload), "dest": "downloads"})
	send(t, c.w, proto.Message{"t": "file.chunk", "id": "d1", "data": base64.StdEncoding.EncodeToString(payload)})
	send(t, c.w, proto.Message{"t": "file.end", "id": "d1", "sha256": hex.EncodeToString(sum[:])})
	done := expect(t, c.r, "file.done")
	if done.String("error") == "" {
		t.Fatalf("file.done %v", done)
	}
	untouched(t, outside)
}

func TestWritesThroughLinksThatLeaveTheHomeFail(t *testing.T) {
	home, outside := linkedHome(t)
	symlink(t, filepath.Join(outside, "shadow"), filepath.Join(home, "x"))
	symlink(t, outside, filepath.Join(home, "d"))
	c := sessionClient(t, session.Session{User: "alcove", Home: home}, true)
	data := base64.StdEncoding.EncodeToString([]byte("host text"))
	for _, p := range []string{"~/x", "x", filepath.Join(home, "x")} {
		if res := c.call("fs.write", proto.Message{"path": p, "data": data, "truncate": true}); res["ok"] != false {
			t.Fatalf("fs.write %s %v", p, res)
		}
		if res := c.call("fs.write", proto.Message{"path": p, "data": data, "append": true}); res["ok"] != false {
			t.Fatalf("fs.write append %s %v", p, res)
		}
	}
	if res := c.call("fs.write", proto.Message{"path": "d/new.txt", "data": data, "mkdirs": true}); res["ok"] != false {
		t.Fatalf("fs.write into a linked folder %v", res)
	}
	if res := c.call("fs.write", proto.Message{"path": "d/sub/new.txt", "data": data, "mkdirs": true}); res["ok"] != false {
		t.Fatalf("fs.write with mkdirs below a linked folder %v", res)
	}
	if res := c.call("fs.mkdir", proto.Message{"path": "d/made"}); res["ok"] != false {
		t.Fatalf("fs.mkdir below a linked folder %v", res)
	}
	if res := c.call("fs.delete", proto.Message{"path": "d/shadow"}); res["ok"] != false {
		t.Fatalf("fs.delete below a linked folder %v", res)
	}
	if err := os.WriteFile(filepath.Join(home, "part"), []byte("p"), 0o644); err != nil {
		t.Fatal(err)
	}
	if res := c.call("fs.rename", proto.Message{"from": "part", "to": "d/shadow", "overwrite": true}); res["ok"] != false {
		t.Fatalf("fs.rename into a linked folder %v", res)
	}
	untouched(t, outside)
}

func TestLinksThatStayInTheHomeAreFollowed(t *testing.T) {
	home, _ := linkedHome(t)
	if err := os.Mkdir(filepath.Join(home, "real"), 0o755); err != nil {
		t.Fatal(err)
	}
	symlink(t, "real", filepath.Join(home, "inside"))
	c := sessionClient(t, session.Session{User: "alcove", Home: home}, true)
	c.ok("fs.write", proto.Message{"path": "inside/a.txt", "data": base64.StdEncoding.EncodeToString([]byte("a")), "truncate": true})
	if b, err := os.ReadFile(filepath.Join(home, "real", "a.txt")); err != nil || string(b) != "a" {
		t.Fatalf("real/a.txt %q %v", b, err)
	}
}

func TestRenameAcrossTheHomeBoundaryIsRefused(t *testing.T) {
	home, outside := linkedHome(t)
	if err := os.WriteFile(filepath.Join(home, "a.txt"), []byte("a"), 0o644); err != nil {
		t.Fatal(err)
	}
	c := sessionClient(t, session.Session{User: "alcove", Home: home}, true)
	res := c.call("fs.rename", proto.Message{"from": "a.txt", "to": filepath.Join(outside, "a.txt")})
	want := "'" + filepath.Join(home, "a.txt") + "' and '" + filepath.Join(outside, "a.txt") +
		"' lie on different sides of the home folder of the desktop user; rename within it or outside it, or copy the file"
	if res["ok"] != false || res["error"] != want {
		t.Fatalf("fs.rename %v", res)
	}
	untouched(t, outside)
}

func TestHomeWritesCreateFoldersAndFiles(t *testing.T) {
	home, _ := linkedHome(t)
	c := sessionClient(t, session.Session{User: "alcove", Home: home}, true)
	data := base64.StdEncoding.EncodeToString([]byte("x"))
	c.ok("fs.write", proto.Message{"path": "proj/src/main.c", "data": data, "mkdirs": true, "truncate": true})
	c.ok("fs.write", proto.Message{"path": "proj/src/main.c", "data": data, "append": true})
	c.ok("fs.mkdir", proto.Message{"path": "proj/out/bin"})
	c.ok("fs.rename", proto.Message{"from": "proj/src/main.c", "to": "proj/out/main.c"})
	if b, _ := os.ReadFile(filepath.Join(home, "proj", "out", "main.c")); string(b) != "xx" {
		t.Fatalf("main.c %q", b)
	}
	if fi, err := os.Stat(filepath.Join(home, "proj", "out", "bin")); err != nil || !fi.IsDir() {
		t.Fatalf("bin %v", err)
	}
	if !c.ok("fs.delete", proto.Message{"path": "proj", "recursive": true}).Bool("deleted") {
		t.Fatal("proj not deleted")
	}
	if _, err := os.Stat(filepath.Join(home, "proj")); err == nil {
		t.Fatal("proj is still there")
	}
}
