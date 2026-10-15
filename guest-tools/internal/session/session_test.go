package session

import (
	"reflect"
	"testing"
)

// Captured on Ubuntu 26.04.1 (systemd 259) with GNOME on Wayland and the
// autologin of alcove on seat0.
const ubuntuList = `1 1000 alcove seat0 1247 user    tty2 no -
2 1000 alcove -     1255 manager -    no -
`

const ubuntuShow = `Id=1
User=1000
Name=alcove
TimestampMonotonic=13074278
Seat=seat0
Display=
Type=wayland
Class=user
Active=yes
State=active
LockedHint=no

Id=2
User=1000
Name=alcove
TimestampMonotonic=13095058
Seat=
Display=
Type=unspecified
Class=manager
Active=yes
State=active
LockedHint=no
`

var ubuntuRuntime = []string{"at-spi", "bus", "dbus-1", "dconf", "pipewire-0", "pipewire-0.lock", "systemd", "wayland-0", "wayland-0.lock"}

func TestListGivesTheSessionIDs(t *testing.T) {
	if got := ParseList(ubuntuList); !reflect.DeepEqual(got, []string{"1", "2"}) {
		t.Fatalf("ids %q", got)
	}
	header := "SESSION  UID USER   SEAT  LEADER CLASS   TTY  IDLE SINCE\n      3 1001 bob seat0 1 user tty2 no -\n\n1 sessions listed.\nNo sessions.\n"
	if got := ParseList(header); !reflect.DeepEqual(got, []string{"3"}) {
		t.Fatalf("ids %q", got)
	}
}

func TestShowGivesEachSession(t *testing.T) {
	got := ParseShow(ubuntuShow)
	want := []Info{
		{ID: "1", User: "alcove", UID: 1000, Seat: "seat0", Active: true, Type: "wayland", Class: "user", State: "active", Started: 13074278},
		{ID: "2", User: "alcove", UID: 1000, Active: true, Type: "unspecified", Class: "manager", State: "active", Started: 13095058},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("sessions\n%+v\nwant\n%+v", got, want)
	}
}

func TestShowReadsTheLockAndTheDisplay(t *testing.T) {
	got := ParseShow("Id=c2\nName=bob\nUser=1001\nType=x11\nDisplay=:0\nLockedHint=yes\nClass=user\n")
	if len(got) != 1 || !got[0].Locked || got[0].Display != ":0" || got[0].Type != "x11" {
		t.Fatalf("sessions %+v", got)
	}
}

func TestPickTakesTheActiveSeat0Session(t *testing.T) {
	got, ok := Pick(ParseShow(ubuntuShow))
	if !ok || got.ID != "1" {
		t.Fatalf("picked %+v %v", got, ok)
	}
}

func TestPickSkipsTheGreeterAndClosingSessions(t *testing.T) {
	sessions := []Info{
		{ID: "c1", User: "gdm", Seat: "seat0", Active: true, Type: "wayland", Class: "greeter", State: "active"},
		{ID: "4", User: "bob", Seat: "seat0", Active: true, Type: "wayland", Class: "user", State: "closing"},
	}
	if got, ok := Pick(sessions); ok {
		t.Fatalf("picked %+v", got)
	}
}

func TestPickTakesTheOnlyGraphicalSessionWhenNoneIsActiveOnSeat0(t *testing.T) {
	sessions := []Info{
		{ID: "5", User: "alcove", Type: "tty", Class: "user", State: "online", Started: 1},
		{ID: "6", User: "bob", Seat: "seat0", Type: "x11", Class: "user", State: "online", Started: 9},
	}
	if got, ok := Pick(sessions); !ok || got.ID != "6" {
		t.Fatalf("picked %+v %v", got, ok)
	}
}

func TestPickPrefersTheGraphicalSessionOverAnActiveConsoleLogin(t *testing.T) {
	sessions := []Info{
		{ID: "1", User: "alcove", Seat: "seat0", Type: "wayland", Class: "user", State: "online", Started: 1},
		{ID: "9", User: "mallory", Seat: "seat0", Active: true, Type: "tty", Class: "user", State: "active", Started: 50},
	}
	if got, ok := Pick(sessions); !ok || got.ID != "1" {
		t.Fatalf("picked %+v %v", got, ok)
	}
	sessions = append(sessions, Info{ID: "2", User: "bob", Seat: "seat0", Active: true, Type: "x11", Class: "user", State: "active", Started: 60})
	if got, ok := Pick(sessions); !ok || got.ID != "2" {
		t.Fatalf("with an active graphical session picked %+v %v", got, ok)
	}
}

