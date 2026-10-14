package server

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

const (
	defaultLaunchWaitMs = 15000
	maxLaunchWaitMs     = 300000
	launchListTimeout   = 20 * time.Second
	// maxClaims bounds the window ids app.launch remembers as taken.
	maxClaims = 1024
)

var (
	launchPoll = 150 * time.Millisecond
	// launchForeignGrace is how long a running launched process keeps the
	// window choice to its own process tree.
	launchForeignGrace = 2 * time.Second
	// launchFrameSettle is how long app.launch waits for a packaged app's
	// frame window to report the app's process.
	launchFrameSettle = 3 * time.Second
	// startProgram starts the program of an app.launch.
	startProgram = func(c *exec.Cmd) error { return c.Start() }
)

// claimSet holds the ids of the windows launches have taken, in the order
// they were taken, at most maxClaims of them, and which of them belong to a
// launch that has not answered yet.
type claimSet struct {
	ids   map[string]bool
	order []string
	held  map[string]bool
}

// add records id; when that makes more than maxClaims ids, the oldest other
// ids that are not held leave, and the oldest held ones when every other id
// is held.
func (c *claimSet) add(id string) {
	if c.ids[id] {
		return
	}
	if c.ids == nil {
		c.ids = map[string]bool{}
	}
	c.ids[id] = true
	c.order = append(c.order, id)
	for len(c.order) > maxClaims {
		victim := 0
		for i, other := range c.order[:len(c.order)-1] {
			if !c.held[other] {
				victim = i
				break
			}
		}
		gone := c.order[victim]
		delete(c.ids, gone)
		delete(c.held, gone)
		c.order = append(c.order[:victim], c.order[victim+1:]...)
	}
}

// hold marks a claimed id as belonging to a launch that has not answered yet.
func (c *claimSet) hold(id string) {
	if !c.ids[id] {
		return
	}
	if c.held == nil {
		c.held = map[string]bool{}
	}
	c.held[id] = true
}

// release ends the hold on id; the id stays claimed.
func (c *claimSet) release(id string) {
	delete(c.held, id)
}

func (c *claimSet) remove(id string) {
	if !c.ids[id] {
		return
	}
	delete(c.ids, id)
	delete(c.held, id)
	for i, other := range c.order {
		if other == id {
			c.order = append(c.order[:i], c.order[i+1:]...)
			break
		}
	}
}

// clearReleased forgets every id that is not held.
func (c *claimSet) clearReleased() {
	var order []string
	for _, id := range c.order {
		if c.held[id] {
			order = append(order, id)
		} else {
			delete(c.ids, id)
		}
	}
	c.order = order
}

func (s *Server) registerLaunch() {
	s.register("app.launch", true, s.appLaunch)
}

