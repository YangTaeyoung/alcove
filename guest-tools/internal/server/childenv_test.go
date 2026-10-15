package server

import (
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
	"github.com/YangTaeyoung/alcove/guest-tools/internal/sysfolder"
)

// testEnvInputs are windowsEnvInputs of a machine whose Windows folder is
// D:\WINDOWS and whose agent account alcove has the profile D:\Users\alcove.
func testEnvInputs(t *testing.T) windowsEnvInputs {
	t.Helper()
	folders, err := sysfolder.BaseVars(`D:\WINDOWS`)
	if err != nil {
		t.Fatal(err)
	}
	folders["programfiles"] = `D:\Program Files`
	folders["programfiles(x86)"] = `D:\Program Files (x86)`
	folders["commonprogramfiles"] = `D:\Program Files\Common Files`
	return windowsEnvInputs{
		machine: []sysfolder.Value{
			{Name: "ComSpec", Text: `%SystemRoot%\system32\cmd.exe`, Expand: true},
			{Name: "NUMBER_OF_PROCESSORS", Text: "4"},
			{Name: "OS", Text: "Windows_NT"},
			{Name: "Path", Text: `%SystemRoot%\system32;%SystemRoot%;%USERPROFILE%\bin;C:\Tools;relative;;%SYSTEMROOT%\System32\OpenSSH\`, Expand: true},
			{Name: "PATHEXT", Text: ".COM;.EXE;.BAT"},
			{Name: "PROCESSOR_ARCHITECTURE", Text: "ARM64"},
			{Name: "PSModulePath", Text: `%ProgramFiles%\WindowsPowerShell\Modules;%SystemRoot%\system32\WindowsPowerShell\v1.0\Modules`, Expand: true},
			{Name: "TEMP", Text: `%SystemRoot%\TEMP`, Expand: true},
			{Name: "TMP", Text: `%SystemRoot%\TEMP`, Expand: true},
			{Name: "USERNAME", Text: "SYSTEM"},
			{Name: "windir", Text: `%SystemRoot%`, Expand: true},
			{Name: "JAVA_TOOLS", Text: `%JAVA_HOME%\bin`, Expand: true},
			{Name: "LITERAL", Text: `100%`},
			{Name: "", Text: "default value"},
			{Name: "A=B", Text: "x"},
		},
		folders:     folders,
		programData: `D:\ProgramData`,
		profile:     `D:\Users\alcove`,
		user:        "alcove",
		domain:      "DESKTOP-1",
		computer:    "DESKTOP-1",
	}
}

// plantedFolder is a user folder that the agent's own PATH names first.
const plantedFolder = `C:\Users\alcove\planted`

// plantInAgentEnvironment sets the profiler variables, ComSpec and
// PSModuleAnalysisCachePath of plantedFolder, and a PATH whose first folder
// is plantedFolder in the test process's environment.
func plantInAgentEnvironment(t *testing.T) {
	t.Helper()
	t.Setenv("COR_ENABLE_PROFILING", "1")
	t.Setenv("COR_PROFILER", "{8f2a1c5e-0b7d-4e3a-9c61-2d4f6a8b0e11}")
	t.Setenv("DOTNET_STARTUP_HOOKS", `C:\Users\alcove\hook.dll`)
	t.Setenv("ComSpec", plantedFolder+`\cmd.exe`)
	t.Setenv("PSModuleAnalysisCachePath", plantedFolder+`\cache`)
	t.Setenv("PATH", plantedFolder+";"+os.Getenv("PATH"))
}

func TestTheWindowsChildEnvironmentIsBuiltFromTheMachineAndTheProfile(t *testing.T) {
	plantInAgentEnvironment(t)
	got := windowsChildEnv(testEnvInputs(t))
	want := []string{
		`APPDATA=D:\Users\alcove\AppData\Roaming`,
		`CommonProgramFiles=D:\Program Files\Common Files`,
		`COMPUTERNAME=DESKTOP-1`,
		`ComSpec=D:\WINDOWS\system32\cmd.exe`,
		`HOMEDRIVE=D:`,
		`HOMEPATH=\Users\alcove`,
		`LITERAL=100%`,
		`LOCALAPPDATA=D:\Users\alcove\AppData\Local`,
		`NUMBER_OF_PROCESSORS=4`,
		`OS=Windows_NT`,
		`Path=D:\WINDOWS\system32;D:\WINDOWS;C:\Tools;D:\WINDOWS\System32\OpenSSH\`,
		`PATHEXT=.COM;.EXE;.BAT`,
		`PROCESSOR_ARCHITECTURE=ARM64`,
		`ProgramData=D:\ProgramData`,
		`ProgramFiles=D:\Program Files`,
		`ProgramFiles(x86)=D:\Program Files (x86)`,
		`PSModulePath=D:\Program Files\WindowsPowerShell\Modules;D:\WINDOWS\system32\WindowsPowerShell\v1.0\Modules`,
		`SystemDrive=D:`,
		`SystemRoot=D:\WINDOWS`,
		`TEMP=D:\Users\alcove\AppData\Local\Temp`,
		`TMP=D:\Users\alcove\AppData\Local\Temp`,
		`USERDOMAIN=DESKTOP-1`,
		`USERNAME=alcove`,
		`USERPROFILE=D:\Users\alcove`,
		`windir=D:\WINDOWS`,
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("environment\n got %q\nwant %q", got, want)
	}
}

func TestTheWindowsChildEnvironmentLeavesOutWhatTheAccountDoesNotName(t *testing.T) {
	in := testEnvInputs(t)
	in.user, in.domain, in.computer, in.programData = "", "", "", ""
	for _, kv := range windowsChildEnv(in) {
		name, _, _ := strings.Cut(kv, "=")
		switch strings.ToUpper(name) {
		case "USERNAME", "USERDOMAIN", "COMPUTERNAME", "PROGRAMDATA":
			t.Errorf("%s is set without a value of its own", kv)
		}
	}
}

// windowsTestSystem is a Windows commandSystem whose base environment is
// windowsChildEnv of testEnvInputs and whose files are those of files.
func windowsTestSystem(t *testing.T, files ...string) commandSystem {
	t.Helper()
	sys := testSystem("windows", windowsChildEnv(testEnvInputs(t))...)
	sys.isFile = func(p string) bool {
		for _, f := range files {
			if strings.EqualFold(f, p) {
				return true
			}
		}
		return false
	}
	return sys
}

func TestAWindowsCommandGetsTheBaseEnvironmentAndNotTheAgents(t *testing.T) {
	plantInAgentEnvironment(t)
	sys := windowsTestSystem(t, plantedFolder+`\where.bat`, `D:\WINDOWS\system32\where.exe`)
	for _, req := range []proto.Message{
		{"argv": []any{"where", "cmd.exe"}},
		{"cmd": "dir", "shell": "cmd"},
		{"cmd": "dir"},
	} {
		c, err := buildCommand(req, sys)
		if err != nil {
			t.Fatalf("%v: %v", req, err)
		}
		if c.Env == nil {
			t.Fatalf("%v inherits the agent's environment", req)
		}
		for _, kv := range c.Env {
			name, value, _ := strings.Cut(kv, "=")
			if strings.HasPrefix(strings.ToUpper(name), "COR_") || strings.EqualFold(name, "DOTNET_STARTUP_HOOKS") ||
				strings.EqualFold(name, "PSModuleAnalysisCachePath") || strings.Contains(value, plantedFolder) {
				t.Errorf("%v gets %s", req, kv)
			}
		}
		if got := envValue(c.Env, "TEMP"); got != `D:\Users\alcove\AppData\Local\Temp` {
			t.Errorf("%v gets TEMP %q", req, got)
		}
		if got := envValue(c.Env, "ComSpec"); got != `D:\WINDOWS\system32\cmd.exe` {
			t.Errorf("%v gets ComSpec %q", req, got)
		}
	}
}

func TestABareArgvNameIsLookedUpInThePathOfTheCommandsEnvironment(t *testing.T) {
	plantInAgentEnvironment(t)
	sys := windowsTestSystem(t, plantedFolder+`\where.bat`, `D:\WINDOWS\system32\where.exe`, plantedFolder+`\planted-only.exe`,
		`E:\bin\tool.cmd`, `D:\WINDOWS\explorer.exe`)

	c, err := buildCommand(proto.Message{"argv": []any{"where", "cmd.exe"}}, sys)
	if err != nil {
		t.Fatal(err)
	}
	if want := `D:\WINDOWS\system32\where.exe`; c.Path != want || !reflect.DeepEqual(c.Args, []string{"where", "cmd.exe"}) {
		t.Fatalf("where runs %q with %q; expected %q", c.Path, c.Args, want)
	}

	c, err = buildCommand(proto.Message{"argv": []any{"explorer.exe"}, "shell": "none"}, sys)
	if err != nil || c.Path != `D:\WINDOWS\explorer.exe` {
		t.Fatalf("explorer.exe runs %v, %v", c, err)
	}

	_, err = buildCommand(proto.Message{"argv": []any{"planted-only"}}, sys)
	if want := "'planted-only' is not in a folder of the command's PATH (the machine's PATH, or PATH of env); pass the full path of the program"; err == nil || err.Error() != want {
		t.Fatalf("planted-only gives %v", err)
	}

	c, err = buildCommand(proto.Message{"argv": []any{"tool"}, "env": map[string]any{"path": `E:\bin`, "PATHEXT": ".EXE;.CMD"}}, sys)
	if err != nil || c.Path != `E:\bin\tool.cmd` {
		t.Fatalf("tool with env PATH runs %v, %v", c, err)
	}
	if got := c.Env[len(c.Env)-2:]; !reflect.DeepEqual(got, []string{"PATHEXT=.EXE;.CMD", `path=E:\bin`}) {
		t.Fatalf("the request's env ends the environment as %q", got)
	}

	c, err = buildCommand(proto.Message{"argv": []any{`C:\x\prog.exe`}}, sys)
	if err != nil || c.Path != `C:\x\prog.exe` {
		t.Fatalf("a full path runs %v, %v", c, err)
	}
}

func TestTheRequestsEnvWinsOverTheBaseEnvironment(t *testing.T) {
	sys := windowsTestSystem(t)
	c, err := buildCommand(proto.Message{"cmd": "dir", "shell": "cmd", "env": map[string]any{"temp": `E:\tmp`, "COR_PROFILER": "{x}"}}, sys)
	if err != nil {
		t.Fatal(err)
	}
	if got := envValue(c.Env, "TEMP"); got != `E:\tmp` {
		t.Fatalf("TEMP is %q", got)
	}
	if got := envValue(c.Env, "cor_profiler"); got != "{x}" {
		t.Fatalf("COR_PROFILER is %q", got)
	}
}

func TestLookWindowsProgramTriesEachFolderWithTheExtensionsOfPATHEXT(t *testing.T) {
	files := map[string]bool{`C:\a\x.bat`: true, `C:\b\x.exe`: true, `C:\b\y.txt`: true, `C:\c\z`: true, `C:\c\z.exe`: true, `rel\w.exe`: true}
	isFile := func(p string) bool { return files[p] }
	for _, c := range []struct {
		name string
		env  []string
		want string
	}{
		{"x", []string{`PATH=C:\a;C:\b`, "PATHEXT=.COM;.EXE;.BAT"}, `C:\a\x.bat`},
		{"x", []string{`PATH=C:\a;C:\b`, "PATHEXT=.EXE"}, `C:\b\x.exe`},
		{"x", []string{`Path=C:\a\;C:\b`, "PATHEXT=.EXE", `PATH=C:\b`}, `C:\b\x.exe`},
		{"x", []string{`PATH=;C:\b\`}, `C:\b\x.exe`},
		{"x.exe", []string{`PATH=C:\a;C:\b`, "PATHEXT=.BAT"}, `C:\b\x.exe`},
		{"y.txt", []string{`PATH=C:\b`}, `C:\b\y.txt`},
		{"z", []string{`PATH=C:\c`, "PATHEXT=exe"}, `C:\c\z.exe`},
		{"w", []string{`PATH=rel;C:\a`}, ""},
		{"x", []string{"PATHEXT=.EXE"}, ""},
	} {
		got, ok := lookWindowsProgram(c.name, c.env, isFile)
		if got != c.want || ok != (c.want != "") {
			t.Errorf("%s in %q gives %q, %v; expected %q", c.name, c.env, got, ok, c.want)
		}
	}
}
