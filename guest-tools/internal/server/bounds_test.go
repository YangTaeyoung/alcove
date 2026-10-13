package server

import (
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

func TestCutChars(t *testing.T) {
	if got := cutChars("abc", 3); got != "abc" {
		t.Fatalf("short text changed: %q", got)
	}
	if got := cutChars("가나다라", 2); got != "가나…" {
		t.Fatalf("cut at a rune boundary: %q", got)
	}
}

func TestCutUTF8Bytes(t *testing.T) {
	if got := cutUTF8Bytes("abc", 3); got != "abc" {
		t.Fatalf("short text changed: %q", got)
	}
	got := cutUTF8Bytes("가나다", 7)
	if got != "가나" || !utf8.ValidString(got) {
		t.Fatalf("cut inside a rune: %q", got)
	}
}

func TestTailUTF8(t *testing.T) {
	got := tailUTF8([]byte("가나다"), 7)
	if got != "나다" {
		t.Fatalf("tail starts inside a rune: %q", got)
	}
}

func TestExecListCutsLongCommands(t *testing.T) {
	c, _ := newRPCClient(t, Options{})
	long := "echo done #" + strings.Repeat("가", 10000)
	job := c.ok("exec.start", proto.Message{"cmd": long}).String("job")
	out, _, _ := waitJobExited(t, c, job)
	if out != "done\n" {
		t.Fatalf("exec.read output %q", out)
	}
	jobs, _ := c.ok("exec.list", nil)["jobs"].([]any)
	for _, j := range jobs {
		m, _ := j.(map[string]any)
		if m["job"] != job {
			continue
		}
		cmd, _ := m["cmd"].(string)
		want := string([]rune(long)[:4096]) + "…"
		if cmd != want {
			t.Fatalf("listed cmd has %d runes, want %d", utf8.RuneCountInString(cmd), utf8.RuneCountInString(want))
		}
		return
	}
	t.Fatalf("job %s missing from exec.list", job)
}

func TestProcListEntriesCutCommands(t *testing.T) {
	procs := []procInfo{
		{PID: 1, Name: "a", Cmd: strings.Repeat("x", 9000)},
		{PID: 2, Name: "b", Cmd: "short"},
	}
	out := procListEntries(procs, "")
	if len(out) != 2 {
		t.Fatalf("entries %v", out)
	}
	if got := out[0].(map[string]any)["cmd"].(string); got != strings.Repeat("x", 8192)+"…" {
		t.Fatalf("long cmd has %d runes", utf8.RuneCountInString(got))
	}
	if got := out[1].(map[string]any)["cmd"].(string); got != "short" {
		t.Fatalf("short cmd %q", got)
	}
	if only := procListEntries(procs, "B"); len(only) != 1 {
		t.Fatalf("filtered entries %v", only)
	}
}

func TestV1ExecKeepsLastBytes(t *testing.T) {
	r, w, c := startServer(t, Options{Clipboard: &fakeClipboard{}, HomeDir: t.TempDir(), AllowExec: true})
	c.SetDeadline(time.Now().Add(20 * time.Second))
	expect(t, r, "hello")
	w.Send(proto.Message{"t": "exec", "cmd": `head -c 300000 /dev/zero | tr '\0' 'a'; echo END`})
	res := expect(t, r, "exec.result")
	out := res.String("out")
	if len(out) != 200000 || !strings.HasSuffix(out, "END\n") || res.Int("code") != 0 {
		t.Fatalf("exec.result code %d, %d bytes, tail %q", res.Int("code"), len(out), out[max(0, len(out)-8):])
	}
}

func TestClipboardRepliesCutLongText(t *testing.T) {
	cb := &fakeClipboard{}
	r, w, c := startServer(t, Options{Clipboard: cb, HomeDir: t.TempDir()})
	c.SetDeadline(time.Now().Add(10 * time.Second))
	expect(t, r, "hello")
	big := strings.Repeat("가", 300000)
	cb.external(big)
	changed := expect(t, r, "clipboard.changed").String("text")
	w.Send(proto.Message{"t": "clipboard.get"})
	got := expect(t, r, "clipboard.text").String("text")
	for name, text := range map[string]string{"clipboard.changed": changed, "clipboard.text": got} {
		if len(text) > 700000 || len(text) < 700000-3 || !utf8.ValidString(text) || !strings.HasPrefix(big, text) {
			t.Fatalf("%s carries %d bytes", name, len(text))
		}
	}
}
