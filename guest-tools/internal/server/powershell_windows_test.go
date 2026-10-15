//go:build windows

package server

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

// plantModule writes the script module AlcovePlanted, whose functions named
// commands each write their name to marker, into a new module folder and
// returns that folder.
func plantModule(t *testing.T, marker string, commands ...string) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "Modules")
	module := filepath.Join(dir, "AlcovePlanted")
	if err := os.MkdirAll(module, 0o755); err != nil {
		t.Fatal(err)
	}
	quote := func(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }
	var script strings.Builder
	exported := make([]string, len(commands))
	for i, name := range commands {
		fmt.Fprintf(&script, "function %s { [IO.File]::WriteAllText(%s, %s) }\n", name, quote(marker), quote(name))
		exported[i] = quote(name)
	}
	manifest := fmt.Sprintf("@{ RootModule = 'AlcovePlanted.psm1'; ModuleVersion = '1.0'; GUID = '6f1f3c4e-2b7a-4d0e-9a51-3c2d8e7f0a11'; "+
		"FunctionsToExport = @(%s); CmdletsToExport = @(); VariablesToExport = @(); AliasesToExport = @() }", strings.Join(exported, ", "))
	if err := os.WriteFile(filepath.Join(module, "AlcovePlanted.psm1"), []byte(script.String()), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(module, "AlcovePlanted.psd1"), []byte(manifest), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

// plantInEnvironment puts dir first in the test process's PSModulePath and
// sets its PSExecutionPolicyPreference to Bypass.
func plantInEnvironment(t *testing.T, dir string) {
	t.Helper()
	t.Setenv("PSModulePath", dir+";"+os.Getenv("PSModulePath"))
	t.Setenv("PSExecutionPolicyPreference", "Bypass")
}

// expectNotRun fails the test when the planted module wrote marker.
func expectNotRun(t *testing.T, marker string) {
	t.Helper()
	if b, err := os.ReadFile(marker); err == nil {
		t.Fatalf("the planted %s ran", b)
	}
}

func TestProcListDoesNotLoadAModuleOfTheInheritedModulePath(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "ran.txt")
	plantInEnvironment(t, plantModule(t, marker, "Get-CimInstance", "Select-Object", "ConvertTo-Json"))
	procs, err := listProcesses()
	if err != nil {
		t.Fatalf("listProcesses: %v", err)
	}
	expectNotRun(t, marker)
	for _, p := range procs {
		if p.PID == os.Getpid() {
			return
		}
	}
	t.Fatalf("the %d listed processes lack this test, pid %d", len(procs), os.Getpid())
}

func TestExecPowerShellDoesNotLoadAModuleOfTheInheritedModulePath(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "ran.txt")
	plant := plantModule(t, marker, "Join-Path")
	plantInEnvironment(t, plant)
	const check = `Join-Path a b; $env:PSModulePath -eq ($PSHOME + '\Modules'); Get-ExecutionPolicy`
	want := []string{`a\b`, "True", "Restricted"}
	c, _ := newRPCClient(t, Options{})

	res := c.ok("exec.run", proto.Message{"cmd": check})
	if got := strings.Fields(res.String("stdout")); !reflect.DeepEqual(got, want) || res.Int("code") != 0 {
		t.Fatalf("exec.run printed %q, stderr %q, code %d", got, res.String("stderr"), res.Int("code"))
	}
	expectNotRun(t, marker)

	res = c.ok("exec.run", proto.Message{"cmd": check, "env": map[string]any{"PSModulePath": plant}})
	if got := strings.Fields(res.String("stdout")); !reflect.DeepEqual(got, want) || res.Int("code") != 0 {
		t.Fatalf("exec.run with env PSModulePath printed %q, stderr %q, code %d", got, res.String("stderr"), res.Int("code"))
	}
	expectNotRun(t, marker)

	out, code := runShell(check)
	if got := strings.Fields(out); !reflect.DeepEqual(got, want) || code != 0 {
		t.Fatalf("the v1 exec printed %q, code %d", out, code)
	}
	expectNotRun(t, marker)
}
