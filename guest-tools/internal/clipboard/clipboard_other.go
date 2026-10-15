//go:build !windows

package clipboard

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"hash/fnv"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"
)

// Target is the session the clipboard tools run in: their environment and,
// when not nil, the user they run as.
type Target struct {
	Env        []string
	Credential *syscall.Credential
	// Scope is the command line before the writer's, such as systemd-run
	// --user --scope … --, that starts it outside the agent's service.
	Scope []string
}

// tool is a clipboard tool pair: the commands that read and write the text.
type tool struct {
	read, write []string
}

// pickTool returns wl-paste/wl-copy when env names a Wayland display and
// lookPath finds wl-paste, else xclip when env names an X display and
// lookPath finds xclip.
func pickTool(env []string, lookPath func(string) (string, error)) (tool, bool) {
	if envValue(env, "WAYLAND_DISPLAY") != "" {
		if _, err := lookPath("wl-paste"); err == nil {
			return tool{read: []string{"wl-paste", "--no-newline", "--type", "text"}, write: []string{"wl-copy"}}, true
		}
	}
	if envValue(env, "DISPLAY") != "" {
		if _, err := lookPath("xclip"); err == nil {
			return tool{read: []string{"xclip", "-selection", "clipboard", "-o"}, write: []string{"xclip", "-selection", "clipboard", "-i"}}, true
		}
	}
	return tool{}, false
}

// envValue returns the last value of name in env.
func envValue(env []string, name string) string {
	v := ""
	for _, e := range env {
		if k, val, ok := strings.Cut(e, "="); ok && k == name {
			v = val
		}
	}
	return v
}

// sessionClipboard runs the clipboard tools in the session target returns,
// or in the agent's own environment when target finds none. last holds the
// sequence of the last text read.
type sessionClipboard struct {
	target func() (Target, bool)
	last   *lastSequence
}

// lastSequence is the sequence Sequence returned last.
type lastSequence struct {
	mu sync.Mutex
	v  uint64
}

// New uses the clipboard of the agent's own environment.
func New() Clipboard { return NewSession(nil) }

// NewSession uses the clipboard of the session target returns at each call;
// without one, or with a nil target, that of the agent's own environment.
func NewSession(target func() (Target, bool)) Clipboard {
	return sessionClipboard{target: target, last: &lastSequence{}}
}

func (c sessionClipboard) current() (tool, Target, bool) {
	t, ok := Target{}, false
	if c.target != nil {
		t, ok = c.target()
	}
	if !ok {
		t = Target{Env: os.Environ()}
	}
	tl, found := pickTool(t.Env, exec.LookPath)
	return tl, t, found
}

// ReadLimit is the most bytes of UTF-8 Text returns, the 700000 bytes the
// agent reports.
const ReadLimit = 700000

// toolTimeout bounds one run of a clipboard tool.
var toolTimeout = 5 * time.Second

// command returns the tool command args in t's environment, as t's user, in
// a session of its own, ended when ctx is done.
func (c sessionClipboard) command(ctx context.Context, args []string, t Target) *exec.Cmd {
	cmd := exec.CommandContext(ctx, args[0], args[1:]...)
	cmd.Env = t.Env
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true, Credential: t.Credential}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = time.Second
	return cmd
}

func (c sessionClipboard) Available() bool {
	_, _, ok := c.current()
	return ok
}

// Text runs the reader for at most toolTimeout and returns the longest
// prefix of what it prints that is at most ReadLimit bytes and ends on a
// character boundary; a reader that exits non-zero returns "" (the tools do
// for an empty clipboard). A reader that cannot start or does not finish in
// time is an error.
func (c sessionClipboard) Text() (string, error) {
	tl, t, ok := c.current()
	if !ok {
		return "", errors.New("no clipboard in this session")
	}
	ctx, cancel := context.WithTimeout(context.Background(), toolTimeout)
	defer cancel()
	cmd := c.command(ctx, tl.read, t)
	out, err := cmd.StdoutPipe()
	if err != nil {
		return "", err
	}
	if err := cmd.Start(); err != nil {
		return "", fmt.Errorf("%s did not start: %v", tl.read[0], err)
	}
	data, _ := io.ReadAll(io.LimitReader(out, ReadLimit+1))
	timedOut := ctx.Err() != nil
	cancel()
	_ = cmd.Wait()
	if timedOut {
		return "", fmt.Errorf("%s did not answer within %v", tl.read[0], toolTimeout)
	}
	return string(cutAtCharacter(data, ReadLimit)), nil
}

// cutAtCharacter returns the longest prefix of b that is at most max bytes
// and does not end inside a UTF-8 character.
func cutAtCharacter(b []byte, max int) []byte {
	if len(b) <= max {
		return b
	}
	for max > 0 && !utf8.RuneStart(b[max]) {
		max--
	}
	return b[:max]
}

// SetText runs the writer, through t.Scope when set, for at most
// toolTimeout.
func (c sessionClipboard) SetText(s string) error {
	tl, t, ok := c.current()
	if !ok {
		return errors.New("no clipboard in this session")
	}
	ctx, cancel := context.WithTimeout(context.Background(), toolTimeout)
	defer cancel()
	cmd := c.command(ctx, append(append([]string{}, t.Scope...), tl.write...), t)
	cmd.Stdin = bytes.NewBufferString(s)
	err := cmd.Run()
	if ctx.Err() != nil {
		return fmt.Errorf("%s did not finish within %v", tl.write[0], toolTimeout)
	}
	return err
}

// Sequence returns a hash of the text; while the reader fails it returns
// the value it returned last (0 before the first text).
func (c sessionClipboard) Sequence() uint64 {
	t, err := c.Text()
	c.last.mu.Lock()
	defer c.last.mu.Unlock()
	if err == nil {
		h := fnv.New64a()
		h.Write([]byte(t))
		c.last.v = h.Sum64()
	}
	return c.last.v
}
