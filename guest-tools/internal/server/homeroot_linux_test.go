//go:build linux

package server

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"os"
	"path/filepath"
	"syscall"
	"testing"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
	"github.com/YangTaeyoung/alcove/guest-tools/internal/session"
)

// owner returns the user and group ids of path, without following a link.
func owner(t *testing.T, path string) (int, int) {
	t.Helper()
	fi, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	st := fi.Sys().(*syscall.Stat_t)
	return int(st.Uid), int(st.Gid)
}

func TestEntriesCreatedInTheHomeBelongToTheSessionUser(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("giving files to another user needs root")
	}
	home := t.TempDir()
	if err := os.Chmod(home, 0o755); err != nil {
		t.Fatal(err)
	}
	existing := filepath.Join(home, "kept.txt")
	if err := os.WriteFile(existing, []byte("k"), 0o644); err != nil {
		t.Fatal(err)
	}
	const uid, gid = 65534, 65534
	c := sessionClient(t, session.Session{User: "nobody", UID: uid, GID: gid, Home: home}, true)
	data := base64.StdEncoding.EncodeToString([]byte("x"))
	c.ok("fs.write", proto.Message{"path": "proj/src/main.c.alcove-part", "data": data, "mkdirs": true, "truncate": true})
	c.ok("fs.rename", proto.Message{"from": "proj/src/main.c.alcove-part", "to": "proj/src/main.c"})
	c.ok("fs.mkdir", proto.Message{"path": "proj/out/bin"})
	c.ok("fs.write", proto.Message{"path": "kept.txt", "data": data, "append": true})
	payload := []byte("drop")
	sum := sha256.Sum256(payload)
	send(t, c.w, proto.Message{"t": "file.begin", "id": "d1", "name": "drop.bin", "size": len(payload), "dest": "downloads"})
	send(t, c.w, proto.Message{"t": "file.chunk", "id": "d1", "data": base64.StdEncoding.EncodeToString(payload)})
	send(t, c.w, proto.Message{"t": "file.end", "id": "d1", "sha256": hex.EncodeToString(sum[:])})
	if done := expect(t, c.r, "file.done"); done.String("error") != "" {
		t.Fatalf("file.done %v", done)
	}
	for _, rel := range []string{"proj", "proj/src", "proj/src/main.c", "proj/out", "proj/out/bin", "Downloads", "Downloads/drop.bin"} {
		if u, g := owner(t, filepath.Join(home, rel)); u != uid || g != gid {
			t.Errorf("%s belongs to %d:%d", rel, u, g)
		}
	}
	if u, _ := owner(t, existing); u != 0 {
		t.Errorf("kept.txt, which existed, now belongs to %d", u)
	}
	if fi, _ := os.Stat(filepath.Join(home, "proj", "src", "main.c")); fi.Mode().Perm() != 0o644 {
		t.Errorf("main.c mode %v", fi.Mode())
	}
}
