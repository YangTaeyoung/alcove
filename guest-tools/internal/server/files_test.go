package server

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

func b64(b []byte) string { return base64.StdEncoding.EncodeToString(b) }

func decode(t *testing.T, res proto.Message) []byte {
	t.Helper()
	b, err := base64.StdEncoding.DecodeString(res.String("data"))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func fsHome(t *testing.T) (*rpcClient, string) {
	t.Helper()
	home := t.TempDir()
	c, _ := newRPCClient(t, Options{HomeDir: home})
	return c, home
}

func TestFsPathForms(t *testing.T) {
	c, home := fsHome(t)
	abs := filepath.Join(t.TempDir(), "abs.txt")
	if err := os.WriteFile(abs, []byte("a"), 0o644); err != nil {
		t.Fatal(err)
	}

	c.ok("fs.write", proto.Message{"path": "~/a b/한글.txt", "data": b64([]byte("x")), "mkdirs": true})
	if got, err := os.ReadFile(filepath.Join(home, "a b", "한글.txt")); err != nil || string(got) != "x" {
		t.Fatalf("tilde write: %q %v", got, err)
	}
	res := c.ok("fs.stat", proto.Message{"path": "a b/한글.txt"})
	if res["exists"] != true || res.String("path") != filepath.Join(home, "a b", "한글.txt") {
		t.Fatalf("relative stat %v", res)
	}
	res = c.ok("fs.stat", proto.Message{"path": "~"})
	if res["dir"] != true || res.String("path") != home {
		t.Fatalf("home stat %v", res)
	}
	res = c.ok("fs.stat", proto.Message{"path": abs})
	if res["exists"] != true || res.Int("size") != 1 || res.String("path") != abs {
		t.Fatalf("absolute stat %v", res)
	}

	res = c.call("fs.write", proto.Message{"path": "nodir/f.txt", "data": b64([]byte("x"))})
	if res["ok"] != false || !strings.Contains(res.String("error"), "mkdirs") {
		t.Fatalf("write without mkdirs %v", res)
	}
	res = c.call("fs.stat", proto.Message{"path": ""})
	if res["ok"] != false || !strings.Contains(res.String("error"), "missing path") {
		t.Fatalf("empty path %v", res)
	}
}

func TestFsWriteReadRoundTrip(t *testing.T) {
	c, _ := fsHome(t)
	data := make([]byte, 600000)
	rand.Read(data)
	for i, off := range []int{0, 262144, 524288} {
		end := off + 262144
		if end > len(data) {
			end = len(data)
		}
		req := proto.Message{"path": "big.bin", "data": b64(data[off:end]), "offset": off}
		if i == 0 {
			req["truncate"] = true
		}
		res := c.ok("fs.write", req)
		if res.Int("size") != end {
			t.Fatalf("size after write %d: %v", i, res)
		}
	}

	var got []byte
	var last proto.Message
	for off := 0; ; {
		last = c.ok("fs.read", proto.Message{"path": "big.bin", "offset": off, "length": 200000})
		piece := decode(t, last)
		got = append(got, piece...)
		off += len(piece)
		if last["eof"] == true {
			break
		}
		if len(piece) == 0 {
			t.Fatal("empty piece before eof")
		}
	}
	if !bytes.Equal(got, data) || last.Int("size") != len(data) {
		t.Fatalf("round trip mismatch: %d bytes", len(got))
	}

	res := c.ok("fs.read", proto.Message{"path": "big.bin", "length": 1 << 20})
	if n := len(decode(t, res)); n != 262144 || res["eof"] == true {
		t.Fatalf("capped read %d eof=%v", n, res["eof"])
	}
}

func TestFsAppend(t *testing.T) {
	c, home := fsHome(t)
	c.ok("fs.write", proto.Message{"path": "log.txt", "data": b64([]byte("one,")), "append": true})
	res := c.ok("fs.write", proto.Message{"path": "log.txt", "data": b64([]byte("two")), "append": true, "offset": 0})
	if res.Int("size") != 7 {
		t.Fatalf("size %v", res)
	}
	got, _ := os.ReadFile(filepath.Join(home, "log.txt"))
	if string(got) != "one,two" {
		t.Fatalf("content %q", got)
	}
}

func TestFsStat(t *testing.T) {
	c, home := fsHome(t)
	res := c.call("fs.stat", proto.Message{"path": "missing"})
	if res["ok"] != true || res["exists"] != false {
		t.Fatalf("missing %v", res)
	}

	body := []byte("hello digest")
	os.WriteFile(filepath.Join(home, "f.txt"), body, 0o644)
	sum := sha256.Sum256(body)
	res = c.ok("fs.stat", proto.Message{"path": "f.txt", "sha256": true})
	if res["exists"] != true || res["dir"] != false || res.Int("size") != len(body) ||
		res.String("sha256") != hex.EncodeToString(sum[:]) || res.String("mtime") == "" {
		t.Fatalf("file %v", res)
	}
	if !strings.HasSuffix(res.String("mtime"), "Z") {
		t.Fatalf("mtime not UTC: %v", res["mtime"])
	}
	res = c.ok("fs.stat", proto.Message{"path": "f.txt"})
	if res.Has("sha256") {
		t.Fatalf("digest without request %v", res)
	}

	os.Mkdir(filepath.Join(home, "d"), 0o755)
	res = c.ok("fs.stat", proto.Message{"path": "d"})
	if res["exists"] != true || res["dir"] != true || res.Int("size") != 0 {
		t.Fatalf("dir %v", res)
	}
}

func entryMap(res proto.Message) map[string]map[string]any {
	out := map[string]map[string]any{}
	list, _ := res["entries"].([]any)
	for _, e := range list {
		m := e.(map[string]any)
		out[m["name"].(string)] = m
	}
	return out
}

func TestFsListRecursive(t *testing.T) {
	c, home := fsHome(t)
	os.MkdirAll(filepath.Join(home, "t", "sub", "deep"), 0o755)
	os.WriteFile(filepath.Join(home, "t", "a.txt"), []byte("aa"), 0o644)
	os.WriteFile(filepath.Join(home, "t", "sub", "b.txt"), []byte("b"), 0o644)
	os.WriteFile(filepath.Join(home, "t", "sub", "deep", "c.txt"), nil, 0o644)

	res := c.ok("fs.list", proto.Message{"path": "t", "recursive": true})
	list, _ := res["entries"].([]any)
	var names []string
	for _, e := range list {
		names = append(names, e.(map[string]any)["name"].(string))
	}
	want := []string{"a.txt", "sub", "sub/b.txt", "sub/deep", "sub/deep/c.txt"}
	if strings.Join(names, "|") != strings.Join(want, "|") || res["truncated"] != false {
		t.Fatalf("names %v truncated=%v", names, res["truncated"])
	}
	em := entryMap(res)
	if em["sub"]["dir"] != true || em["a.txt"]["dir"] != false || int(em["a.txt"]["size"].(float64)) != 2 {
		t.Fatalf("entries %v", em)
	}
	if _, has := em["a.txt"]["sha256"]; has {
		t.Fatalf("digest without request %v", em["a.txt"])
	}

	res = c.ok("fs.list", proto.Message{"path": "t", "recursive": true, "sha256": true})
	em = entryMap(res)
	sum := sha256.Sum256([]byte("aa"))
	if em["a.txt"]["sha256"] != hex.EncodeToString(sum[:]) {
		t.Fatalf("file digest %v", em["a.txt"])
	}
	if _, has := em["sub"]["sha256"]; has {
		t.Fatalf("directory digest %v", em["sub"])
	}

	res = c.ok("fs.list", proto.Message{"path": "t"})
	em = entryMap(res)
	if len(em) != 2 || em["a.txt"] == nil || em["sub"] == nil {
		t.Fatalf("shallow %v", em)
	}

	res = c.call("fs.list", proto.Message{"path": "nope"})
	if res["ok"] != false || !strings.Contains(res.String("error"), "does not exist") || !strings.Contains(res.String("error"), "nope") {
		t.Fatalf("missing dir %v", res)
	}

	os.Mkdir(filepath.Join(home, "many"), 0o755)
	for i := 0; i < 5001; i++ {
		os.WriteFile(filepath.Join(home, "many", fmt.Sprintf("f%05d", i)), nil, 0o644)
	}
	res = c.ok("fs.list", proto.Message{"path": "many"})
	if list, _ := res["entries"].([]any); len(list) != 5000 || res["truncated"] != true {
		t.Fatalf("truncation: %d entries truncated=%v", len(list), res["truncated"])
	}
}

func TestFsTail(t *testing.T) {
	c, home := fsHome(t)
	var sb strings.Builder
	for i := 1; i <= 1000; i++ {
		fmt.Fprintf(&sb, "line %d\n", i)
	}
	os.WriteFile(filepath.Join(home, "big.log"), []byte(sb.String()), 0o644)
	res := c.ok("fs.tail", proto.Message{"path": "big.log", "lines": 5})
	want := "line 996\nline 997\nline 998\nline 999\nline 1000\n"
	if string(decode(t, res)) != want || res.Int("size") != sb.Len() {
		t.Fatalf("tail %q", decode(t, res))
	}

	os.WriteFile(filepath.Join(home, "p.log"), []byte("a\nb\nc"), 0o644)
	res = c.ok("fs.tail", proto.Message{"path": "p.log", "lines": 2})
	if string(decode(t, res)) != "b\nc" {
		t.Fatalf("partial last line %q", decode(t, res))
	}

	long := strings.Repeat("x\n", 200000)
	os.WriteFile(filepath.Join(home, "long.log"), []byte(long), 0o644)
	res = c.ok("fs.tail", proto.Message{"path": "long.log", "lines": 1000000})
	got := decode(t, res)
	if len(got) > 262144 || !bytes.HasPrefix(got, []byte("x\n")) || len(got)%2 != 0 {
		t.Fatalf("window tail %d bytes", len(got))
	}
	os.WriteFile(filepath.Join(home, "odd.log"), []byte(strings.Repeat("ab\n", 150000)), 0o644)
	res = c.ok("fs.tail", proto.Message{"path": "odd.log", "lines": 1000000})
	got = decode(t, res)
	if !bytes.HasPrefix(got, []byte("ab\n")) || len(got) > 262144 {
		t.Fatalf("partial first line kept: %q", got[:10])
	}

	res = c.call("fs.tail", proto.Message{"path": "gone.log"})
	if res["ok"] != false || !strings.Contains(res.String("error"), "gone.log") {
		t.Fatalf("missing %v", res)
	}
}

func TestFsReadErrors(t *testing.T) {
	c, home := fsHome(t)
	os.Mkdir(filepath.Join(home, "d"), 0o755)
	for _, p := range []string{"d", "gone.txt"} {
		res := c.call("fs.read", proto.Message{"path": p})
		if res["ok"] != false || !strings.Contains(res.String("error"), p) {
			t.Fatalf("read %s: %v", p, res)
		}
	}
}

func TestWriteToPartThenRename(t *testing.T) {
	c, home := fsHome(t)
	os.WriteFile(filepath.Join(home, "x"), []byte("old"), 0o644)
	c.ok("fs.write", proto.Message{"path": "x.part", "data": b64([]byte("new")), "truncate": true})

	res := c.call("fs.rename", proto.Message{"from": "x.part", "to": "x"})
	if res["ok"] != false || !strings.Contains(res.String("error"), "exists") {
		t.Fatalf("no overwrite %v", res)
	}
	if got, _ := os.ReadFile(filepath.Join(home, "x")); string(got) != "old" {
		t.Fatalf("destination changed %q", got)
	}

	res = c.ok("fs.rename", proto.Message{"from": "x.part", "to": "x", "overwrite": true})
	if res.String("path") != filepath.Join(home, "x") {
		t.Fatalf("path %v", res)
	}
	if got, _ := os.ReadFile(filepath.Join(home, "x")); string(got) != "new" {
		t.Fatalf("content %q", got)
	}
	if _, err := os.Stat(filepath.Join(home, "x.part")); !os.IsNotExist(err) {
		t.Fatalf("part file remains: %v", err)
	}

	os.Mkdir(filepath.Join(home, "dir"), 0o755)
	os.WriteFile(filepath.Join(home, "y"), nil, 0o644)
	res = c.call("fs.rename", proto.Message{"from": "y", "to": "dir", "overwrite": true})
	if res["ok"] != false || !strings.Contains(res.String("error"), "directory") {
		t.Fatalf("replace directory %v", res)
	}
}

func TestFsMkdir(t *testing.T) {
	c, home := fsHome(t)
	res := c.ok("fs.mkdir", proto.Message{"path": "a/b/c"})
	if res.String("path") != filepath.Join(home, "a", "b", "c") {
		t.Fatalf("path %v", res)
	}
	if st, err := os.Stat(filepath.Join(home, "a", "b", "c")); err != nil || !st.IsDir() {
		t.Fatalf("not created: %v", err)
	}
	c.ok("fs.mkdir", proto.Message{"path": "a/b/c"})
}

func TestFsDelete(t *testing.T) {
	c, home := fsHome(t)
	os.MkdirAll(filepath.Join(home, "d", "e"), 0o755)
	os.WriteFile(filepath.Join(home, "d", "e", "f"), []byte("x"), 0o644)

	res := c.call("fs.delete", proto.Message{"path": "d"})
	if res["ok"] != false || !strings.Contains(res.String("error"), "recursive") {
		t.Fatalf("non-empty %v", res)
	}
	res = c.ok("fs.delete", proto.Message{"path": "d", "recursive": true})
	if res["deleted"] != true {
		t.Fatalf("recursive %v", res)
	}
	if _, err := os.Stat(filepath.Join(home, "d")); !os.IsNotExist(err) {
		t.Fatalf("still there: %v", err)
	}
	res = c.ok("fs.delete", proto.Message{"path": "d"})
	if res["deleted"] != false {
		t.Fatalf("missing %v", res)
	}

	os.WriteFile(filepath.Join(home, "one"), nil, 0o644)
	res = c.ok("fs.delete", proto.Message{"path": "one"})
	if res["deleted"] != true {
		t.Fatalf("file %v", res)
	}
}

func TestFsGated(t *testing.T) {
	_, r, w, _ := startServerS(t, Options{Clipboard: &fakeClipboard{}, HomeDir: t.TempDir()})
	expect(t, r, "hello")
	w.Send(proto.Message{"t": "req", "id": 1, "op": "fs.stat", "path": "~"})
	res := expect(t, r, "res")
	if res["ok"] != false || res.String("error") != errExecDisabled {
		t.Fatalf("res %v", res)
	}
}
