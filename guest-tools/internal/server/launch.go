package server

import (
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
)

var (
	launchPoll = 150 * time.Millisecond
	// launchForeignGrace is how long a running launched process keeps the
	// window choice to its own process tree.
	launchForeignGrace = 2 * time.Second
	// launchFrameSettle is how long app.launch waits for a packaged app's
	// frame window to report the app's process.
	launchFrameSettle = 3 * time.Second
)

func (s *Server) registerLaunch() {
	s.register("app.launch", true, s.appLaunch)
}

// appLaunch starts a program with a normal window, reports its exit as a
// process.exited event and, unless wait_window_ms is 0 or the agent has no UI
// helper, waits for the window the launch opened.
func (s *Server) appLaunch(req proto.Message) (proto.Message, error) {
	path := req.String("path")
	if path == "" {
		return nil, errors.New("missing path; pass the program to start")
	}
	waitMs := defaultLaunchWaitMs
	if req.Has("wait_window_ms") {
		waitMs = req.Int("wait_window_ms")
	}
	if waitMs < 0 {
		return nil, errors.New("wait_window_ms must be 0 or more")
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
		windows, err := s.listWindows()
		if err != nil {
			return nil, fmt.Errorf("'%s' was not started because the windows could not be listed: %v", path, err)
		}
		for _, w := range windows {
			before[windowID(w)] = true
		}
	}

	if err := c.Start(); err != nil {
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
		if w := s.waitLaunchWindow(pid, before, exited, time.Duration(waitMs)*time.Millisecond); w != nil {
			res["window"] = w
		}
	}
	return res, nil
}

func (s *Server) listWindows() ([]map[string]any, error) {
	out, err := s.opt.UI.Call("win.list", nil, launchListTimeout)
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

// waitLaunchWindow polls win.list until pickLaunchWindow names a window or
// the wait is over; it returns nil when no window was found. After the first
// choice it lists the windows once more, one poll later, and returns the
// choice among the windows of that listing when there is one.
func (s *Server) waitLaunchWindow(pid int, before map[string]bool, exited <-chan struct{}, wait time.Duration) map[string]any {
	start := time.Now()
	deadline := start.Add(wait)
	tree := map[int]bool{pid: true}
	for {
		growTree(tree, processParents())
		done := false
		select {
		case <-exited:
			done = true
		default:
		}
		windows, err := s.listWindows()
		if err == nil {
			foreign := done || time.Since(start) >= launchForeignGrace
			if w := pickLaunchWindow(windows, before, tree, foreign); w != nil {
				time.Sleep(launchPoll)
				growTree(tree, processParents())
				if again, err := s.listWindows(); err == nil {
					if later := pickLaunchWindow(again, before, tree, foreign); later != nil {
						w = later
					}
				}
				return s.settleFrameWindow(w, deadline)
			}
		}
		if !time.Now().Before(deadline) {
			return nil
		}
		time.Sleep(launchPoll)
	}
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
// before the launch: the largest one that belongs to a process of tree;
// without such a window and with foreign set, the largest one of any process.
// Of windows of the same size the one listed first is chosen.
func pickLaunchWindow(windows []map[string]any, before map[string]bool, tree map[int]bool, foreign bool) map[string]any {
	var own, other map[string]any
	for _, w := range windows {
		title, _ := w["title"].(string)
		if title == "" || before[windowID(w)] {
			continue
		}
		if tree[windowPID(w)] {
			if own == nil || windowArea(w) > windowArea(own) {
				own = w
			}
		} else if other == nil || windowArea(w) > windowArea(other) {
			other = w
		}
	}
	if own != nil || !foreign {
		return own
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
func (s *Server) settleFrameWindow(w map[string]any, deadline time.Time) map[string]any {
	end := time.Now().Add(launchFrameSettle)
	if deadline.Before(end) {
		end = deadline
	}
	for isFrameHostWindow(w) && time.Now().Before(end) {
		time.Sleep(launchPoll)
		windows, err := s.listWindows()
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
