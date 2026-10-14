//go:build windows

package server

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/sysfolder"
)

func TestABareNameResolvesInTheSystemFolderWhateverTheEnvironmentSays(t *testing.T) {
	windows, err := sysfolder.WindowsFolder()
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(windows, "System32", "notepad.exe")
	fake := t.TempDir()
	if err := os.MkdirAll(filepath.Join(fake, "System32"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(fake, "System32", "notepad.exe"), []byte("MZ"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"SystemRoot", "windir", "SystemDrive"} {
		t.Setenv(name, fake)
	}
	got, err := resolveProgram("notepad")
	if err != nil || !strings.EqualFold(got, want) {
		t.Fatalf("notepad resolves to %q, %v; expected %q", got, err, want)
	}
}

func TestAnAppPathsProgramResolvesToAnExistingFile(t *testing.T) {
	got, err := resolveProgram("msedge")
	if err != nil {
		t.Skipf("msedge has no App Paths entry here: %v", err)
	}
	if _, err := os.Stat(got); err != nil {
		t.Fatalf("msedge resolves to %q, which is missing: %v", got, err)
	}
}
