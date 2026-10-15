//go:build !windows

package clipboard

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

func lookPathOf(found ...string) func(string) (string, error) {
	return func(name string) (string, error) {
		for _, f := range found {
			if f == name {
				return "/usr/bin/" + name, nil
			}
		}
		return "", exec.ErrNotFound
	}
}

func TestToolFollowsTheSessionDisplay(t *testing.T) {
	cases := []struct {
		env   []string
		found []string
		read  string
	}{
		{[]string{"WAYLAND_DISPLAY=wayland-0", "XDG_RUNTIME_DIR=/run/user/1000"}, []string{"wl-paste", "xclip"}, "wl-paste"},
		{[]string{"WAYLAND_DISPLAY=wayland-0", "DISPLAY=:0"}, []string{"xclip"}, "xclip"},
		{[]string{"DISPLAY=:1"}, []string{"wl-paste", "xclip"}, "xclip"},
		{[]string{"DISPLAY=:1"}, []string{"wl-paste"}, ""},
		{[]string{"HOME=/root"}, []string{"wl-paste", "xclip"}, ""},
	}
	for _, c := range cases {
		tl, ok := pickTool(c.env, lookPathOf(c.found...))
		got := ""
		if ok {
			got = tl.read[0]
		}
		if got != c.read {
			t.Errorf("env %q with %q: tool %q, want %q", c.env, c.found, got, c.read)
		}
	}
}

func TestToolReadsTheLastValueOfAName(t *testing.T) {
	if _, ok := pickTool([]string{"WAYLAND_DISPLAY=wayland-0", "WAYLAND_DISPLAY="}, lookPathOf("wl-paste")); ok {
		t.Fatal("a WAYLAND_DISPLAY emptied later in the environment still chose wl-paste")
	}
}

func TestCommandsRunWithTheSessionEnvironment(t *testing.T) {
	c := sessionClipboard{}
	target := Target{Env: []string{"WAYLAND_DISPLAY=wayland-0", "HOME=/home/alcove"}}
	cmd := c.command(context.Background(), []string{"wl-paste", "--no-newline"}, target)
	if !reflect.DeepEqual(cmd.Env, target.Env) || !cmd.SysProcAttr.Setsid || cmd.SysProcAttr.Credential != nil {
		t.Fatalf("env %q, attr %+v", cmd.Env, cmd.SysProcAttr)
	}
}

