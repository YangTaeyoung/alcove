//go:build !windows

package server

import (
	"reflect"
	"testing"
)

// psSample is `ps axo pid=,ppid=,rss=,args=` of an Ubuntu 26.04 guest.
const psSample = `      1       0 13312 /sbin/init splash
      2       0     0 [kthreadd]
   2420       1  8704 sshd: /usr/sbin/sshd -D [listener] 0 of 10-100 startups
   3216    1990 61440 /usr/bin/gnome-text-editor
   3300    1990  4096 python3 /opt/tool/server.py --port 8080
`

func TestProcessNamesComeFromTheKernelName(t *testing.T) {
	comms := map[int]string{1: "systemd", 2: "kthreadd", 2420: "sshd", 3216: "gnome-text-edit", 3300: "python3"}
	got := parseProcesses(psSample, func(pid int) (string, bool) {
		c, ok := comms[pid]
		return c, ok
	})
	want := []procInfo{
		{PID: 1, PPID: 0, MemKB: 13312, Name: "systemd", Path: "/sbin/init", Cmd: "/sbin/init splash"},
		{PID: 2, PPID: 0, MemKB: 0, Name: "kthreadd", Cmd: "[kthreadd]"},
		{PID: 2420, PPID: 1, MemKB: 8704, Name: "sshd", Cmd: "sshd: /usr/sbin/sshd -D [listener] 0 of 10-100 startups"},
		{PID: 3216, PPID: 1990, MemKB: 61440, Name: "gnome-text-editor", Path: "/usr/bin/gnome-text-editor", Cmd: "/usr/bin/gnome-text-editor"},
		{PID: 3300, PPID: 1990, MemKB: 4096, Name: "python3", Cmd: "python3 /opt/tool/server.py --port 8080"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("processes\n%+v\nwant\n%+v", got, want)
	}
}

func TestProcessNamesWithoutAKernelNameComeFromTheFirstArgument(t *testing.T) {
	got := parseProcesses(psSample, func(int) (string, bool) { return "", false })
	if got[2].Name != "sshd:" || got[3].Name != "gnome-text-editor" {
		t.Fatalf("processes %+v", got)
	}
}
