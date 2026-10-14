//go:build windows

package sysfolder

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"reflect"
	"strings"
	"testing"
)

// TestMain prints MachineVars as JSON and exits when ALCOVE_PRINT_VARS is 1;
// otherwise it runs the tests.
func TestMain(m *testing.M) {
	if os.Getenv("ALCOVE_PRINT_VARS") == "1" {
		vars, err := MachineVars()
		if err != nil {
			fmt.Println("error:", err)
			os.Exit(1)
		}
		out, _ := json.Marshal(vars)
		fmt.Println(string(out))
		os.Exit(0)
	}
	os.Exit(m.Run())
}

// varsOfAProcessWith returns MachineVars of a new process of this test binary
// whose environment adds env.
func varsOfAProcessWith(t *testing.T, env ...string) map[string]string {
	t.Helper()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(self)
	cmd.Env = append(append(os.Environ(), "ALCOVE_PRINT_VARS=1"), env...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	var vars map[string]string
	if err := json.Unmarshal(out, &vars); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	return vars
}

func TestTheMachineVariablesAreNotTakenFromTheEnvironment(t *testing.T) {
	want := varsOfAProcessWith(t)
	if !strings.HasSuffix(strings.ToLower(want["systemroot"]), `\windows`) || want["programfiles"] == "" {
		t.Fatalf("the machine variables are %v", want)
	}
	dir := t.TempDir()
	got := varsOfAProcessWith(t, "SystemRoot="+dir, "windir="+dir, "SystemDrive="+dir, "ProgramFiles="+dir, "ProgramFiles(x86)="+dir)
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("with the variables set to %s: %v; expected %v", dir, got, want)
	}
}
