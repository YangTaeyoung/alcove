//go:build !windows

package clipboard

import (
	"bytes"
	"errors"
	"hash/fnv"
	"os"
	"os/exec"
)

// commandClipboard uses wl-copy/wl-paste (Wayland) or xclip (X11) when present.
type commandClipboard struct {
	read, write []string
}

// New picks an available clipboard tool; Available() is false without a session.
func New() Clipboard {
	if os.Getenv("WAYLAND_DISPLAY") != "" {
		if _, err := exec.LookPath("wl-paste"); err == nil {
			return commandClipboard{read: []string{"wl-paste", "--no-newline", "--type", "text"}, write: []string{"wl-copy"}}
		}
	}
	if os.Getenv("DISPLAY") != "" {
		if _, err := exec.LookPath("xclip"); err == nil {
			return commandClipboard{read: []string{"xclip", "-selection", "clipboard", "-o"}, write: []string{"xclip", "-selection", "clipboard", "-i"}}
		}
	}
	return commandClipboard{}
}

func (c commandClipboard) Available() bool { return len(c.read) > 0 }

func (c commandClipboard) Text() (string, error) {
	if !c.Available() {
		return "", errors.New("no clipboard in this session")
	}
	out, err := exec.Command(c.read[0], c.read[1:]...).Output()
	if err != nil {
		return "", nil // empty clipboard makes the tools exit non-zero
	}
	return string(out), nil
}

func (c commandClipboard) SetText(s string) error {
	if !c.Available() {
		return errors.New("no clipboard in this session")
	}
	cmd := exec.Command(c.write[0], c.write[1:]...)
	cmd.Stdin = bytes.NewBufferString(s)
	return cmd.Run()
}

func (c commandClipboard) Sequence() uint64 {
	t, _ := c.Text()
	h := fnv.New64a()
	h.Write([]byte(t))
	return h.Sum64()
}
