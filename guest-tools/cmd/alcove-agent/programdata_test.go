package main

import "testing"

func TestASystemFolderValueIsExpandedWithTheWindowsFolder(t *testing.T) {
	for _, c := range []struct{ raw, want string }{
		{`%SystemDrive%\ProgramData`, `C:\ProgramData`},
		{`%systemdrive%\ProgramData`, `C:\ProgramData`},
		{`%SystemRoot%\..\ProgramData`, `C:\WINDOWS\..\ProgramData`},
		{`%windir%\Temp`, `C:\WINDOWS\Temp`},
		{`D:\ProgramData`, `D:\ProgramData`},
	} {
		got, err := expandSystemFolder(c.raw, `C:\WINDOWS`)
		if err != nil || got != c.want {
			t.Errorf("%s gives %q, %v; expected %q", c.raw, got, err, c.want)
		}
	}
}

func TestASystemFolderValueWithAnotherVariableOrNoDriveIsRefused(t *testing.T) {
	for _, raw := range []string{`%ALLUSERSPROFILE%`, `%SystemDrive%\%USERNAME%`, `%SystemDrive\ProgramData`, `ProgramData`, `\ProgramData`, `\\server\share\ProgramData`, ``} {
		if got, err := expandSystemFolder(raw, `C:\WINDOWS`); err == nil {
			t.Errorf("%q gives %q; expected an error", raw, got)
		}
	}
	if got, err := expandSystemFolder(`%SystemDrive%\ProgramData`, `WINDOWS`); err == nil {
		t.Errorf("a Windows folder without a drive gives %q; expected an error", got)
	}
}