// appLaunch starts a program with a normal window, reports its exit as a
// process.exited event and, unless wait_window_ms is 0 or the agent has no UI
// helper, waits for the window the launch opened.
func (s *Server) appLaunch(ctx context.Context, req proto.Message) (proto.Message, error) {
	path := req.String("path")
	if path == "" {
		return nil, errors.New("missing path; pass the program to start")
	}
	waitMs := defaultLaunchWaitMs
	if req.Has("wait_window_ms") {
		waitMs = req.Int("wait_window_ms")
	}
	if waitMs < 0 {
		return nil, errors.New("pass wait_window_ms of 0 or more")
	}
	if waitMs > maxLaunchWaitMs {
		waitMs = maxLaunchWaitMs
	}

	c := exec.Command(resolveProgram(path), req.Strings("args")...)
	if cwd := req.String("cwd"); cwd != "" {
		c.Dir = resolveHomePath(s.opt.HomeDir, cwd)
	} else if filepath.IsAbs(c.Path) {
		c.Dir = filepath.Dir(c.Path)
	}
	if env := req.StringMap("env"); len(env) > 0 {
		keys := make([]string, 0, len(env))
		for k := range env {
			if k == "" || strings.Contains(k, "=") {
				return nil, errors.New("env names cannot be empty or contain '='")
			}
			keys = append(keys, k)
		}
		sort.Strings(keys)
		c.Env = os.Environ()
		for _, k := range keys {
			c.Env = append(c.Env, k+"="+env[k])
		}
	}

	watch := waitMs > 0 && s.opt.UI != nil
	before := map[string]bool{}
	if watch {
		windows, err := s.listWindows(ctx)
		if err != nil {
			return nil, fmt.Errorf("'%s' was not started because the windows could not be listed: %v", path, err)
		}
		for _, w := range windows {
			before[windowID(w)] = true
		}
	}

	if err := startProgram(c); err != nil {
		return nil, fmt.Errorf("cannot start '%s': %v; check the path with fs.stat", path, err)
	}
	pid, started := c.Process.Pid, c.Path
	exited := make(chan struct{})
	go func() {
		_ = c.Wait()
		code := -1
		if c.ProcessState != nil {
			code = c.ProcessState.ExitCode()
		}
		close(exited)
		s.emit("process.exited", proto.Message{"pid": pid, "code": code, "path": started})
	}()

	res := proto.Message{"pid": pid}
	if watch {
		if w := s.waitLaunchWindow(ctx, pid, before, exited, time.Duration(waitMs)*time.Millisecond); w != nil {
			res["window"] = w
		}
	}
	return res, nil
}

// claimWindow picks a window not listed before the launch and not already
// claimed by another launch, claims it and holds the claim for the launch
// until releaseClaim. The launch's own current claim, named by own, stays
// eligible in a later listing.
func (s *Server) claimWindow(windows []map[string]any, before map[string]bool, tree map[int]bool, foreign bool, own string) map[string]any {
	s.launchMu.Lock()
	defer s.launchMu.Unlock()
	w := pickLaunchWindow(windows, before, tree, foreign, s.claimed.ids, own)
	if w != nil {
		s.claimed.add(windowID(w))
		s.claimed.hold(windowID(w))
	}
	return w
}

// releaseClaim records that the launch holding the claim on id has answered.
func (s *Server) releaseClaim(id string) {
	if id == "" {
		return
	}
	s.launchMu.Lock()
	s.claimed.release(id)
	s.launchMu.Unlock()
}

func (s *Server) unclaimWindow(id string) {
	if id == "" {
		return
	}
	s.launchMu.Lock()
	s.claimed.remove(id)
	s.launchMu.Unlock()
}

func (s *Server) listWindows(ctx context.Context) ([]map[string]any, error) {
	out, err := s.opt.UI.CallContext(ctx, "win.list", nil, launchListTimeout)
	if err != nil {
		return nil, err
	}
	list, _ := out["windows"].([]any)
	windows := make([]map[string]any, 0, len(list))
	for _, v := range list {
		if w, ok := v.(map[string]any); ok {
			windows = append(windows, w)
		}
	}
	return windows, nil
}

func windowID(w map[string]any) string {
	id, _ := w["id"].(string)
	return id
}

func windowPID(w map[string]any) int {
	switch v := w["pid"].(type) {
	case float64:
		return int(v)
	case int:
		return v
	}
	return 0
}

