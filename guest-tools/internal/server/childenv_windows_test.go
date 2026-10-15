//go:build windows

package server

import (
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
	"github.com/YangTaeyoung/alcove/guest-tools/internal/sysfolder"
)

// systemProgram returns the path of the program name in the System32 folder
// of systemFolders, or name alone when that folder cannot be read.
func systemProgram(name string) string {
	_, system, err := systemFolders(windowsFolder)
	if err != nil {
		return name
	}
	return system + `\` + name
}

// plantInTestEnvironment sets the profiler variables in the test process's
// environment and puts a new folder first in its PATH that holds where.bat
// and alcove-planted-only.bat, each of which writes its name to marker; it
// returns that folder.
func plantInTestEnvironment(t *testing.T, marker string) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "planted")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"where", "alcove-planted-only"} {
		script := "@echo " + name + "> \"" + marker + "\"\r\n"
		if err := os.WriteFile(filepath.Join(dir, name+".bat"), []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("COR_ENABLE_PROFILING", "1")
	t.Setenv("COR_PROFILER", "{8f2a1c5e-0b7d-4e3a-9c61-2d4f6a8b0e11}")
	t.Setenv("DOTNET_STARTUP_HOOKS", filepath.Join(dir, "hook.dll"))
	t.Setenv("PATH", dir+";"+os.Getenv("PATH"))
	return dir
}

// expectPlantedNotRun fails the test when a planted script wrote marker.
func expectPlantedNotRun(t *testing.T, marker string) {
	t.Helper()
	if b, err := os.ReadFile(marker); err == nil {
		t.Fatalf("the planted %s ran", strings.TrimSpace(string(b)))
	}
}

func TestTheChildEnvironmentTakesNothingFromTheAgentsEnvironment(t *testing.T) {
	want, err := childEnvironment()
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	for _, name := range []string{"COR_ENABLE_PROFILING", "COR_PROFILER", "DOTNET_STARTUP_HOOKS", "PSModuleAnalysisCachePath", "PATH", "PATHEXT", "ComSpec", "TEMP", "TMP",
		"USERPROFILE", "HOMEDRIVE", "HOMEPATH", "APPDATA", "LOCALAPPDATA", "SystemRoot", "windir", "SystemDrive", "ProgramData",
		"ProgramFiles", "USERNAME", "USERDOMAIN", "COMPUTERNAME"} {
		t.Setenv(name, dir)
	}
	got, err := childEnvironment()
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("with the agent's variables set to %s:\n got %q, %v\nwant %q", dir, got, err, want)
	}
	u, err := user.Current()
	if err != nil {
		t.Fatal(err)
	}
	if home := envValue(want, "USERPROFILE"); !strings.EqualFold(home, u.HomeDir) {
		t.Errorf("USERPROFILE is %q; the account's profile is %q", home, u.HomeDir)
	}
	if account := envValue(want, "USERDOMAIN") + `\` + envValue(want, "USERNAME"); !strings.EqualFold(account, u.Username) {
		t.Errorf("the account is %q; expected %q", account, u.Username)
	}
	if temp, local := envValue(want, "TEMP"), envValue(want, "LOCALAPPDATA"); temp != local+`\Temp` || envValue(want, "TMP") != temp {
		t.Errorf("TEMP %q, TMP %q, LOCALAPPDATA %q", temp, envValue(want, "TMP"), local)
	}
	if envValue(want, "OS") != "Windows_NT" {
		t.Errorf("OS is %q", envValue(want, "OS"))
	}
	for _, name := range []string{"Path", "PATHEXT", "ComSpec", "NUMBER_OF_PROCESSORS", "PROCESSOR_ARCHITECTURE", "SystemRoot", "windir",
		"SystemDrive", "ProgramData", "ProgramFiles", "COMPUTERNAME", "HOMEDRIVE", "HOMEPATH", "APPDATA"} {
		if envValue(want, name) == "" {
			t.Errorf("%s is missing from %q", name, want)
		}
	}
	windows, err := sysfolder.WindowsFolder()
	if err != nil {
		t.Fatal(err)
	}
	if path := strings.ToLower(envValue(want, "Path")); !strings.HasPrefix(path, strings.ToLower(windows)+`\system32;`) {
		t.Errorf("Path is %q", envValue(want, "Path"))
	}
}

func TestTheAgentsHomeIsTheProfileFolderWhateverTheEnvironmentSays(t *testing.T) {
	u, err := user.Current()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("USERPROFILE", t.TempDir())
	t.Setenv("HOMEDRIVE", "Q:")
	t.Setenv("HOMEPATH", `\elsewhere`)
	if got := agentHome(); !strings.EqualFold(got, u.HomeDir) {
		t.Fatalf("agentHome is %q; the account's profile is %q", got, u.HomeDir)
	}
	s := New(Options{Clipboard: &fakeClipboard{}})
	defer s.Close()
	if got := s.homeDir(); !strings.EqualFold(got, u.HomeDir) {
		t.Fatalf("the home of requests is %q; expected %q", got, u.HomeDir)
	}
}

func TestAnExecChildDoesNotGetTheAgentsEnvironmentOrRunAProgramOfItsPath(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "ran.txt")
	planted := plantInTestEnvironment(t, marker)
	const show = `"[$env:COR_ENABLE_PROFILING|$env:COR_PROFILER|$env:DOTNET_STARTUP_HOOKS]"; $env:PATH`
	expectClean := func(what, out string) {
		t.Helper()
		lines := strings.Split(strings.TrimSpace(out), "\n")
		if len(lines) != 2 || strings.TrimSpace(lines[0]) != "[||]" || strings.Contains(strings.ToLower(out), strings.ToLower(planted)) {
			t.Fatalf("%s printed %q", what, out)
		}
	}
	c, _ := newRPCClient(t, Options{})

	res := c.ok("exec.run", proto.Message{"cmd": show})
	expectClean("exec.run", res.String("stdout"))

	res = c.ok("exec.run", proto.Message{"cmd": "echo [%COR_PROFILER%]", "shell": "cmd"})
	if got := strings.TrimSpace(res.String("stdout")); got != "[%COR_PROFILER%]" {
		t.Fatalf("cmd printed %q", got)
	}

	out, code := runShell(show)
	if code != 0 {
		t.Fatalf("the v1 exec printed %q, code %d", out, code)
	}
	expectClean("the v1 exec", out)

	res = c.ok("exec.run", proto.Message{"argv": []any{"where", "cmd.exe"}})
	if res.Int("code") != 0 || !strings.Contains(strings.ToLower(res.String("stdout")), `\system32\cmd.exe`) {
		t.Fatalf("where printed %q, stderr %q, code %d", res.String("stdout"), res.String("stderr"), res.Int("code"))
	}
	expectPlantedNotRun(t, marker)

	res = c.call("exec.run", proto.Message{"argv": []any{"alcove-planted-only"}})
	if res["ok"] != false || !strings.Contains(res.String("error"), "'alcove-planted-only' is not in a folder of the command's PATH") {
		t.Fatalf("alcove-planted-only gave %v", res)
	}
	expectPlantedNotRun(t, marker)

	job := c.ok("exec.start", proto.Message{"argv": []any{"where", "cmd.exe"}}).String("job")
	if ev := c.event("job.exited"); ev.String("job") != job || ev.Int("code") != 0 {
		t.Fatalf("the job %s ended with %v", job, ev)
	}
	expectPlantedNotRun(t, marker)

	res = c.ok("exec.run", proto.Message{"cmd": `"[$env:COR_PROFILER]"`, "env": map[string]any{"COR_PROFILER": "from-env"}})
	if got := strings.TrimSpace(res.String("stdout")); got != "[from-env]" {
		t.Fatalf("with env COR_PROFILER the command printed %q", got)
	}
}

func TestAnAppLaunchChildDoesNotGetTheAgentsEnvironment(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "ran.txt")
	planted := plantInTestEnvironment(t, marker)
	out := filepath.Join(t.TempDir(), "env.txt")
	c, _ := newRPCClient(t, Options{})
	c.ok("app.launch", proto.Message{"path": "cmd.exe", "args": []any{"/c", "set", ">", out}, "wait_window_ms": 0,
		"env": map[string]any{"ALCOVE_E2E": "from-env"}})
	if ev := c.event("process.exited"); ev.Int("code") != 0 {
		t.Fatalf("cmd.exe ended with %v", ev)
	}
	b, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	env := strings.Split(strings.ReplaceAll(strings.TrimSpace(string(b)), "\r\n", "\n"), "\n")
	if got := envValue(env, "ALCOVE_E2E"); got != "from-env" {
		t.Fatalf("ALCOVE_E2E is %q in %q", got, env)
	}
	for _, kv := range env {
		name, value, _ := strings.Cut(kv, "=")
		if strings.HasPrefix(strings.ToUpper(name), "COR_") || strings.EqualFold(name, "DOTNET_STARTUP_HOOKS") ||
			strings.Contains(strings.ToLower(value), strings.ToLower(planted)) {
			t.Errorf("the launched program got %s", kv)
		}
	}
	if temp := envValue(env, "TEMP"); temp != envValue(env, "LOCALAPPDATA")+`\Temp` {
		t.Errorf("TEMP is %q", temp)
	}
	expectPlantedNotRun(t, marker)
}

func TestASystemCommandRunsInTheEnvironmentOfTheSystemFolders(t *testing.T) {
	plantInTestEnvironment(t, filepath.Join(t.TempDir(), "ran.txt"))
	windows, err := sysfolder.WindowsFolder()
	if err != nil {
		t.Fatal(err)
	}
	c, err := systemCommand("taskkill.exe", "/?")
	if err != nil {
		t.Fatal(err)
	}
	ps, err := windowsPowerShell(windowsFolder)
	if err != nil {
		t.Fatal(err)
	}
	if want := windows + `\System32\taskkill.exe`; !strings.EqualFold(c.Path, want) || !reflect.DeepEqual(c.Env, ps.systemEnv()) {
		t.Fatalf("taskkill runs %q in %q; expected %q in %q", c.Path, c.Env, want, ps.systemEnv())
	}
	if out, err := c.CombinedOutput(); err != nil {
		if _, exited := err.(*exec.ExitError); !exited {
			t.Fatalf("taskkill /? did not start: %v: %s", err, out)
		}
	}
}
