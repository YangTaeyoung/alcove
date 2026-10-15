// Package session finds the desktop session of a Linux guest through
// loginctl and describes the user and environment of that session.
package session

import (
	"sort"
	"strconv"
	"strings"
)

// Info is one logind session as `loginctl show-session` prints it.
type Info struct {
	ID      string
	User    string
	UID     uint32
	Seat    string
	Active  bool
	Type    string
	Class   string
	State   string
	Display string
	Locked  bool
	// Started is TimestampMonotonic, in microseconds since boot.
	Started uint64
}

// Account is the passwd entry of a session's user.
type Account struct {
	Name   string
	UID    uint32
	GID    uint32
	Groups []uint32
	Home   string
}

// Session is the desktop session the agent serves: its user, the user's
// groups and home directory, and the environment of programs started in it.
type Session struct {
	ID     string
	User   string
	UID    uint32
	GID    uint32
	Groups []uint32
	Home   string
	Type   string
	Locked bool
	Env    []string
}

// ShowProperties are the properties ParseShow reads.
var ShowProperties = []string{"Id", "Name", "User", "Seat", "Active", "Type", "Class", "State", "Display", "LockedHint", "TimestampMonotonic"}

// ParseList returns the session ids of `loginctl list-sessions --no-legend`:
// the first field of each line whose second field is a number.
func ParseList(out string) []string {
	var ids []string
	for _, line := range strings.Split(out, "\n") {
		f := strings.Fields(line)
		if len(f) < 3 {
			continue
		}
		if _, err := strconv.ParseUint(f[1], 10, 32); err != nil {
			continue
		}
		ids = append(ids, f[0])
	}
	return ids
}

// ParseShow returns the sessions of `loginctl show-session <id>...`, whose
// blocks of key=value lines are separated by empty lines. A block without Id
// is left out.
func ParseShow(out string) []Info {
	var sessions []Info
	cur := map[string]string{}
	flush := func() {
		if cur["Id"] != "" {
			sessions = append(sessions, infoFrom(cur))
		}
		cur = map[string]string{}
	}
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimRight(line, "\r")
		if line == "" {
			flush()
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		if _, seen := cur[k]; seen && k == "Id" {
			flush()
		}
		cur[k] = v
	}
	flush()
	return sessions
}

func infoFrom(m map[string]string) Info {
	uid, _ := strconv.ParseUint(m["User"], 10, 32)
	started, _ := strconv.ParseUint(m["TimestampMonotonic"], 10, 64)
	return Info{
		ID: m["Id"], User: m["Name"], UID: uint32(uid), Seat: m["Seat"], Active: m["Active"] == "yes",
		Type: m["Type"], Class: m["Class"], State: m["State"], Display: m["Display"],
		Locked: m["LockedHint"] == "yes", Started: started,
	}
}

// graphical reports whether a session type draws a desktop.
func graphical(t string) bool { return t == "wayland" || t == "x11" || t == "mir" }

// Pick chooses the desktop session among sessions: the active session of
// seat0, else the only graphical session, else the user session that began
// first. Only sessions of class user that are not closing are chosen.
func Pick(sessions []Info) (Info, bool) {
	var users []Info
	for _, s := range sessions {
		if strings.HasPrefix(s.Class, "user") && s.State != "closing" {
			users = append(users, s)
		}
	}
	for _, s := range users {
		if s.Seat == "seat0" && s.Active {
			return s, true
		}
	}
	var desktops []Info
	for _, s := range users {
		if graphical(s.Type) {
			desktops = append(desktops, s)
		}
	}
	if len(desktops) == 1 {
		return desktops[0], true
	}
	if len(users) == 0 {
		return Info{}, false
	}
	sort.SliceStable(users, func(i, j int) bool { return users[i].Started < users[j].Started })
	return users[0], true
}

// DefaultPath is the PATH of session programs when the agent has none.
const DefaultPath = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

// Environment returns the environment of programs started in the session s
// of account a. runtimeEntries are the names in the user's runtime folder
// /run/user/<uid>, nil when that folder does not exist; path is the agent's
// PATH. WAYLAND_DISPLAY names the wayland-0 socket, or the first other
// wayland-<n> socket, of a wayland session; DISPLAY is the session's display.
func Environment(s Info, a Account, runtimeEntries []string, path string) []string {
	if path == "" {
		path = DefaultPath
	}
	env := []string{"HOME=" + a.Home, "USER=" + a.Name, "LOGNAME=" + a.Name, "PATH=" + path}
	if runtimeEntries != nil {
		dir := "/run/user/" + strconv.FormatUint(uint64(a.UID), 10)
		env = append(env, "XDG_RUNTIME_DIR="+dir)
		if s.Type == "wayland" {
			if socket := waylandSocket(runtimeEntries); socket != "" {
				env = append(env, "WAYLAND_DISPLAY="+socket)
			}
		}
		for _, e := range runtimeEntries {
			if e == "bus" {
				env = append(env, "DBUS_SESSION_BUS_ADDRESS=unix:path="+dir+"/bus")
				break
			}
		}
	}
	if s.Display != "" {
		env = append(env, "DISPLAY="+s.Display)
	}
	if s.Type != "" {
		env = append(env, "XDG_SESSION_TYPE="+s.Type)
	}
	return env
}

// waylandSocket returns wayland-0 when entries hold it, else the first other
// wayland-<n> entry in name order, else "".
func waylandSocket(entries []string) string {
	var found []string
	for _, e := range entries {
		n, ok := strings.CutPrefix(e, "wayland-")
		if !ok {
			continue
		}
		if _, err := strconv.Atoi(n); err != nil {
			continue
		}
		if e == "wayland-0" {
			return e
		}
		found = append(found, e)
	}
	if len(found) == 0 {
		return ""
	}
	sort.Strings(found)
	return found[0]
}

// New combines a session and its account into a Session.
func New(s Info, a Account, env []string) Session {
	return Session{ID: s.ID, User: a.Name, UID: a.UID, GID: a.GID, Groups: a.Groups, Home: a.Home,
		Type: s.Type, Locked: s.Locked, Env: env}
}
