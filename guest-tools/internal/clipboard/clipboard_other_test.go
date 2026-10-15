//go:build !windows

package clipboard

import (
	"os/exec"
	"reflect"
	"testing"
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
	cmd := c.command([]string{"wl-paste", "--no-newline"}, target)
	if !reflect.DeepEqual(cmd.Env, target.Env) || cmd.SysProcAttr != nil {
		t.Fatalf("env %q, attr %+v", cmd.Env, cmd.SysProcAttr)
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
