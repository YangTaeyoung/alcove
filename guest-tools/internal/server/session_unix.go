//go:build !windows

package server

import (
	"os/exec"
	"sync"
	"syscall"
	"time"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/clipboard"
	"github.com/YangTaeyoung/alcove/guest-tools/internal/session"
)

// sessionCacheTime is how long a session lookup is reused.
const sessionCacheTime = 5 * time.Second

// sessionCache runs lookup at most once per sessionCacheTime.
type sessionCache struct {
	mu     sync.Mutex
	lookup func() (session.Session, error)
	at     time.Time
	s      session.Session
	ok     bool
}

func (c *sessionCache) get() (session.Session, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.at.IsZero() && time.Since(c.at) < sessionCacheTime {
		return c.s, c.ok
	}
	s, err := c.lookup()
	c.at, c.s, c.ok = time.Now(), s, err == nil
	return c.s, c.ok
}

// defaultSessionSource returns the desktop session that loginctl reports.
func defaultSessionSource() func() (session.Session, bool) {
	c := &sessionCache{lookup: session.Lookup}
	return c.get
}

// newClipboard returns the clipboard of the session source names, or of the
// agent's own environment while there is none.
func newClipboard(source func() (session.Session, bool)) clipboard.Clipboard {
	return clipboard.NewSession(func() (clipboard.Target, bool) {
		sess, ok := source()
		if !ok {
			return clipboard.Target{}, false
		}
		return clipboard.Target{Env: sess.Env, Credential: sess.Credential(), Scope: sess.ScopePrefix()}, true
	})
}

// runInSession gives c the environment env and a session of its own, runs
// it as cred's user when cred is not nil, and starts it through scope (the
// command line of systemd-run before the program) when scope is not empty
// and the program is an executable file, so that it runs in the user's
// service manager rather than in the agent's service. The process keeps its
// process id through systemd-run.
func runInSession(c *exec.Cmd, env []string, cred *syscall.Credential, scope []string) {
	c.Env = env
	if c.SysProcAttr == nil {
		c.SysProcAttr = &syscall.SysProcAttr{}
	}
	c.SysProcAttr.Setsid = true
	c.SysProcAttr.Credential = cred
	if _, err := exec.LookPath(c.Path); len(scope) > 0 && c.Err == nil && err == nil {
		c.Args = append(append(append([]string{}, scope...), c.Path), c.Args[1:]...)
		c.Path = scope[0]
	}
}
