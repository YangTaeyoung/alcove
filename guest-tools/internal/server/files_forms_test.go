package server

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

func TestFsDeleteRefusesTheHomeDirectoryReachedThroughALinkedParent(t *testing.T) {
	base := t.TempDir()
	home := filepath.Join(base, "home")
	os.MkdirAll(filepath.Join(home, "keep"), 0o755)
	c, _ := newRPCClient(t, Options{HomeDir: home})
	link := filepath.Join(t.TempDir(), "to-base")
	symlink(t, base, link)
	for _, p := range []string{filepath.Join(link, "home"), link + string(filepath.Separator) + "home" + string(filepath.Separator), link} {
		res := c.call("fs.delete", proto.Message{"path": p, "recursive": true})
		if p == link {
			if res["ok"] != true || res["deleted"] != true {
				t.Fatalf("deleting the link itself: %v", res)
			}
			continue
		}
		if res["ok"] != false || !strings.Contains(res.String("error"), "it is the home directory or contains it") {
			t.Fatalf("%s: %v", p, res)
		}
	}
	if _, err := os.Stat(filepath.Join(home, "keep")); err != nil {
		t.Fatalf("home content deleted: %v", err)
	}
}

func TestFsStatThroughAFileAnswersMissing(t *testing.T) {
	c, home := fsHome(t)
	os.WriteFile(filepath.Join(home, "f.txt"), []byte("x"), 0o644)
	res := c.call("fs.stat", proto.Message{"path": "f.txt/inner"})
	if res["ok"] != true || res["exists"] != false {
		t.Fatalf("res %v", res)
	}
}

func TestFsListCountsEntriesItCouldNotRead(t *testing.T) {
	if runtime.GOOS == "windows" || os.Geteuid() == 0 {
		t.Skip("needs a folder this user cannot read")
	}
	c, home := fsHome(t)
	closed := filepath.Join(home, "d", "closed")
	os.MkdirAll(closed, 0o755)
	os.WriteFile(filepath.Join(closed, "x"), []byte("x"), 0o644)
	os.Chmod(closed, 0)
	t.Cleanup(func() { os.Chmod(closed, 0o755) })
	res := c.ok("fs.list", proto.Message{"path": "d", "recursive": true})
	if res.Int("skipped") != 1 || len(res["entries"].([]any)) != 1 {
		t.Fatalf("res %v", res)
	}
	res = c.ok("fs.list", proto.Message{"path": "d"})
	if res.Has("skipped") {
		t.Fatalf("a listing of readable entries %v", res)
	}
}

func TestFsReadRefusesAFileThatIsNotRegular(t *testing.T) {
	c, home := fsHome(t)
	fifo := filepath.Join(home, "fifo")
	if err := mkfifo(fifo); err != nil {
		t.Skipf("no FIFO here: %v", err)
	}
	want := fmt.Sprintf("'%s' is not a regular file; fs.read, fs.tail and sha256 read regular files only", fifo)
	for _, call := range []struct {
		op     string
		fields proto.Message
	}{
		{"fs.read", proto.Message{"path": "fifo"}},
		{"fs.tail", proto.Message{"path": "fifo"}},
		{"fs.stat", proto.Message{"path": "fifo", "sha256": true}},
	} {
		res := c.call(call.op, call.fields)
		if res["ok"] != false || !strings.Contains(res.String("error"), want) {
			t.Fatalf("%s: %v", call.op, res)
		}
	}
}

func TestUTF32ByteOrderMarkIsNotUTF16(t *testing.T) {
	c, home := fsHome(t)
	os.WriteFile(filepath.Join(home, "u32.txt"), []byte{0xFF, 0xFE, 0, 0, 'a', 0, 0, 0}, 0o644)
	os.WriteFile(filepath.Join(home, "u16.txt"), []byte{0xFF, 0xFE, 'a', 0}, 0o644)
	if res := c.ok("fs.read", proto.Message{"path": "u32.txt"}); res.Has("encoding") {
		t.Fatalf("UTF-32 file %v", res)
	}
	if res := c.ok("fs.tail", proto.Message{"path": "u32.txt"}); res.Has("encoding") {
		t.Fatalf("UTF-32 tail %v", res)
	}
	if res := c.ok("fs.read", proto.Message{"path": "u16.txt"}); res.String("encoding") != "utf-16le" {
		t.Fatalf("UTF-16 file %v", res)
	}
}

func TestFsTailUTF16KeepsSurrogatePairsWhole(t *testing.T) {
	c, home := fsHome(t)
	body := utf16le(strings.Repeat("😀\n", 50000))
	os.WriteFile(filepath.Join(home, "emoji.log"), append([]byte{0xFF, 0xFE}, body...), 0o644)
	res := c.ok("fs.tail", proto.Message{"path": "emoji.log", "lines": 1000000})
	got := decode(t, res)
	if len(got) > 262144 || len(got)%6 != 0 || !bytes.HasPrefix(got, utf16le("😀\n")) {
		t.Fatalf("tail of %d bytes starts % x", len(got), got[:6])
	}
}

func TestWindowsPathFormsThatDependOnACurrentFolderAreRefused(t *testing.T) {
	cases := map[string]string{
		`C:foo`:   `'C:foo' is relative to the current folder of drive C:; pass a full path such as C:\foo`,
		`d:`:      `'d:' is relative to the current folder of drive d:; pass a full path such as d:\`,
		`\x`:      `'\x' starts at the root of the agent's current drive; pass a full path with its drive, such as C:\x`,
		`/x/y`:    `'/x/y' starts at the root of the agent's current drive; pass a full path with its drive, such as C:\x\y`,
		`C:\foo`:  "",
		`C:/foo`:  "",
		`\\srv\s`: "",
		`//srv/s`: "",
		`a\b`:     "",
		`~\b`:     "",
	}
	for p, want := range cases {
		err := windowsPathFormError(p)
		if (want == "" && err != nil) || (want != "" && (err == nil || err.Error() != want)) {
			t.Errorf("windowsPathFormError(%q) = %v, expected %q", p, err, want)
		}
	}
}
