//go:build !windows

package server

import (
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

const koreanTail = `yes 한 | head -c 300000; printf ab`

func checkKoreanTail(t *testing.T, label, out string) {
	t.Helper()
	if len(out) > 200000 || len(out) < 199990 || strings.ContainsRune(out, utf8.RuneError) || !strings.HasSuffix(out, "한\nab") {
		t.Fatalf("%s: %d bytes, replacement character %v, tail %q", label, len(out), strings.ContainsRune(out, utf8.RuneError), out[max(0, len(out)-8):])
	}
}

func TestExecRunTruncatedStreamStartsOnACharacter(t *testing.T) {
	c, _ := newRPCClient(t, Options{})
	res := c.ok("exec.run", proto.Message{"cmd": koreanTail, "shell": "sh"})
	if res["truncated"] != true {
		t.Fatalf("res not truncated: %v", res["truncated"])
	}
	checkKoreanTail(t, "exec.run stdout", res.String("stdout"))
}

func TestV1ExecTruncatedStreamStartsOnACharacter(t *testing.T) {
	r, w, c := startServer(t, Options{Clipboard: &fakeClipboard{}, HomeDir: t.TempDir(), AllowExec: true})
	c.SetDeadline(time.Now().Add(20 * time.Second))
	expect(t, r, "hello")
	w.Send(proto.Message{"t": "exec", "cmd": koreanTail})
	checkKoreanTail(t, "exec.result out", expect(t, r, "exec.result").String("out"))
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
