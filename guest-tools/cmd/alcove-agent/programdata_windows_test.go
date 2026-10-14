//go:build windows

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// TestMain prints programDataFolder's answer and exits when
// ALCOVE_PRINT_PROGRAMDATA is 1; otherwise it runs the tests.
func TestMain(m *testing.M) {
	if os.Getenv("ALCOVE_PRINT_PROGRAMDATA") == "1" {
		dir, err := programDataFolder()
		if err != nil {
			fmt.Println("error:", err)
			os.Exit(1)
		}
		fmt.Println(dir)
		os.Exit(0)
	}
	os.Exit(m.Run())
}

// programDataOfAProcessWith returns what programDataFolder answers in a new
// process of this test binary whose environment adds env.
func programDataOfAProcessWith(t *testing.T, env ...string) string {
	t.Helper()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(self)
	cmd.Env = append(append(os.Environ(), "ALCOVE_PRINT_PROGRAMDATA=1"), env...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	return strings.TrimSpace(string(out))
}

func TestTheProgramDataFolderIsNotTakenFromTheEnvironment(t *testing.T) {
	want := programDataOfAProcessWith(t)
	if !strings.HasSuffix(strings.ToLower(want), `\programdata`) {
		t.Fatalf("ProgramData is %s", want)
	}
	if got := programDataOfAProcessWith(t, "ProgramData="+t.TempDir()); got != want {
		t.Fatalf("with ProgramData set the folder is %q; expected %q", got, want)
	}
}

func TestTheProgramDataFolderIsNotOnTheSystemDriveOfTheEnvironment(t *testing.T) {
	want := programDataOfAProcessWith(t)
	drive := t.TempDir()
	if err := os.Mkdir(filepath.Join(drive, "ProgramData"), 0o755); err != nil {
		t.Fatal(err)
	}
	if got := programDataOfAProcessWith(t, "SystemDrive="+drive); got != want {
		t.Fatalf("with SystemDrive=%s the folder is %q; expected %q", drive, got, want)
	}
	if got := programDataOfAProcessWith(t, "SystemDrive=Q:"); got != want {
		t.Fatalf("with SystemDrive=Q: the folder is %q; expected %q", got, want)
	}
}