// waitLaunchWindow polls win.list until claimWindow names a window or the wait
// is over; it returns nil when no window was found. After the first choice it
// lists the windows once more, one poll later, and returns the choice among the
// windows of that listing when there is one. When the first choice is gone from
// the second listing and nothing else is a candidate, it keeps polling instead
// of returning the window that has already closed.
func (s *Server) waitLaunchWindow(ctx context.Context, pid int, before map[string]bool, exited <-chan struct{}, wait time.Duration) map[string]any {
	start := time.Now()
	deadline := start.Add(wait)
	tree := map[int]bool{pid: true}
	held := ""
	defer func() { s.releaseClaim(held) }()
	for {
		if ctx.Err() != nil {
			return nil
		}
		growTree(tree, processParents())
		done := false
		select {
		case <-exited:
			done = true
		default:
		}
		windows, err := s.listWindows(ctx)
		if err == nil {
			foreign := done || time.Since(start) >= launchForeignGrace
			if w := s.claimWindow(windows, before, tree, foreign, ""); w != nil {
				held = windowID(w)
				time.Sleep(launchPoll)
				growTree(tree, processParents())
				again, againErr := s.listWindows(ctx)
				if againErr == nil {
					if later := s.claimWindow(again, before, tree, foreign, windowID(w)); later != nil {
						if windowID(later) != windowID(w) {
							s.unclaimWindow(windowID(w))
							w = later
							held = windowID(w)
						}
					} else if !listedWindow(again, windowID(w)) {
						// The chosen window is gone and nothing replaced it: keep looking.
						s.unclaimWindow(windowID(w))
						held = ""
						if !time.Now().Before(deadline) {
							return nil
						}
						continue
					}
				}
				return s.settleFrameWindow(ctx, w, deadline)
			}
		}
		if !time.Now().Before(deadline) {
			return nil
		}
		time.Sleep(launchPoll)
	}
}

// listedWindow reports whether a window with the id is in the listing.
func listedWindow(windows []map[string]any, id string) bool {
	for _, w := range windows {
		if windowID(w) == id {
			return true
		}
	}
	return false
}

// growTree adds to tree every process whose parent is in it.
func growTree(tree map[int]bool, parents map[int]int) {
	for changed := true; changed; {
		changed = false
		for pid, ppid := range parents {
			if !tree[pid] && tree[ppid] {
				tree[pid] = true
				changed = true
			}
		}
	}
}

// pickLaunchWindow chooses among the titled windows that were not listed
// before the launch, are not already claimed by another launch and have a
// rectangle that is not empty or are minimized: the largest one that belongs
// to a process of tree; without such a window and with foreign set, the
// largest one of any process. Of windows of the same size the one listed
// first is chosen.
func pickLaunchWindow(windows []map[string]any, before map[string]bool, tree map[int]bool, foreign bool, claimed map[string]bool, own string) map[string]any {
	var ownWin, other map[string]any
	for _, w := range windows {
		id := windowID(w)
		title, _ := w["title"].(string)
		if title == "" || before[id] || (claimed[id] && id != own) {
			continue
		}
		if state, _ := w["state"].(string); windowArea(w) <= 0 && state != "minimized" {
			continue
		}
		if tree[windowPID(w)] {
			if ownWin == nil || windowArea(w) > windowArea(ownWin) {
				ownWin = w
			}
		} else if other == nil || windowArea(w) > windowArea(other) {
			other = w
		}
	}
	if ownWin != nil || !foreign {
		return ownWin
	}
	return other
}

func windowArea(w map[string]any) float64 {
	width, _ := w["w"].(float64)
	height, _ := w["h"].(float64)
	return width * height
}

// settleFrameWindow re-reads the frame window of a packaged app until it
// reports the app's process instead of the frame host, the settle time has
// passed or the deadline is reached, and returns the newest reading.
func (s *Server) settleFrameWindow(ctx context.Context, w map[string]any, deadline time.Time) map[string]any {
	end := time.Now().Add(launchFrameSettle)
	if deadline.Before(end) {
		end = deadline
	}
	for isFrameHostWindow(w) && time.Now().Before(end) {
		if ctx.Err() != nil {
			return w
		}
		time.Sleep(launchPoll)
		windows, err := s.listWindows(ctx)
		if err != nil {
			continue
		}
		found := false
		for _, other := range windows {
			if windowID(other) == windowID(w) {
				w, found = other, true
				break
			}
		}
		if !found {
			break
		}
	}
	return w
}

func isFrameHostWindow(w map[string]any) bool {
	class, _ := w["class"].(string)
	process, _ := w["process"].(string)
	return class == "ApplicationFrameWindow" && strings.EqualFold(process, "ApplicationFrameHost.exe")
}
