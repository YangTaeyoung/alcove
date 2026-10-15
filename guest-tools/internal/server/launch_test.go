package server

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
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

func (u *windowsUI) CallContext(_ context.Context, op string, _ map[string]any, _ time.Duration) (map[string]any, error) {
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

func minimized(id, title string, pid int) map[string]any {
	w := sized(id, title, pid, 0, 0)
	w["state"] = "minimized"
	return w
}

// launchExit returns fields with the path and args of exitProgram(code).
func launchExit(code int, fields proto.Message) proto.Message {
	path, args := exitProgram(code)
	m := proto.Message{"path": path, "args": args}
	for k, v := range fields {
		m[k] = v
	}
	return m
}

func TestLaunchStartsProcessAndReportsExit(t *testing.T) {
	c, _ := newRPCClient(t, Options{})
	res := c.ok("app.launch", launchExit(3, proto.Message{"wait_window_ms": 0}))
	pid := res.Int("pid")
	if pid <= 0 || res.Has("window") {
		t.Fatalf("res %v", res)
	}
	ev := c.event("process.exited")
	program, _ := exitProgram(3)
	if ev.Int("pid") != pid || ev.Int("code") != 3 || !strings.EqualFold(filepath.Base(ev.String("path")), program) || !filepath.IsAbs(ev.String("path")) {
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
	if res["ok"] != false || res.String("error") != "pass wait_window_ms of 0 or more" {
		t.Fatalf("res %v", res)
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
	res := c.ok("app.launch", launchExit(0, nil))
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
	res := c.ok("app.launch", launchExit(0, nil))
	if w, _ := res["window"].(map[string]any); w["id"] != "0x21" {
		t.Fatalf("res %v", res)
	}
}

func TestLaunchWithoutANewWindowAnswersAfterTheWait(t *testing.T) {
	ui := &windowsUI{list: func(int) ([]any, error) { return []any{window("0x10", "Program Manager", 4)}, nil }}
	c, _ := newRPCClient(t, Options{UI: ui})
	start := time.Now()
	res := c.ok("app.launch", launchExit(0, proto.Message{"wait_window_ms": 400}))
	if res.Int("pid") <= 0 || res.Has("window") {
		t.Fatalf("res %v", res)
	}
	if took := time.Since(start); took < 400*time.Millisecond {
		t.Fatalf("answered after %v", took)
	}
	if ui.listed() < 2 {
		t.Fatalf("win.list was called %d times", ui.listed())
	}
}

func TestLaunchDoesNotStartWhenTheWindowsCannotBeListed(t *testing.T) {
	ui := &windowsUI{list: func(int) ([]any, error) { return nil, errors.New("the UI helper is busy with 'ui.tree'; retry") }}
	var starts atomic.Int32
	start := startProgram
	startProgram = func(c *exec.Cmd) error {
		starts.Add(1)
		return start(c)
	}
	t.Cleanup(func() { startProgram = start })
	c, _ := newRPCClient(t, Options{UI: ui})
	res := c.call("app.launch", launchExit(0, nil))
	program, _ := exitProgram(0)
	want := "'" + program + "' was not started because the windows could not be listed: the UI helper is busy with 'ui.tree'; retry"
	if res["ok"] != false || res.String("error") != want {
		t.Fatalf("res %v", res)
	}
	if n := starts.Load(); n != 0 {
		t.Fatalf("%d programs were started", n)
	}
	c.ok("app.launch", launchExit(0, proto.Message{"wait_window_ms": 0}))
	if n := starts.Load(); n != 1 {
		t.Fatalf("a launch that does not list windows started %d programs", n)
	}
}

func TestLaunchWithWaitZeroDoesNotListWindows(t *testing.T) {
	ui := &windowsUI{list: func(int) ([]any, error) { return nil, errors.New("not expected") }}
	c, _ := newRPCClient(t, Options{UI: ui})
	c.ok("app.launch", launchExit(0, proto.Message{"wait_window_ms": 0}))
	if ui.listed() != 0 {
		t.Fatalf("win.list was called %d times", ui.listed())
	}
}

func TestLaunchRefusesABadEnvName(t *testing.T) {
	c, _ := newRPCClient(t, Options{})
	for _, bad := range []map[string]any{{"": "v"}, {"A=B": "v"}} {
		res := c.call("app.launch", launchExit(0, proto.Message{"wait_window_ms": 0, "env": bad}))
		if res["ok"] != false || res.String("error") != "env names cannot be empty or contain '='" {
			t.Fatalf("env %v answered %v", bad, res)
		}
	}
}

type launchKey struct{}

// twoLaunchUI lists only an old window until the launches numbered 0 and 1
// have both listed the windows once, and two new windows of different sizes
// from then on. The number of a launch is the launchKey value of its context.
type twoLaunchUI struct {
	mu     sync.Mutex
	listed map[int]bool
	opened bool
}

func (u *twoLaunchUI) CallContext(ctx context.Context, op string, _ map[string]any, _ time.Duration) (map[string]any, error) {
	if op != "win.list" {
		return map[string]any{}, nil
	}
	u.mu.Lock()
	defer u.mu.Unlock()
	old := window("0x10", "Program Manager", 4)
	if !u.opened {
		if u.listed == nil {
			u.listed = map[int]bool{}
		}
		n, _ := ctx.Value(launchKey{}).(int)
		u.listed[n] = true
		u.opened = u.listed[0] && u.listed[1]
		return map[string]any{"windows": []any{old}}, nil
	}
	return map[string]any{"windows": []any{sized("0xa", "App A", 77, 900, 700), sized("0xb", "App B", 88, 400, 300), old}}, nil
}

func TestTwoConcurrentLaunchesTakeDifferentWindows(t *testing.T) {
	ui := &twoLaunchUI{}
	s := New(Options{Clipboard: &fakeClipboard{}, HomeDir: t.TempDir(), UI: ui, AllowExec: true})
	ids := make(chan string, 2)
	errs := make(chan error, 2)
	for i := 0; i < 2; i++ {
		ctx := context.WithValue(context.Background(), launchKey{}, i)
		go func() {
			res, err := s.appLaunch(ctx, launchExit(0, proto.Message{"wait_window_ms": 60000}))
			if err != nil {
				errs <- err
				return
			}
			w, _ := res["window"].(map[string]any)
			if w == nil {
				errs <- errors.New("no window")
				return
			}
			ids <- windowID(w)
		}()
	}
	got := map[string]bool{}
	for i := 0; i < 2; i++ {
		select {
		case err := <-errs:
			t.Fatal(err)
		case id := <-ids:
			if got[id] {
				t.Fatalf("both launches took window %s", id)
			}
			got[id] = true
		}
	}
	if !got["0xa"] || !got["0xb"] {
		t.Fatalf("the launches took %v, expected 0xa and 0xb", got)
	}
}

// pollingUI lists only an old window, so a launch keeps polling, and counts
// the win.list calls.
type pollingUI struct {
	mu    sync.Mutex
	calls int
}

func (u *pollingUI) CallContext(_ context.Context, op string, _ map[string]any, _ time.Duration) (map[string]any, error) {
	if op != "win.list" {
		return map[string]any{}, nil
	}
	u.mu.Lock()
	u.calls++
	u.mu.Unlock()
	return map[string]any{"windows": []any{window("0x10", "Program Manager", 4)}}, nil
}

func (u *pollingUI) listed() int {
	u.mu.Lock()
	defer u.mu.Unlock()
	return u.calls
}

func TestLaunchStopsPollingWhenTheConnectionCloses(t *testing.T) {
	ui := &pollingUI{}
	s, r, w, c := startServerS(t, Options{Clipboard: &fakeClipboard{}, HomeDir: t.TempDir(), UI: ui, AllowExec: true})
	returned := make(chan struct{})
	s.register("t.launch", true, func(ctx context.Context, req proto.Message) (proto.Message, error) {
		defer close(returned)
		return s.appLaunch(ctx, req)
	})
	expect(t, r, "hello")
	w.Send(launchExit(0, proto.Message{"t": "req", "id": 1, "op": "t.launch", "wait_window_ms": maxLaunchWaitMs}))
	for ui.listed() < 2 {
		time.Sleep(5 * time.Millisecond)
	}
	c.Close()
	select {
	case <-returned:
	case <-time.After(60 * time.Second):
		t.Fatalf("the launch still waits for a window after the connection closed; win.list was called %d times", ui.listed())
	}
}

func TestClaimSetForgetsTheOldestIdsBeyondItsLimit(t *testing.T) {
	var c claimSet
	for i := 0; i < maxClaims+3; i++ {
		c.add(fmt.Sprintf("0x%x", i))
	}
	if len(c.ids) != maxClaims || len(c.order) != maxClaims {
		t.Fatalf("the set holds %d ids in an order of %d", len(c.ids), len(c.order))
	}
	for i := 0; i < 3; i++ {
		if c.ids[fmt.Sprintf("0x%x", i)] {
			t.Fatalf("the id claimed as number %d is still held", i)
		}
	}
	if !c.ids["0x3"] || !c.ids[fmt.Sprintf("0x%x", maxClaims+2)] {
		t.Fatal("an id within the limit is missing")
	}
	c.add("0x3")
	c.add("0xfffff")
	if c.ids["0x3"] || !c.ids["0x4"] || !c.ids["0xfffff"] {
		t.Fatalf("a second claim of 0x3 changed its place in the order")
	}
	c.remove("0x4")
	c.remove("0x4")
	c.remove("0xnone")
	if c.ids["0x4"] || len(c.ids) != maxClaims-1 || len(c.order) != maxClaims-1 {
		t.Fatalf("after removing 0x4 the set holds %d ids in an order of %d", len(c.ids), len(c.order))
	}
	c.clearReleased()
	if len(c.ids) != 0 || len(c.order) != 0 {
		t.Fatalf("after clearReleased the set holds %d ids", len(c.ids))
	}
	c.add("0x1")
	if !c.ids["0x1"] || len(c.order) != 1 {
		t.Fatal("an id claimed after clearReleased is missing")
	}
}

func TestClaimSetKeepsHeldIdsWhenItForgetsTheReleasedOnes(t *testing.T) {
	var c claimSet
	for _, id := range []string{"0x1", "0x2", "0x3", "0x4"} {
		c.add(id)
	}
	c.hold("0x2")
	c.hold("0x4")
	c.hold("0xnone")
	if c.ids["0xnone"] || c.held["0xnone"] {
		t.Fatal("holding an id that is not claimed claimed it")
	}
	c.clearReleased()
	if len(c.ids) != 2 || !c.ids["0x2"] || !c.ids["0x4"] || fmt.Sprint(c.order) != "[0x2 0x4]" {
		t.Fatalf("after clearReleased the set holds %v in the order %v", c.ids, c.order)
	}
	c.release("0x2")
	if !c.ids["0x2"] {
		t.Fatal("a released id is no longer claimed")
	}
	c.remove("0x4")
	if c.held["0x4"] {
		t.Fatal("a removed id is still held")
	}
	c.clearReleased()
	if len(c.ids) != 0 || len(c.order) != 0 {
		t.Fatalf("after the second clearReleased the set holds %v", c.ids)
	}
	for i := 0; i < maxClaims+1; i++ {
		id := fmt.Sprintf("0x%x", 100+i)
		c.add(id)
		c.hold(id)
	}
	if c.ids["0x64"] || c.held["0x64"] || len(c.held) != maxClaims {
		t.Fatalf("the oldest held id stayed beyond the limit; %d ids are held", len(c.held))
	}
}

func TestClaimSetForgetsTheOldestReleasedIdBeforeAHeldOne(t *testing.T) {
	var c claimSet
	for i := 0; i < maxClaims; i++ {
		c.add(fmt.Sprintf("0x%x", i))
	}
	c.hold("0x0")
	c.add("0xfffff")
	if !c.ids["0x0"] || !c.held["0x0"] || c.ids["0x1"] || !c.ids["0xfffff"] || len(c.ids) != maxClaims || len(c.order) != maxClaims {
		t.Fatalf("0x0 kept %v, 0x1 kept %v, %d ids in an order of %d", c.ids["0x0"], c.ids["0x1"], len(c.ids), len(c.order))
	}
	if c.order[0] != "0x0" || c.order[1] != "0x2" || c.order[len(c.order)-1] != "0xfffff" {
		t.Fatalf("order begins %v and ends %v", c.order[:2], c.order[len(c.order)-1])
	}
}

func TestAHelperStartReleasesTheClaimsOfLaunchesThatAnswered(t *testing.T) {
	s := New(Options{Clipboard: &fakeClipboard{}, HomeDir: t.TempDir(), UI: &fakeUI{}})
	before := map[string]bool{}
	tree := map[int]bool{77: true}
	windows := []map[string]any{window("0x20", "Fixture", 77)}
	if w := s.claimWindow(windows, before, tree, false, ""); w == nil || windowID(w) != "0x20" {
		t.Fatalf("first claim: %v", w)
	}
	if w := s.claimWindow(windows, before, tree, false, ""); w != nil {
		t.Fatalf("a claimed window was claimed again: %v", w)
	}
	s.HandleUIStart()
	if w := s.claimWindow(windows, before, tree, false, ""); w != nil {
		t.Fatalf("a helper start released the claim of a launch that has not answered: %v", w)
	}
	s.releaseClaim("0x20")
	if w := s.claimWindow(windows, before, tree, false, ""); w != nil {
		t.Fatalf("the claim of a launch that answered was released without a helper start: %v", w)
	}
	s.HandleUIStart()
	if w := s.claimWindow(windows, before, tree, false, ""); w == nil || windowID(w) != "0x20" {
		t.Fatalf("claim after a helper start: %v", w)
	}
	s.HandleUIEvent("window.closed", map[string]any{"window": map[string]any{"id": "0x20"}})
	if w := s.claimWindow(windows, before, tree, false, ""); w == nil || windowID(w) != "0x20" {
		t.Fatalf("claim after window.closed: %v", w)
	}
}

func TestAHelperStartDuringALaunchKeepsItsClaimAndTheAnswerReleasesTheHold(t *testing.T) {
	old := window("0x10", "Program Manager", 4)
	var s *Server
	var heldAtStart, claimedAfterStart bool
	ui := &windowsUI{list: func(n int) ([]any, error) {
		if n == 0 {
			return []any{old}, nil
		}
		if n == 2 {
			// The listing after the first choice: a helper starts while the launch runs.
			s.launchMu.Lock()
			heldAtStart = s.claimed.held["0x20"]
			s.launchMu.Unlock()
			s.HandleUIStart()
			s.launchMu.Lock()
			claimedAfterStart = s.claimed.ids["0x20"]
			s.launchMu.Unlock()
		}
		return []any{window("0x20", "Fixture", 77), old}, nil
	}}
	var c *rpcClient
	c, s = newRPCClient(t, Options{UI: ui})
	res := c.ok("app.launch", launchExit(0, nil))
	if w, _ := res["window"].(map[string]any); w["id"] != "0x20" {
		t.Fatalf("res %v", res)
	}
	if !heldAtStart || !claimedAfterStart {
		t.Fatalf("held before the helper start: %v, claimed after it: %v", heldAtStart, claimedAfterStart)
	}
	s.launchMu.Lock()
	held, claimed := len(s.claimed.held), s.claimed.ids["0x20"]
	s.launchMu.Unlock()
	if held != 0 || !claimed {
		t.Fatalf("after the answer %d claims are held and 0x20 claimed is %v", held, claimed)
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
		{"a window of the tree with an empty rectangle is not chosen", []map[string]any{sized("0x27", "OLEChannelWnd", 50, 0, 0)}, true, ""},
		{"a window of another process with an empty rectangle is not chosen", []map[string]any{sized("0x28", "Hidden", 90, 0, 40)}, true, ""},
		{"a window with a rectangle is chosen beside one with an empty rectangle", []map[string]any{sized("0x29", "OLEChannelWnd", 50, 0, 0), sized("0x2a", "Services", 50, 806, 593)}, false, "0x2a"},
		{"a minimized window is chosen", []map[string]any{minimized("0x2b", "Tray app", 50)}, false, "0x2b"},
	}
	for _, c := range cases {
		got := ""
		if w := pickLaunchWindow(c.windows, before, tree, c.foreign, nil, ""); w != nil {
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
	got := s.settleFrameWindow(context.Background(), host, time.Now().Add(10*time.Second))
	if got["process"] != "CalculatorApp.exe" {
		t.Fatalf("window %v", got)
	}
	plain := window("0x60", "Fixture", 3)
	before := ui.listed()
	if got := s.settleFrameWindow(context.Background(), plain, time.Now().Add(10*time.Second)); got["id"] != "0x60" || ui.listed() != before {
		t.Fatalf("window %v after %d more listings", got, ui.listed()-before)
	}
}
