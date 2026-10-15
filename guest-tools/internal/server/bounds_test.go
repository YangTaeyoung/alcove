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
	if got := cutChars("a\xff\xfeb\x80c", 3); got != "a\uFFFDb…" {
		t.Fatalf("invalid bytes: %q", got)
	}
	if got := cutChars("a\xffb", 5); got != "a\uFFFDb" {
		t.Fatalf("short text with an invalid byte: %q", got)
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

func TestStreamText(t *testing.T) {
	if got := streamText([]byte("\x9c\n가"), true); got != "\n가" {
		t.Fatalf("cut stream starts inside a character: %q", got)
	}
	if got := streamText([]byte("\x9c\n"), false); got != "�\n" {
		t.Fatalf("uncut stream: %q", got)
	}
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
