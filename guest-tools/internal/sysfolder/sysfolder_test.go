package sysfolder

import (
	"errors"
	"reflect"
	"testing"
)

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

func TestATextValueIsExpandedWithoutBeingAFolder(t *testing.T) {
	vars := base(t)
	vars["programfiles"] = `C:\Program Files`
	for _, c := range []struct{ raw, want string }{
		{`.COM;.EXE;.BAT`, `.COM;.EXE;.BAT`},
		{`%ProgramFiles%\WindowsPowerShell\Modules;%SystemRoot%\system32\WindowsPowerShell\v1.0\Modules`,
			`C:\Program Files\WindowsPowerShell\Modules;C:\WINDOWS\system32\WindowsPowerShell\v1.0\Modules`},
		{`%SystemRoot%`, `C:\WINDOWS`},
		{`Windows_NT`, `Windows_NT`},
		{``, ``},
	} {
		got, err := ExpandText(c.raw, vars)
		if err != nil || got != c.want {
			t.Errorf("%s gives %q, %v; expected %q", c.raw, got, err, c.want)
		}
	}
	for _, raw := range []string{`%JAVA_HOME%\bin`, `%SystemRoot%\%USERNAME%`, `100%`, `%SystemRoot`} {
		if got, err := ExpandText(raw, vars); err == nil {
			t.Errorf("%q gives %q; expected an error", raw, got)
		}
	}
}

func TestAStringBufferHoldsEveryByteOfTheValue(t *testing.T) {
	for size := uint32(0); size < 9; size++ {
		if got := stringUnits(size); 2*got < int(size) || 2*got > int(size)+1 {
			t.Errorf("a value of %d bytes gets %d UTF-16 units", size, got)
		}
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

// readValues returns a reader of the values of values that fails for a name
// values does not hold.
func readValues(values map[string]string) func(string) (string, error) {
	return func(name string) (string, error) {
		v, ok := values[name]
		if !ok {
			return "", errors.New("the value does not exist")
		}
		return v, nil
	}
}

func TestTheProgramFilesFoldersOfAnArmMachineAreRead(t *testing.T) {
	vars, err := folderVars(`C:\WINDOWS`, readValues(map[string]string{
		"ProgramFilesDir":       `C:\Program Files`,
		"ProgramFilesDir (x86)": `C:\Program Files (x86)`,
		"ProgramFilesDir (Arm)": `C:\Program Files (Arm)`,
		"ProgramW6432Dir":       `C:\Program Files`,
		"CommonFilesDir":        `C:\Program Files\Common Files`,
		"CommonFilesDir (x86)":  `C:\Program Files (x86)\Common Files`,
		"CommonFilesDir (Arm)":  `C:\Program Files (Arm)\Common Files`,
		"CommonW6432Dir":        `C:\Program Files\Common Files`,
	}))
	want := map[string]string{
		"systemdrive":             `C:`,
		"systemroot":              `C:\WINDOWS`,
		"windir":                  `C:\WINDOWS`,
		"programfiles":            `C:\Program Files`,
		"programfiles(x86)":       `C:\Program Files (x86)`,
		"programfiles(arm)":       `C:\Program Files (Arm)`,
		"programw6432":            `C:\Program Files`,
		"commonprogramfiles":      `C:\Program Files\Common Files`,
		"commonprogramfiles(x86)": `C:\Program Files (x86)\Common Files`,
		"commonprogramfiles(arm)": `C:\Program Files (Arm)\Common Files`,
		"commonprogramw6432":      `C:\Program Files\Common Files`,
	}
	if err != nil || !reflect.DeepEqual(vars, want) {
		t.Fatalf("got %v, %v; expected %v", vars, err, want)
	}
}

func TestAProgramFilesValueThatIsMissingEmptyOrNotAFolderIsLeftOut(t *testing.T) {
	vars, err := folderVars(`D:\WINDOWS`, readValues(map[string]string{
		"ProgramFilesDir":      `%SystemDrive%\Program Files`,
		"CommonFilesDir":       `%ProgramFiles%\Common Files`,
		"ProgramW6432Dir":      ``,
		"CommonFilesDir (Arm)": `Program Files (Arm)\Common Files`,
	}))
	want := map[string]string{
		"systemdrive":  `D:`,
		"systemroot":   `D:\WINDOWS`,
		"windir":       `D:\WINDOWS`,
		"programfiles": `D:\Program Files`,
	}
	if err != nil || !reflect.DeepEqual(vars, want) {
		t.Fatalf("got %v, %v; expected %v", vars, err, want)
	}
	if _, err := folderVars(`WINDOWS`, readValues(nil)); err == nil {
		t.Fatal("a Windows folder without a drive gave no error")
	}
}
