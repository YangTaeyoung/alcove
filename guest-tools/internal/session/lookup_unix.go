//go:build !windows

package session

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"slices"
	"strconv"
	"syscall"
	"time"
)

// commandTimeout bounds one loginctl run.
const commandTimeout = 5 * time.Second

// ErrNone is the error of Lookup when no user session exists or the system
// has no loginctl.
var ErrNone = errors.New("no user session")

// Lookup finds the desktop session with loginctl and reads its user from the
// passwd and group files.
func Lookup() (Session, error) {
	if _, err := exec.LookPath("loginctl"); err != nil {
		return Session{}, ErrNone
	}
	list, err := run("loginctl", "list-sessions", "--no-legend", "--no-pager")
	if err != nil {
		return Session{}, err
	}
	ids := ParseList(list)
	if len(ids) == 0 {
		return Session{}, ErrNone
	}
	args := append([]string{"show-session", "--no-pager"}, ids...)
	for _, p := range ShowProperties {
		args = append(args, "-p", p)
	}
	// loginctl prints the sessions it found and fails for one that ended
	// after the listing; the printed sessions are used.
	show, showErr := run("loginctl", args...)
	info, ok := Pick(ParseShow(show))
	if !ok {
		if showErr != nil {
			return Session{}, showErr
		}
		return Session{}, ErrNone
	}
	a, err := account(info.UID)
	if err != nil {
		return Session{}, err
	}
	var entries []string
	if des, err := os.ReadDir("/run/user/" + strconv.FormatUint(uint64(a.UID), 10)); err == nil {
		entries = []string{}
		for _, d := range des {
			entries = append(entries, d.Name())
		}
	}
	sess := New(info, a, Environment(info, a, entries, os.Getenv("PATH"), systemLocale()))
	if slices.Contains(entries, "bus") {
		if runner, err := exec.LookPath("systemd-run"); err == nil {
			sess.ScopeRunner = runner
		}
	}
	return sess, nil
}

// systemLocale returns the locale variables of /etc/default/locale, else of
// /etc/locale.conf, else of the agent's environment.
func systemLocale() []string {
	for _, f := range []string{"/etc/default/locale", "/etc/locale.conf"} {
		if b, err := os.ReadFile(f); err == nil {
			if l := ParseLocale(string(b)); len(l) > 0 {
				return l
			}
		}
	}
	return LocaleFromEnv(os.Environ())
}

func run(name string, args ...string) (string, error) {
	c := exec.Command(name, args...)
	c.WaitDelay = time.Second
	timer := time.AfterFunc(commandTimeout, func() {
		if c.Process != nil {
			_ = c.Process.Kill()
		}
	})
	defer timer.Stop()
	out, err := c.Output()
	if err != nil {
		return string(out), fmt.Errorf("%s %s: %v", name, args[0], err)
	}
	return string(out), nil
}

// account reads the user of uid and its groups.
func account(uid uint32) (Account, error) {
	u, err := user.LookupId(strconv.FormatUint(uint64(uid), 10))
	if err != nil {
		return Account{}, err
	}
	gid, err := strconv.ParseUint(u.Gid, 10, 32)
	if err != nil {
		return Account{}, fmt.Errorf("user %s has the group id %q", u.Username, u.Gid)
	}
	a := Account{Name: u.Username, UID: uid, GID: uint32(gid), Home: u.HomeDir}
	if ids, err := u.GroupIds(); err == nil {
		for _, id := range ids {
			if g, err := strconv.ParseUint(id, 10, 32); err == nil {
				a.Groups = append(a.Groups, uint32(g))
			}
		}
	}
	return a, nil
}

// Credential returns the credential that runs a child as the session's user,
// or nil when the agent runs as that user already or cannot change its user.
func (s Session) Credential() *syscall.Credential {
	if os.Geteuid() != 0 || s.UID == uint32(os.Geteuid()) {
		return nil
	}
	return &syscall.Credential{Uid: s.UID, Gid: s.GID, Groups: s.Groups}
}
