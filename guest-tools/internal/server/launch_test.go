package server

import (
	"errors"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

// windowsUI answers win.list with what list returns for the n-th call.
type windowsUI struct {
	mu    sync.Mutex
	calls int
	list  func(n int) ([]any, error)
}

func (u *windowsUI) Call(op string, _ map[string]any, _ time.Duration) (map[string]any, error) {
	if op != "win.list" {
		return map[string]any{}, nil
	}
	u.mu.Lock()
	n := u.calls
	u.calls++
	u.mu.Unlock()
	windows, err := u.list(n)
	if err != nil {
		return nil, err
	}
	return map[string]any{"windows": windows}, nil
}

func (u *windowsUI) listed() int {
	u.mu.Lock()
	defer u.mu.Unlock()
	return u.calls
}

func window(id, title string, pid int) map[string]any {
	return sized(id, title, pid, 400, 300)
}

func sized(id, title string, pid, w, h int) map[string]any {
	return map[string]any{"id": id, "title": title, "pid": float64(pid), "class": "Fixture", "process": "fixture.exe",
		"w": float64(w), "h": float64(h)}
}

func TestLaunchStartsProcessAndReportsExit(t *testing.T) {
	c, _ := newRPCClient(t, Options{})
	res := c.ok("app.launch", proto.Message{"path": "sh", "args": []string{"-c", "exit 3"}, "wait_window_ms": 0})
	pid := res.Int("pid")
	if pid <= 0 || res.Has("window") {
		t.Fatalf("res %v", res)
	}
	ev := c.event("process.exited")
	if ev.Int("pid") != pid || ev.Int("code") != 3 || filepath.Base(ev.String("path")) != "sh" || !filepath.IsAbs(ev.String("path")) {
		t.Fatalf("event %v", ev)
	}
}

func TestLaunchGated(t *testing.T) {
	_, r, w, _ := startServerS(t, Options{Clipboard: &fakeClipboard{}, HomeDir: t.TempDir()})
	expect(t, r, "hello")
	w.Send(proto.Message{"t": "req", "id": 1, "op": "app.launch", "path": "sh"})
	res := expect(t, r, "res")
	if res["ok"] != false || res.String("error") != "exec disabled; start alcove-agent with --allow-exec" {
		t.Fatalf("res %v", res)
	}
}

func TestLaunchMissingPath(t *testing.T) {
	c, _ := newRPCClient(t, Options{})
	missing := filepath.Join(t.TempDir(), "no-such-program")
	res := c.call("app.launch", proto.Message{"path": missing, "wait_window_ms": 0})
	if res["ok"] != false || !strings.Contains(res.String("error"), "cannot start '"+missing+"'") || !strings.Contains(res.String("error"), "fs.stat") {
		t.Fatalf("res %v", res)
	}
	res = c.call("app.launch", proto.Message{})
	if res["ok"] != false || !strings.HasPrefix(res.String("error"), "missing path") {
		t.Fatalf("res %v", res)
	}
	res = c.call("app.launch", proto.Message{"path": "sh", "wait_window_ms": -1})
	if res["ok"] != false || res.String("error") != "wait_window_ms must be 0 or more" {
		t.Fatalf("res %v", res)
	}
}

func TestLaunchRunsInTheProgramDirectoryWithArgsAndEnv(t *testing.T) {
	home := t.TempDir()
	c, _ := newRPCClient(t, Options{HomeDir: home})
	out := filepath.Join(home, "out.txt")
	script := `printf '%s|%s|%s' "$PWD" "$1" "$ALCOVE_LAUNCH_TEST" > "$0"`
	c.ok("app.launch", proto.Message{"path": "/bin/sh", "args": []string{"-c", script, out, "두 번째"},
		"env": map[string]any{"ALCOVE_LAUNCH_TEST": "set"}, "wait_window_ms": 0})
	c.event("process.exited")
	got := c.ok("fs.read", proto.Message{"path": out})
	if text := string(decode(t, got)); text != "/bin|두 번째|set" {
		t.Fatalf("the program saw %q", text)
	}
	c.events = nil
	c.ok("app.launch", proto.Message{"path": "/bin/sh", "args": []string{"-c", script, out, "x"}, "cwd": "~", "wait_window_ms": 0})
	c.event("process.exited")
	got = c.ok("fs.read", proto.Message{"path": out})
	if text := string(decode(t, got)); !strings.HasSuffix(strings.SplitN(text, "|", 2)[0], filepath.Base(home)) {
		t.Fatalf("with cwd ~ the program saw %q", text)
	}
}

func TestLaunchReturnsTheWindowOpenedAfterTheLaunch(t *testing.T) {
	old := window("0x10", "Program Manager", 4)
	ui := &windowsUI{list: func(n int) ([]any, error) {
		if n < 3 {
			return []any{old}, nil
		}
		return []any{window("0x30", "", 77), window("0x20", "Fixture", 77), old}, nil
	}}
	c, _ := newRPCClient(t, Options{UI: ui})
	res := c.ok("app.launch", proto.Message{"path": "sh", "args": []string{"-c", "exit 0"}})
	w, _ := res["window"].(map[string]any)
	if w["id"] != "0x20" || w["title"] != "Fixture" {
		t.Fatalf("res %v", res)
	}
}

func TestLaunchChoosesAmongWindowsThatOpenOnePollApart(t *testing.T) {
	old := window("0x10", "Program Manager", 4)
	prompt := sized("0x20", "Restore pages", 77, 380, 160)
	ui := &windowsUI{list: func(n int) ([]any, error) {
		switch {
		case n < 2:
			return []any{old}, nil
		case n == 2:
			return []any{prompt, old}, nil
		}
		return []any{prompt, sized("0x21", "Page", 77, 1000, 700), old}, nil
	}}
	c, _ := newRPCClient(t, Options{UI: ui})
	res := c.ok("app.launch", proto.Message{"path": "sh", "args": []string{"-c", "exit 0"}})
	if w, _ := res["window"].(map[string]any); w["id"] != "0x21" {
		t.Fatalf("res %v", res)
	}
}

func TestLaunchWithoutANewWindowAnswersAfterTheWait(t *testing.T) {
	ui := &windowsUI{list: func(int) ([]any, error) { return []any{window("0x10", "Program Manager", 4)}, nil }}
	c, _ := newRPCClient(t, Options{UI: ui})
	start := time.Now()
	res := c.ok("app.launch", proto.Message{"path": "sh", "args": []string{"-c", "exit 0"}, "wait_window_ms": 400})
	if res.Int("pid") <= 0 || res.Has("window") {
		t.Fatalf("res %v", res)
	}
	if took := time.Since(start); took < 400*time.Millisecond || took > 5*time.Second {
		t.Fatalf("answered after %v", took)
	}
	if ui.listed() < 3 {
		t.Fatalf("win.list was called %d times", ui.listed())
	}
}

func TestLaunchDoesNotStartWhenTheWindowsCannotBeListed(t *testing.T) {
	ui := &windowsUI{list: func(int) ([]any, error) { return nil, errors.New("the UI helper is busy with 'ui.tree'; retry") }}
	home := t.TempDir()
	c, _ := newRPCClient(t, Options{UI: ui, HomeDir: home})
	marker := filepath.Join(home, "started")
	res := c.call("app.launch", proto.Message{"path": "sh", "args": []string{"-c", "touch " + marker}})
	want := "'sh' was not started because the windows could not be listed: the UI helper is busy with 'ui.tree'; retry"
	if res["ok"] != false || res.String("error") != want {
		t.Fatalf("res %v", res)
	}
	time.Sleep(200 * time.Millisecond)
	if c.ok("fs.stat", proto.Message{"path": marker})["exists"] != false {
		t.Fatal("the program ran")
	}
}

func TestLaunchWithWaitZeroDoesNotListWindows(t *testing.T) {
	ui := &windowsUI{list: func(int) ([]any, error) { return nil, errors.New("not expected") }}
	c, _ := newRPCClient(t, Options{UI: ui})
	c.ok("app.launch", proto.Message{"path": "sh", "args": []string{"-c", "exit 0"}, "wait_window_ms": 0})
	if ui.listed() != 0 {
		t.Fatalf("win.list was called %d times", ui.listed())
	}
}

func TestPickLaunchWindow(t *testing.T) {
	before := map[string]bool{"0x10": true}
	tree := map[int]bool{50: true, 51: true}
	old := window("0x10", "Old", 50)
	untitled := window("0x11", "", 50)
	foreign := window("0x12", "Other app", 90)
	child := window("0x13", "Child window", 51)
	own := window("0x14", "Own window", 50)

	cases := []struct {
		name    string
		windows []map[string]any
		foreign bool
		want    string
	}{
		{"a window listed before the launch is not chosen", []map[string]any{old}, true, ""},
		{"a window without a title is not chosen", []map[string]any{untitled, old}, true, ""},
		{"a window of a descendant is chosen", []map[string]any{old, child}, false, "0x13"},
		{"a window of the tree wins over an earlier window of another process", []map[string]any{foreign, own}, true, "0x14"},
		{"of two windows of the tree with the same size the first listed is chosen", []map[string]any{child, own}, false, "0x13"},
		{"of two windows of the tree the larger is chosen", []map[string]any{sized("0x20", "Prompt", 50, 300, 120), sized("0x21", "Main", 51, 900, 600)}, false, "0x21"},
		{"of two windows of other processes the larger is chosen", []map[string]any{sized("0x22", "Restore pages", 90, 380, 160), sized("0x23", "Page", 91, 1000, 700), sized("0x24", "Tip", 92, 200, 40)}, true, "0x23"},
		{"a small window of the tree wins over a large window of another process", []map[string]any{sized("0x25", "Other", 90, 1200, 700), sized("0x26", "Own", 50, 200, 100)}, true, "0x26"},
		{"a window of another process is not chosen while foreign is unset", []map[string]any{foreign}, false, ""},
		{"a window of another process is chosen when foreign is set", []map[string]any{old, foreign}, true, "0x12"},
	}
	for _, c := range cases {
		got := ""
		if w := pickLaunchWindow(c.windows, before, tree, c.foreign); w != nil {
			got = windowID(w)
		}
		if got != c.want {
			t.Errorf("%s: chose %q, expected %q", c.name, got, c.want)
		}
	}
}

func TestGrowTreeAddsDescendants(t *testing.T) {
	tree := map[int]bool{10: true}
	growTree(tree, map[int]int{11: 10, 12: 11, 13: 12, 20: 1, 21: 20})
	for _, pid := range []int{10, 11, 12, 13} {
		if !tree[pid] {
			t.Errorf("pid %d is missing", pid)
		}
	}
	if tree[20] || tree[21] {
		t.Errorf("tree %v", tree)
	}
	growTree(tree, map[int]int{14: 13})
	if !tree[14] {
		t.Error("a child of a process that left the list is missing")
	}
}

func TestSettleFrameWindowWaitsForTheAppProcess(t *testing.T) {
	host := map[string]any{"id": "0x50", "title": "Calculator", "pid": float64(8), "class": "ApplicationFrameWindow", "process": "ApplicationFrameHost.exe"}
	app := map[string]any{"id": "0x50", "title": "Calculator", "pid": float64(9), "class": "ApplicationFrameWindow", "process": "CalculatorApp.exe"}
	ui := &windowsUI{list: func(n int) ([]any, error) {
		if n < 2 {
			return []any{host}, nil
		}
		return []any{app}, nil
	}}
	s := New(Options{Clipboard: &fakeClipboard{}, HomeDir: t.TempDir(), UI: ui})
	got := s.settleFrameWindow(host, time.Now().Add(10*time.Second))
	if got["process"] != "CalculatorApp.exe" {
		t.Fatalf("window %v", got)
	}
	plain := window("0x60", "Fixture", 3)
	before := ui.listed()
	if got := s.settleFrameWindow(plain, time.Now().Add(10*time.Second)); got["id"] != "0x60" || ui.listed() != before {
		t.Fatalf("window %v after %d more listings", got, ui.listed()-before)
	}
}
