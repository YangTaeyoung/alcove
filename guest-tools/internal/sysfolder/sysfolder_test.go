package sysfolder

import "testing"

func base(t *testing.T) map[string]string {
	t.Helper()
	vars, err := BaseVars(`C:\WINDOWS`)
	if err != nil {
		t.Fatal(err)
	}
	return vars
}

func TestASystemFolderValueIsExpandedWithTheWindowsFolder(t *testing.T) {
	for _, c := range []struct{ raw, want string }{
		{`%SystemDrive%\ProgramData`, `C:\ProgramData`},
		{`%systemdrive%\ProgramData`, `C:\ProgramData`},
		{`%SystemRoot%\..\ProgramData`, `C:\WINDOWS\..\ProgramData`},
		{`%windir%\Temp`, `C:\WINDOWS\Temp`},
		{`%SYSTEMROOT%\System32\OpenSSH\`, `C:\WINDOWS\System32\OpenSSH\`},
		{`D:\ProgramData`, `D:\ProgramData`},
	} {
		got, err := Expand(c.raw, base(t))
		if err != nil || got != c.want {
			t.Errorf("%s gives %q, %v; expected %q", c.raw, got, err, c.want)
		}
	}
}

func TestASystemFolderValueWithAnotherVariableOrNoDriveIsRefused(t *testing.T) {
	for _, raw := range []string{`%ALLUSERSPROFILE%`, `%SystemDrive%\%USERNAME%`, `%SystemDrive\ProgramData`, `ProgramData`, `\ProgramData`, `\\server\share\ProgramData`, `"C:\x.exe"`, ``} {
		if got, err := Expand(raw, base(t)); err == nil {
			t.Errorf("%q gives %q; expected an error", raw, got)
		}
	}
	if got, err := BaseVars(`WINDOWS`); err == nil {
		t.Errorf("a Windows folder without a drive gives %v; expected an error", got)
	}
}

func TestAddedVariablesAreExpandedByName(t *testing.T) {
	vars := base(t)
	vars["programfiles(x86)"] = `C:\Program Files (x86)`
	got, err := Expand(`%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe`, vars)
	if want := `C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe`; err != nil || got != want {
		t.Fatalf("got %q, %v; expected %q", got, err, want)
	}
}
