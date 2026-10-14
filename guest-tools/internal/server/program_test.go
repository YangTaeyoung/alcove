package server

import "testing"

func TestBareProgramNamesResolveThroughSystemPlacesOnly(t *testing.T) {
	files := map[string]bool{
		`C:\Windows\system32\notepad.exe`: true,
		`C:\Windows\setup.cmd`:            true,
	}
	appPaths := map[string]string{
		`SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe`:          `"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"`,
		`SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\old.exe`: `C:\Old\old.exe`,
	}
	dirs := []string{`C:\Windows\system32`, ``, `C:\Windows`}
	pick := func(p string) (string, error) {
		return systemProgramPath(p, dirs, func(f string) bool { return files[f] }, func(k string) string { return appPaths[k] })
	}
	cases := map[string]string{
		`notepad`:        `C:\Windows\system32\notepad.exe`,
		`notepad.exe`:    `C:\Windows\system32\notepad.exe`,
		`setup.cmd`:      `C:\Windows\setup.cmd`,
		`msedge.exe`:     `C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe`,
		`msedge`:         `C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe`,
		`old`:            `C:\Old\old.exe`,
		`C:\Tools\x.exe`: `C:\Tools\x.exe`,
		`.\x.exe`:        `.\x.exe`,
		`D:relative.exe`: `D:relative.exe`,
	}
	for in, want := range cases {
		if got, err := pick(in); err != nil || got != want {
			t.Errorf("%s: %q %v, expected %q", in, got, err, want)
		}
	}
	_, err := pick("code")
	want := "'code' is not in the system folders of PATH or under HKLM App Paths; pass the full path of the program"
	if err == nil || err.Error() != want {
		t.Fatalf("unknown name: %v", err)
	}
}
