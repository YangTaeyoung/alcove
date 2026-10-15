//go:build !windows

package main

import (
	"errors"
	"os"
	"os/user"
	"path/filepath"
	"strings"
	"testing"
)

func TestReplaceFileSwapsTheContentAndLeavesNoTemporaryFile(t *testing.T) {
	dir := t.TempDir()
	dst := filepath.Join(dir, "alcove-agent")
	if err := os.WriteFile(dst, []byte("old"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := replaceFile(dst, []byte("new"), 0o755); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(dst)
	fi, _ := os.Stat(dst)
	if err != nil || string(got) != "new" || fi.Mode().Perm() != 0o755 {
		t.Fatalf("content %q mode %v err %v", got, fi.Mode(), err)
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 1 {
		t.Fatalf("folder holds %d entries", len(entries))
	}
}

func TestReplaceFileInAMissingFolderFails(t *testing.T) {
	if err := replaceFile(filepath.Join(t.TempDir(), "missing", "alcove-agent"), []byte("new"), 0o755); err == nil {
		t.Fatal("replaceFile succeeded without a folder")
	}
}

// fakeInstall returns an install into a temporary folder whose systemctl
// records its calls and fails the call named fail.
func fakeInstall(t *testing.T, fail string) (systemdInstall, *[]string) {
	t.Helper()
	dir := t.TempDir()
	exe := filepath.Join(dir, "new-agent")
	if err := os.WriteFile(exe, []byte("new binary"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, sub := range []string{"bin", "units"} {
		if err := os.MkdirAll(filepath.Join(dir, sub), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	calls := &[]string{}
	in := systemdInstall{exe: exe, bin: filepath.Join(dir, "bin", "alcove-agent"), unit: filepath.Join(dir, "units", "alcove-agent.service"),
		systemctl: func(args ...string) ([]byte, error) {
			call := strings.Join(args, " ")
			*calls = append(*calls, call)
			if call == fail {
				return []byte("Job for alcove-agent.service failed.\n"), errors.New("exit status 1")
			}
			return nil, nil
		}}
	return in, calls
}

func TestInstallReplacesTheBinaryAndRestartsTheService(t *testing.T) {
	in, calls := fakeInstall(t, "")
	if err := os.WriteFile(in.bin, []byte("old binary"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := in.run(7645, true, []string{"--allow-peer", "192.168.64.0/24"}); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(in.bin); string(got) != "new binary" {
		t.Fatalf("installed binary %q", got)
	}
	unit, _ := os.ReadFile(in.unit)
	if !strings.Contains(string(unit), "ExecStart="+in.bin+" --port 7645 --allow-exec --allow-peer 192.168.64.0/24\n") {
		t.Fatalf("unit %s", unit)
	}
	want := []string{"daemon-reload", "enable alcove-agent", "restart alcove-agent"}
	if strings.Join(*calls, "|") != strings.Join(want, "|") {
		t.Fatalf("systemctl calls %q", *calls)
	}
}

func TestInstallStopsWhenTheBinaryCannotBeReplaced(t *testing.T) {
	in, calls := fakeInstall(t, "")
	in.bin = filepath.Join(filepath.Dir(in.bin), "missing", "alcove-agent")
	err := in.run(7645, false, nil)
	if err == nil || !strings.HasPrefix(err.Error(), "cannot replace "+in.bin+" (") || !strings.HasSuffix(err.Error(), "); run alcove-agent --install as root") {
		t.Fatalf("err %v", err)
	}
	if len(*calls) != 0 {
		t.Fatalf("systemctl ran after a failed copy: %q", *calls)
	}
}

func TestInstallReportsTheSystemctlStepThatFailed(t *testing.T) {
	in, _ := fakeInstall(t, "restart alcove-agent")
	err := in.run(7645, false, nil)
	want := "systemctl restart alcove-agent failed (exit status 1: Job for alcove-agent.service failed.); check journalctl -u alcove-agent, then run alcove-agent --install again"
	if err == nil || err.Error() != want {
		t.Fatalf("err %v", err)
	}
}

func TestInstallFromTheInstalledBinaryKeepsIt(t *testing.T) {
	in, calls := fakeInstall(t, "")
	in.bin = in.exe
	if err := in.run(7645, false, nil); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(in.bin); string(got) != "new binary" || len(*calls) != 3 {
		t.Fatalf("binary %q calls %q", got, *calls)
	}
}

func TestHomeIsSetWhenTheServiceHasNone(t *testing.T) {
	u, err := user.Current()
	if err != nil || u.HomeDir == "" {
		t.Skip("this user has no home directory in the user database")
	}
	t.Setenv("HOME", "")
	ensureHome()
	if got := os.Getenv("HOME"); got != u.HomeDir {
		t.Fatalf("HOME %q, want %q", got, u.HomeDir)
	}
}

func TestLogFolderIsCreatedForTheOwnerOnly(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "alcove")
	got, err := ownLogFolder(dir)
	if err != nil || got != dir {
		t.Fatalf("ownLogFolder = %q, %v", got, err)
	}
	if fi, err := os.Lstat(dir); err != nil || !fi.IsDir() || fi.Mode().Perm() != 0o700 {
		t.Fatalf("folder %v %v", fi.Mode(), err)
	}
}

func TestLogFolderOfOtherAccessIsNarrowed(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "alcove")
	if err := os.Mkdir(dir, 0o777); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o777); err != nil {
		t.Fatal(err)
	}
	if _, err := ownLogFolder(dir); err != nil {
		t.Fatal(err)
	}
	if fi, _ := os.Lstat(dir); fi.Mode().Perm() != 0o700 {
		t.Fatalf("mode %v", fi.Mode())
	}
}

func TestLogFolderThatIsALinkIsRefused(t *testing.T) {
	base := t.TempDir()
	real := filepath.Join(base, "real")
	if err := os.Mkdir(real, 0o700); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(base, "alcove")
	if err := os.Symlink(real, dir); err != nil {
		t.Fatal(err)
	}
	_, err := ownLogFolder(dir)
	want := dir + " is not a plain folder owned by this user; remove it and run alcove-agent --install again"
	if err == nil || err.Error() != want {
		t.Fatalf("err %v", err)
	}
}

func TestDataFolderLiesOutsideTheTemporaryFolder(t *testing.T) {
	if strings.HasPrefix(installLogFolder, os.TempDir()) || installLogFolder != "/var/log/alcove" {
		t.Fatalf("install log folder %q", installLogFolder)
	}
}
