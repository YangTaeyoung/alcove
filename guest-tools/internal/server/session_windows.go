//go:build windows

package server

import (
	"io/fs"
	"os/exec"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/clipboard"
	"github.com/YangTaeyoung/alcove/guest-tools/internal/session"
)

// defaultSessionSource reports no session: the agent runs in the session of
// the signed-in user.
func defaultSessionSource() func() (session.Session, bool) { return nil }

// newClipboard returns the clipboard of the agent's session.
func newClipboard(func() (session.Session, bool)) clipboard.Clipboard { return clipboard.New() }

// runInSession gives c the environment env.
func runInSession(c *exec.Cmd, env []string, _ any, _ []string) { c.Env = env }

// linkedElsewhere reports false: Windows agents have no session home.
func linkedElsewhere(fs.FileInfo, uint32) bool { return false }