func TestPickTakesTheActiveConsoleSessionWithoutADesktop(t *testing.T) {
	sessions := []Info{
		{ID: "5", User: "alcove", Type: "tty", Class: "user", State: "online", Started: 1},
		{ID: "6", User: "bob", Seat: "seat0", Active: true, Type: "tty", Class: "user", State: "active", Started: 9},
	}
	if got, ok := Pick(sessions); !ok || got.ID != "6" {
		t.Fatalf("picked %+v %v", got, ok)
	}
}

func TestPickTakesTheFirstUserSessionWithoutADesktop(t *testing.T) {
	sessions := []Info{
		{ID: "8", User: "bob", Type: "tty", Class: "user", State: "active", Started: 50},
		{ID: "7", User: "alcove", Type: "tty", Class: "user", State: "active", Started: 20},
		{ID: "9", User: "alcove", Class: "manager", State: "active", Started: 1},
	}
	if got, ok := Pick(sessions); !ok || got.ID != "7" {
		t.Fatalf("picked %+v %v", got, ok)
	}
}

func TestEnvironmentOfAWaylandSession(t *testing.T) {
	info, _ := Pick(ParseShow(ubuntuShow))
	a := Account{Name: "alcove", UID: 1000, GID: 1000, Home: "/home/alcove"}
	got := Environment(info, a, ubuntuRuntime, "/usr/bin:/bin", nil)
	want := []string{"HOME=/home/alcove", "USER=alcove", "LOGNAME=alcove", "PATH=/usr/bin:/bin",
		"XDG_RUNTIME_DIR=/run/user/1000", "WAYLAND_DISPLAY=wayland-0",
		"DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus", "XDG_SESSION_TYPE=wayland"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("env\n%q\nwant\n%q", got, want)
	}
}

func TestEnvironmentOfAnX11SessionWithoutARuntimeFolder(t *testing.T) {
	info := Info{ID: "3", Type: "x11", Display: ":1"}
	a := Account{Name: "bob", UID: 1001, Home: "/home/bob"}
	got := Environment(info, a, nil, "", nil)
	want := []string{"HOME=/home/bob", "USER=bob", "LOGNAME=bob", "PATH=" + DefaultPath, "DISPLAY=:1", "XDG_SESSION_TYPE=x11"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("env %q", got)
	}
}

func TestLocaleFileGivesTheLocaleVariables(t *testing.T) {
	file := "#  File generated by update-locale\nLANG=\"ko_KR.UTF-8\"\nLC_TIME='en_GB.UTF-8'\nLANGUAGE=ko:en\nPATH=/evil\n\nexport LC_ALL=C.UTF-8\n"
	got := ParseLocale(file)
	want := []string{"LANG=ko_KR.UTF-8", "LC_TIME=en_GB.UTF-8", "LANGUAGE=ko:en", "LC_ALL=C.UTF-8"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("locale %q", got)
	}
}

func TestEnvironmentCarriesTheLocale(t *testing.T) {
	info := Info{ID: "3", Type: "x11", Display: ":1"}
	a := Account{Name: "bob", UID: 1001, Home: "/home/bob"}
	got := Environment(info, a, nil, "/usr/bin", []string{"LANG=ko_KR.UTF-8"})
	if got[len(got)-1] != "LANG=ko_KR.UTF-8" {
		t.Fatalf("env %q", got)
	}
}

func TestWaylandSocketPrefersWayland0(t *testing.T) {
	cases := map[string][]string{
		"wayland-0": {"wayland-1", "wayland-0", "wayland-0.lock"},
		"wayland-1": {"wayland-2", "wayland-1.lock", "wayland-1"},
		"":          {"wayland-x", "bus"},
	}
	for want, entries := range cases {
		if got := waylandSocket(entries); got != want {
			t.Errorf("waylandSocket(%q) = %q, want %q", entries, got, want)
		}
	}
}