// fakeTools puts sh scripts named after the keys of scripts into a folder
// that becomes PATH, and returns that folder.
func fakeTools(t *testing.T, scripts map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for name, body := range scripts {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("#!/bin/sh\n"+body+"\n"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", dir+":/usr/bin:/bin")
	return dir
}

func waylandTarget(t *testing.T) Target {
	return Target{Env: []string{"WAYLAND_DISPLAY=wayland-0", "PATH=" + os.Getenv("PATH")}}
}

func shortToolTimeout(t *testing.T) {
	old := toolTimeout
	toolTimeout = 300 * time.Millisecond
	t.Cleanup(func() { toolTimeout = old })
}

func TestAHungClipboardToolTimesOut(t *testing.T) {
	shortToolTimeout(t)
	fakeTools(t, map[string]string{"wl-paste": "sleep 30", "wl-copy": "cat >/dev/null; sleep 30"})
	c := NewSession(func() (Target, bool) { return waylandTarget(t), true })
	start := time.Now()
	if _, err := c.Text(); err == nil {
		t.Fatal("Text of a hung wl-paste succeeded")
	}
	if err := c.SetText("x"); err == nil {
		t.Fatal("SetText of a hung wl-copy succeeded")
	}
	if d := time.Since(start); d > 10*time.Second {
		t.Fatalf("the calls took %v", d)
	}
}

func TestClipboardTextIsReadUpToTheLimit(t *testing.T) {
	fakeTools(t, map[string]string{"wl-paste": "head -c 3000000 /dev/zero | tr '\\000' a"})
	c := NewSession(func() (Target, bool) { return waylandTarget(t), true })
	text, err := c.Text()
	if err != nil || len(text) != ReadLimit {
		t.Fatalf("read %d bytes, %v", len(text), err)
	}
}

func TestSetTextRunsTheWriterThroughTheScope(t *testing.T) {
	dir := fakeTools(t, map[string]string{
		"wl-paste": "true",
		"wl-copy":  "cat > \"$CLIP_OUT\"",
		"runner":   "echo \"$@\" > \"$RUNNER_OUT\"; shift; exec \"$@\"",
	})
	clip, ran := filepath.Join(dir, "clip.txt"), filepath.Join(dir, "runner.txt")
	target := waylandTarget(t)
	target.Env = append(target.Env, "CLIP_OUT="+clip, "RUNNER_OUT="+ran)
	target.Scope = []string{filepath.Join(dir, "runner"), "--"}
	c := NewSession(func() (Target, bool) { return target, true })
	if err := c.SetText("한글 text"); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(clip); string(b) != "한글 text" {
		t.Fatalf("wl-copy got %q", b)
	}
	if b, _ := os.ReadFile(ran); !strings.HasPrefix(string(b), "-- ") || !strings.HasSuffix(strings.TrimSpace(string(b)), "wl-copy") {
		t.Fatalf("runner got %q", b)
	}
}

func TestClipboardWithoutASessionToolIsUnavailable(t *testing.T) {
	c := NewSession(func() (Target, bool) { return Target{Env: []string{"HOME=/home/alcove"}}, true })
	if c.Available() {
		t.Fatal("a session without a display has a clipboard")
	}
	if _, err := c.Text(); err == nil || err.Error() != "no clipboard in this session" {
		t.Fatalf("Text: %v", err)
	}
	if err := c.SetText("x"); err == nil {
		t.Fatal("SetText succeeded without a clipboard")
	}
}

func TestClipboardTextCutAtTheLimitEndsOnAWholeCharacter(t *testing.T) {
	fakeTools(t, map[string]string{"wl-paste": "yes 가 | tr -d '\\n' | head -c 900000"})
	c := NewSession(func() (Target, bool) { return waylandTarget(t), true })
	text, err := c.Text()
	if err != nil || !utf8.ValidString(text) || len(text) != ReadLimit-1 {
		t.Fatalf("read %d bytes, valid UTF-8 %v, %v", len(text), utf8.ValidString(text), err)
	}
}

func TestSequenceKeepsTheLastValueWhileTheReaderFails(t *testing.T) {
	shortToolTimeout(t)
	dir := fakeTools(t, map[string]string{"wl-paste": `if [ -e "$HANG" ]; then sleep 30; fi; printf 'guest text'`})
	hang := filepath.Join(dir, "hang")
	target := waylandTarget(t)
	target.Env = append(target.Env, "HANG="+hang)
	c := NewSession(func() (Target, bool) { return target, true })
	before := c.Sequence()
	if err := os.WriteFile(hang, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if got := c.Sequence(); got != before {
		t.Fatalf("a timed-out read changed the sequence from %x to %x", before, got)
	}
	if err := os.Remove(hang); err != nil {
		t.Fatal(err)
	}
	if got := c.Sequence(); got != before {
		t.Fatalf("the same text after a timed-out read changed the sequence from %x to %x", before, got)
	}
}

func TestSequenceKeepsTheLastValueWhileTheReaderExitsNonZero(t *testing.T) {
	dir := fakeTools(t, map[string]string{"wl-paste": `if [ -e "$FAIL" ]; then echo 'Nothing is copied' >&2; exit 1; fi; printf 'guest text'`})
	fail := filepath.Join(dir, "fail")
	target := waylandTarget(t)
	target.Env = append(target.Env, "FAIL="+fail)
	c := NewSession(func() (Target, bool) { return target, true })
	before := c.Sequence()
	if err := os.WriteFile(fail, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if text, err := c.Text(); text != "" || err != nil {
		t.Fatalf("Text of a reader that exits 1 gave %q, %v", text, err)
	}
	if got := c.Sequence(); got != before {
		t.Fatalf("a reader that exits 1 changed the sequence from %x to %x", before, got)
	}
	if err := os.Remove(fail); err != nil {
		t.Fatal(err)
	}
	if got := c.Sequence(); got != before {
		t.Fatalf("the same text after a reader that exited 1 changed the sequence from %x to %x", before, got)
	}
}

func TestSequenceFollowsATextLongerThanTheReadLimit(t *testing.T) {
	dir := fakeTools(t, map[string]string{"wl-paste": `head -c 3000000 /dev/zero | tr '\000' "$(cat "$LETTER")"`})
	letter := filepath.Join(dir, "letter")
	target := waylandTarget(t)
	target.Env = append(target.Env, "LETTER="+letter)
	c := NewSession(func() (Target, bool) { return target, true })
	if err := os.WriteFile(letter, []byte("a"), 0o644); err != nil {
		t.Fatal(err)
	}
	first := c.Sequence()
	if err := os.WriteFile(letter, []byte("b"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := c.Sequence(); got == first {
		t.Fatalf("a text longer than %d bytes that changed kept the sequence %x", ReadLimit, got)
	}
}
