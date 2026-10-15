package server

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"unicode/utf16"

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

func TestFsWriteRefusesMoreThanOnePiece(t *testing.T) {
	c, home := fsHome(t)
	res := c.call("fs.write", proto.Message{"path": "big.bin", "data": b64(make([]byte, 262145))})
	want := "data is 262145 bytes; fs.write takes at most 262144 bytes, so write the rest with further calls"
	if res["ok"] != false || res.String("error") != want {
		t.Fatalf("res %v", res)
	}
	if _, err := os.Stat(filepath.Join(home, "big.bin")); err == nil {
		t.Fatal("the file was created")
	}
}

func TestFsWriteRefusesAppendWithTruncate(t *testing.T) {
	c, home := fsHome(t)
	os.WriteFile(filepath.Join(home, "f.txt"), []byte("kept"), 0o644)
	res := c.call("fs.write", proto.Message{"path": "f.txt", "data": b64([]byte("x")), "append": true, "truncate": true})
	if res["ok"] != false || res.String("error") != "pass append or truncate, not both" {
		t.Fatalf("res %v", res)
	}
	if got, _ := os.ReadFile(filepath.Join(home, "f.txt")); string(got) != "kept" {
		t.Fatalf("content %q", got)
	}
}

func TestFsWriteRefusesAnOffsetPastTheEnd(t *testing.T) {
	c, home := fsHome(t)
	path := filepath.Join(home, "f.txt")
	os.WriteFile(path, []byte("abc"), 0o644)
	res := c.call("fs.write", proto.Message{"path": "f.txt", "data": b64([]byte("x")), "offset": 4})
	if want := fmt.Sprintf("offset 4 lies past the end of '%s' (3 bytes); write from offset 3 or lower", path); res["ok"] != false || res.String("error") != want {
		t.Fatalf("res %v", res)
	}
	res = c.call("fs.write", proto.Message{"path": "f.txt", "data": b64([]byte("x")), "offset": 1, "truncate": true})
	if want := fmt.Sprintf("offset 1 lies past the end of '%s' (0 bytes after truncate); write from offset 0", path); res["ok"] != false || res.String("error") != want {
		t.Fatalf("res %v", res)
	}
	if got, _ := os.ReadFile(path); string(got) != "abc" {
		t.Fatalf("content %q", got)
	}
	if res := c.ok("fs.write", proto.Message{"path": "f.txt", "data": b64([]byte("d")), "offset": 3}); res.Int("size") != 4 {
		t.Fatalf("res %v", res)
	}
	res = c.call("fs.write", proto.Message{"path": "new.txt", "data": b64([]byte("x")), "offset": 2})
	if want := fmt.Sprintf("offset 2 lies past the end of '%s' (0 bytes); write from offset 0", filepath.Join(home, "new.txt")); res["ok"] != false || res.String("error") != want {
		t.Fatalf("res %v", res)
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

func TestOwnerName(t *testing.T) {
	const user = "S-1-5-21-1-2-3-1001"
	cases := map[string]string{
		"S-1-5-32-544":        "administrators",
		"S-1-5-18":            "system",
		user:                  "user",
		"S-1-5-21-1-2-3-1002": "S-1-5-21-1-2-3-1002",
		"S-1-5-32-545":        "S-1-5-32-545",
	}
	for sid, want := range cases {
		if got := ownerName(sid, user); got != want {
			t.Errorf("ownerName(%q) = %q, expected %q", sid, got, want)
		}
	}
	if got := ownerName("S-1-5-21-1-2-3-1001", ""); got != "S-1-5-21-1-2-3-1001" {
		t.Errorf("without a user SID: %q", got)
	}
}

func TestFsStatReportsTheOwnerOfTheEntryItself(t *testing.T) {
	c, home := fsHome(t)
	var asked []string
	saved := entryOwner
	entryOwner = func(path string) (string, bool) {
		asked = append(asked, path)
		return "administrators", true
	}
	t.Cleanup(func() { entryOwner = saved })
	os.WriteFile(filepath.Join(home, "f.txt"), []byte("x"), 0o644)
	symlink(t, filepath.Join(home, "gone"), filepath.Join(home, "dangling"))

	for _, name := range []string{"f.txt", "dangling"} {
		if res := c.ok("fs.stat", proto.Message{"path": name}); res.String("owner") != "administrators" {
			t.Fatalf("%s: %v", name, res)
		}
	}
	if res := c.ok("fs.stat", proto.Message{"path": "missing"}); res.Has("owner") {
		t.Fatalf("missing: %v", res)
	}
	want := []string{filepath.Join(home, "f.txt"), filepath.Join(home, "dangling")}
	if strings.Join(asked, "|") != strings.Join(want, "|") {
		t.Fatalf("owners read of %q, expected %q", asked, want)
	}
}

func TestFsStatHasNoOwnerOutsideWindows(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows reports owners")
	}
	c, home := fsHome(t)
	os.WriteFile(filepath.Join(home, "f.txt"), []byte("x"), 0o644)
	if res := c.ok("fs.stat", proto.Message{"path": "f.txt"}); res.Has("owner") {
		t.Fatalf("stat %v", res)
	}
}

func TestIsLink(t *testing.T) {
	links := []os.FileMode{os.ModeSymlink | 0o777, os.ModeSymlink | 0o666, os.ModeIrregular | 0o666}
	for _, m := range links {
		if !isLink(m) {
			t.Errorf("%v is not reported as a link", m)
		}
	}
	plain := []os.FileMode{0o644, os.ModeDir | 0o755, os.ModeDir | os.ModeIrregular | 0o777, os.ModeNamedPipe, os.ModeSocket, os.ModeDevice | os.ModeCharDevice}
	for _, m := range plain {
		if isLink(m) {
			t.Errorf("%v is reported as a link", m)
		}
	}
}

// symlink creates a symbolic link or skips the test where the system does not allow one.
func symlink(t *testing.T, target, link string) {
	t.Helper()
	if err := os.Symlink(target, link); err != nil {
		t.Skipf("symbolic links cannot be created here: %v", err)
	}
}

func TestFsStatReportsLinks(t *testing.T) {
	c, home := fsHome(t)
	outside := t.TempDir()
	os.WriteFile(filepath.Join(outside, "f.txt"), []byte("abc"), 0o644)
	os.Mkdir(filepath.Join(home, "real"), 0o755)
	os.WriteFile(filepath.Join(home, "real.txt"), []byte("x"), 0o644)
	symlink(t, outside, filepath.Join(home, "to-dir"))
	symlink(t, filepath.Join(outside, "f.txt"), filepath.Join(home, "to-file"))
	symlink(t, filepath.Join(outside, "gone"), filepath.Join(home, "dangling"))

	res := c.ok("fs.stat", proto.Message{"path": "to-dir"})
	if res["exists"] != true || res["dir"] != true || res["link"] != true || res.String("path") != filepath.Join(home, "to-dir") {
		t.Fatalf("link to a directory %v", res)
	}
	res = c.ok("fs.stat", proto.Message{"path": "to-file", "sha256": true})
	sum := sha256.Sum256([]byte("abc"))
	if res["exists"] != true || res["dir"] != false || res["link"] != true || res.Int("size") != 3 || res.String("sha256") != hex.EncodeToString(sum[:]) {
		t.Fatalf("link to a file %v", res)
	}
	res = c.ok("fs.stat", proto.Message{"path": "dangling"})
	if res["exists"] != false || res["link"] != true {
		t.Fatalf("link to nothing %v", res)
	}
	for _, name := range []string{"real", "real.txt", "missing", "to-dir/f.txt"} {
		if res := c.ok("fs.stat", proto.Message{"path": name}); res.Has("link") {
			t.Fatalf("%s: %v", name, res)
		}
	}
}

func TestFsListMarksLinksAndDoesNotEnterThem(t *testing.T) {
	c, home := fsHome(t)
	outside := t.TempDir()
	os.WriteFile(filepath.Join(outside, "secret.txt"), []byte("s"), 0o644)
	os.MkdirAll(filepath.Join(home, "t", "sub"), 0o755)
	os.WriteFile(filepath.Join(home, "t", "a.txt"), []byte("a"), 0o644)
	symlink(t, outside, filepath.Join(home, "t", "sub", "out"))
	symlink(t, filepath.Join(outside, "secret.txt"), filepath.Join(home, "t", "note"))

	res := c.ok("fs.list", proto.Message{"path": "t", "recursive": true, "sha256": true})
	em := entryMap(res)
	if len(em) != 4 {
		t.Fatalf("entries %v", em)
	}
	for _, name := range []string{"sub/out", "note"} {
		e := em[name]
		if e == nil || e["link"] != true || e["dir"] != false {
			t.Fatalf("%s: %v", name, e)
		}
		if _, has := e["sha256"]; has {
			t.Fatalf("%s has a digest: %v", name, e)
		}
	}
	for _, name := range []string{"sub", "a.txt"} {
		if _, has := em[name]["link"]; has {
			t.Fatalf("%s: %v", name, em[name])
		}
	}

	res = c.call("fs.list", proto.Message{"path": "t/sub/out", "recursive": true})
	want := fmt.Sprintf("'%s' is a link and fs.list does not follow links; list the folder it leads to", filepath.Join(home, "t", "sub", "out"))
	if res["ok"] != false || res.String("error") != want {
		t.Fatalf("listing a link %v", res)
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

func TestFsListOmitsDigestOfUnreadableFile(t *testing.T) {
	c, home := fsHome(t)
	os.Mkdir(filepath.Join(home, "t"), 0o755)
	os.WriteFile(filepath.Join(home, "t", "open.txt"), []byte("aa"), 0o644)
	closed := filepath.Join(home, "t", "closed.txt")
	os.WriteFile(closed, []byte("bbb"), 0o000)
	if f, err := os.Open(closed); err == nil {
		f.Close()
		t.Skip("a file with mode 000 is readable here")
	}

	em := entryMap(c.ok("fs.list", proto.Message{"path": "t", "sha256": true}))
	if len(em) != 2 {
		t.Fatalf("entries %v", em)
	}
	sum := sha256.Sum256([]byte("aa"))
	if em["open.txt"]["sha256"] != hex.EncodeToString(sum[:]) {
		t.Fatalf("readable file %v", em["open.txt"])
	}
	if _, has := em["closed.txt"]["sha256"]; has || int(em["closed.txt"]["size"].(float64)) != 3 {
		t.Fatalf("unreadable file %v", em["closed.txt"])
	}

	res := c.call("fs.stat", proto.Message{"path": "t/closed.txt", "sha256": true})
	if res["ok"] != false || !strings.Contains(res.String("error"), "cannot hash") {
		t.Fatalf("stat of the unreadable file %v", res)
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

func utf16le(s string) []byte {
	units := utf16.Encode([]rune(s))
	b := make([]byte, 0, 2*len(units))
	for _, u := range units {
		b = append(b, byte(u), byte(u>>8))
	}
	return b
}

func TestFsTailUTF16(t *testing.T) {
	c, home := fsHome(t)
	bom := []byte{0xFF, 0xFE}
	write := func(name string, content []byte) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(home, name), append(append([]byte{}, bom...), content...), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	var sb strings.Builder
	for i := 1; i <= 5; i++ {
		fmt.Fprintf(&sb, "로그 줄 %d\r\n", i)
	}
	write("ps.log", utf16le(sb.String()))
	res := c.ok("fs.tail", proto.Message{"path": "ps.log", "lines": 2})
	if got := decode(t, res); !bytes.Equal(got, utf16le("로그 줄 4\r\n로그 줄 5\r\n")) {
		t.Fatalf("tail of two lines: % x", got)
	}
	if res.String("encoding") != "utf-16le" || res.Int("size") != 2+2*len(utf16.Encode([]rune(sb.String()))) {
		t.Fatalf("encoding %q, size %d", res.String("encoding"), res.Int("size"))
	}
	res = c.ok("fs.tail", proto.Message{"path": "ps.log", "lines": 100})
	if got := decode(t, res); !bytes.Equal(got, utf16le(sb.String())) {
		t.Fatalf("tail of the whole file: % x", got)
	}

	write("units.log", utf16le("a\nĊ਀\nlast"))
	res = c.ok("fs.tail", proto.Message{"path": "units.log", "lines": 2})
	if got := decode(t, res); !bytes.Equal(got, utf16le("Ċ਀\nlast")) {
		t.Fatalf("line feed bytes inside other code units split a line: % x", got)
	}

	write("long.log", utf16le(strings.Repeat("ab\n", 60000)))
	res = c.ok("fs.tail", proto.Message{"path": "long.log", "lines": 1000000})
	got := decode(t, res)
	if len(got) > 262144 || len(got)%6 != 0 || !bytes.HasPrefix(got, utf16le("ab\n")) || res.String("encoding") != "utf-16le" {
		t.Fatalf("window tail: %d bytes starting % x", len(got), got[:8])
	}

	write("odd.log", append(utf16le(strings.Repeat("ab\n", 60000)), 'x'))
	res = c.ok("fs.tail", proto.Message{"path": "odd.log", "lines": 1000000})
	got = decode(t, res)
	if len(got) > 262144 || len(got)%6 != 1 || !bytes.HasPrefix(got, utf16le("ab\n")) {
		t.Fatalf("window tail of a file with an odd size: %d bytes starting % x", len(got), got[:8])
	}

	write("bom-only.log", nil)
	res = c.ok("fs.tail", proto.Message{"path": "bom-only.log"})
	if got := decode(t, res); len(got) != 0 || res.String("encoding") != "utf-16le" {
		t.Fatalf("tail of a file holding only the byte order mark: % x, encoding %q", got, res.String("encoding"))
	}
}

func TestFsReadAndTailReportUTF16Only(t *testing.T) {
	c, home := fsHome(t)
	os.WriteFile(filepath.Join(home, "wide.txt"), append([]byte{0xFF, 0xFE}, utf16le("한글 text")...), 0o644)
	os.WriteFile(filepath.Join(home, "plain.txt"), []byte("한글 text\n"), 0o644)
	os.WriteFile(filepath.Join(home, "empty.txt"), nil, 0o644)

	res := c.ok("fs.read", proto.Message{"path": "wide.txt", "offset": 2, "length": 4})
	if got := decode(t, res); !bytes.Equal(got, utf16le("한글")) || res.String("encoding") != "utf-16le" {
		t.Fatalf("read inside a UTF-16 file: % x, encoding %q", got, res.String("encoding"))
	}
	res = c.ok("fs.read", proto.Message{"path": "wide.txt"})
	if got := decode(t, res); !bytes.HasPrefix(got, []byte{0xFF, 0xFE}) || res.String("encoding") != "utf-16le" {
		t.Fatalf("read from the start of a UTF-16 file: % x, encoding %q", got, res.String("encoding"))
	}
	for _, name := range []string{"plain.txt", "empty.txt"} {
		for _, op := range []string{"fs.read", "fs.tail"} {
			if res := c.ok(op, proto.Message{"path": name}); res.Has("encoding") {
				t.Fatalf("%s of %s reports encoding %q", op, name, res.String("encoding"))
			}
		}
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

func TestFsDeleteRefusesHomeRootAndAncestors(t *testing.T) {
	c, home := fsHome(t)
	os.MkdirAll(filepath.Join(home, "keep", "sub"), 0o755)
	os.WriteFile(filepath.Join(home, "keep", "f"), []byte("x"), 0o644)

	targets := []string{"~", ".", home, filepath.Dir(home)}
	if runtime.GOOS != "windows" {
		targets = append(targets, "/")
	}
	for _, p := range targets {
		for _, recursive := range []bool{true, false} {
			res := c.call("fs.delete", proto.Message{"path": p, "recursive": recursive})
			want := "it is the home directory or contains it; delete its contents instead, or use exec.run if this is intended"
			if res["ok"] != false || !strings.Contains(res.String("error"), "refusing to delete '") || !strings.HasSuffix(res.String("error"), want) {
				t.Fatalf("%q recursive=%v: %v", p, recursive, res)
			}
		}
	}
	if _, err := os.Stat(filepath.Join(home, "keep", "f")); err != nil {
		t.Fatalf("home content deleted: %v", err)
	}

	res := c.ok("fs.delete", proto.Message{"path": "keep", "recursive": true})
	if res["deleted"] != true {
		t.Fatalf("subdirectory %v", res)
	}
	if _, err := os.Stat(home); err != nil {
		t.Fatalf("home gone: %v", err)
	}
}

func TestFsDeleteRefusesTheHomeDirectoryUnderAnotherSpellingOfItsName(t *testing.T) {
	base := t.TempDir()
	home := filepath.Join(base, "home")
	if err := os.MkdirAll(filepath.Join(home, "keep"), 0o755); err != nil {
		t.Fatal(err)
	}
	alias := filepath.Join(base, "HOME")
	if a, err := os.Stat(alias); err != nil || !sameAs(a, home) {
		t.Skip("this file system tells names apart by case")
	}
	c, _ := newRPCClient(t, Options{HomeDir: home})
	parentAlias := filepath.Join(filepath.Dir(base), strings.ToUpper(filepath.Base(base)))
	want := "it is the home directory or contains it; delete its contents instead, or use exec.run if this is intended"
	for _, tc := range []struct {
		path      string
		recursive bool
	}{{alias, true}, {alias, false}, {parentAlias, false}} {
		res := c.call("fs.delete", proto.Message{"path": tc.path, "recursive": tc.recursive})
		if res["ok"] != false || res.String("error") != "refusing to delete '"+tc.path+"': "+want {
			t.Fatalf("%q recursive=%v: %v", tc.path, tc.recursive, res)
		}
	}
	if _, err := os.Stat(filepath.Join(home, "keep")); err != nil {
		t.Fatalf("home content deleted: %v", err)
	}
}

func TestFsDeleteRefusesAFolderWhoseIdentityCannotBeRead(t *testing.T) {
	c, home := fsHome(t)
	for _, name := range []string{"unreadable", "other", "file"} {
		if name == "file" {
			if err := os.WriteFile(filepath.Join(home, name), []byte("x"), 0o644); err != nil {
				t.Fatal(err)
			}
			continue
		}
		if err := os.Mkdir(filepath.Join(home, name), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	read := readFileID
	var failing string
	readFileID = func(path string, follow bool) (fileID, error) {
		if path == failing {
			return fileID{}, errors.New("sharing violation")
		}
		return read(path, follow)
	}
	t.Cleanup(func() { readFileID = read })

	failing = filepath.Join(home, "unreadable")
	res := c.call("fs.delete", proto.Message{"path": "unreadable", "recursive": true})
	want := "refusing to delete '" + failing + "': its identity could not be read (sharing violation), so it cannot be told apart from the home directory; delete its contents instead, or use exec.run if this is intended"
	if res["ok"] != false || res.String("error") != want {
		t.Fatalf("unreadable folder: %v", res)
	}

	failing = filepath.Clean(home)
	other := filepath.Join(home, "other")
	res = c.call("fs.delete", proto.Message{"path": "other", "recursive": true})
	want = "refusing to delete '" + other + "': the identity of " + failing + " could not be read (sharing violation), so it cannot be told apart from that folder; delete its contents instead, or use exec.run if this is intended"
	if res["ok"] != false || res.String("error") != want {
		t.Fatalf("unreadable home: %v", res)
	}

	failing = filepath.Join(home, "file")
	if res := c.ok("fs.delete", proto.Message{"path": "file"}); res["deleted"] != true {
		t.Fatalf("file: %v", res)
	}
	failing = ""
	if res := c.ok("fs.delete", proto.Message{"path": "unreadable"}); res["deleted"] != true {
		t.Fatalf("readable folder: %v", res)
	}
}

// sameAs reports whether fi is the file or folder at path.
func sameAs(fi os.FileInfo, path string) bool {
	other, err := os.Stat(path)
	return err == nil && os.SameFile(fi, other)
}

func TestIsFileSystemRoot(t *testing.T) {
	cases := []struct {
		path, volume string
		sep          byte
		want         bool
	}{
		{"/", "", '/', true},
		{"/usr", "", '/', false},
		{`C:\`, "C:", '\\', true},
		{`C:\Users`, "C:", '\\', false},
		{`D:\`, "D:", '\\', true},
		{`\\host\share\`, `\\host\share`, '\\', true},
		{`\\host\share\dir`, `\\host\share`, '\\', false},
		{`C:`, "C:", '\\', false},
	}
	for _, tc := range cases {
		if got := isFileSystemRoot(tc.path, tc.volume, tc.sep); got != tc.want {
			t.Errorf("isFileSystemRoot(%q, %q, %q) = %v, want %v", tc.path, tc.volume, tc.sep, got, tc.want)
		}
	}
}

func TestPathContains(t *testing.T) {
	cases := []struct {
		dir, target string
		sep         byte
		fold        bool
		want        bool
	}{
		{"/a", "/a", '/', false, true},
		{"/a", "/a/b/c", '/', false, true},
		{"/a/b", "/a", '/', false, false},
		{"/ab", "/a/b", '/', false, false},
		{"/A", "/a/b", '/', false, false},
		{`C:\Users`, `c:\users\me`, '\\', true, true},
		{`C:\`, `C:\Users\me`, '\\', true, true},
		{`D:\`, `C:\Users\me`, '\\', true, false},
	}
	for _, tc := range cases {
		if got := pathContains(tc.dir, tc.target, tc.sep, tc.fold); got != tc.want {
			t.Errorf("pathContains(%q, %q) = %v, want %v", tc.dir, tc.target, got, tc.want)
		}
	}
}
