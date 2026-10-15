//go:build !windows

package clipboard

import (
	"bytes"
	"errors"
	"hash/fnv"
	"os"
	"os/exec"
	"strings"
	"syscall"
)

// Target is the session the clipboard tools run in: their environment and,
// when not nil, the user they run as.
type Target struct {
	Env        []string
	Credential *syscall.Credential
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
// or in the agent's own environment when target finds none.
type sessionClipboard struct {
	target func() (Target, bool)
}

// New uses the clipboard of the agent's own environment.
func New() Clipboard { return NewSession(nil) }

// NewSession uses the clipboard of the session target returns at each call;
// without one, or with a nil target, that of the agent's own environment.
func NewSession(target func() (Target, bool)) Clipboard { return sessionClipboard{target: target} }

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

func (c sessionClipboard) command(args []string, t Target) *exec.Cmd {
	cmd := exec.Command(args[0], args[1:]...)
	cmd.Env = t.Env
	if t.Credential != nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{Credential: t.Credential}
	}
	return cmd
}

func (c sessionClipboard) Available() bool {
	_, _, ok := c.current()
	return ok
}

func (c sessionClipboard) Text() (string, error) {
	tl, t, ok := c.current()
	if !ok {
		return "", errors.New("no clipboard in this session")
	}
	out, err := c.command(tl.read, t).Output()
	if err != nil {
		return "", nil // empty clipboard makes the tools exit non-zero
	}
	return string(out), nil
}

func (c sessionClipboard) SetText(s string) error {
	tl, t, ok := c.current()
	if !ok {
		return errors.New("no clipboard in this session")
	}
	cmd := c.command(tl.write, t)
	cmd.Stdin = bytes.NewBufferString(s)
	return cmd.Run()
}

func (c sessionClipboard) Sequence() uint64 {
	t, _ := c.Text()
	h := fnv.New64a()
	h.Write([]byte(t))
	return h.Sum64()
}
