package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestOpenLogDoesNotOpenAFileInAFolderThatIsNotLocked(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "Alcove")
	path := filepath.Join(dir, "agent.log")
	f, err := openLog(path, dir, errors.New("access denied"))
	if err == nil {
		f.Close()
		t.Fatal("the log was opened")
	}
	if !strings.Contains(err.Error(), path) || !strings.Contains(err.Error(), "access denied") {
		t.Fatalf("err %v", err)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatalf("the folder was created: %v", err)
	}
}

func TestOpenLogCreatesAndAppends(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "Alcove")
	path := filepath.Join(dir, "agent.log")
	for _, line := range []string{"one\n", "two\n"} {
		f, err := openLog(path, dir, nil)
		if err != nil {
			t.Fatal(err)
		}
		f.WriteString(line)
		f.Close()
	}
	if got, _ := os.ReadFile(path); string(got) != "one\ntwo\n" {
		t.Fatalf("log %q", got)
	}
}

func TestOpenLogOpensAFileOutsideTheFolderThatIsNotLocked(t *testing.T) {
	base := t.TempDir()
	path := filepath.Join(base, "elsewhere", "agent.log")
	f, err := openLog(path, filepath.Join(base, "Alcove"), errors.New("access denied"))
	if err != nil {
		t.Fatal(err)
	}
	f.Close()
}

func TestInsideDir(t *testing.T) {
	sep := string(filepath.Separator)
	dir := sep + "data" + sep + "Alcove"
	cases := []struct {
		path string
		want bool
	}{
		{dir + sep + "agent.log", true},
		{dir + sep + "uia" + sep + "helper.log", true},
		{sep + "data" + sep + "ALCOVE" + sep + "agent.log", true},
		{dir, true},
		{dir + sep + ".." + sep + "agent.log", false},
		{sep + "data" + sep + "Alcove2" + sep + "agent.log", false},
		{sep + "data" + sep + "agent.log", false},
		{sep + "other" + sep + "agent.log", false},
	}
	for _, c := range cases {
		if got := insideDir(dir, c.path); got != c.want {
			t.Errorf("insideDir(%q, %q) = %v, expected %v", dir, c.path, got, c.want)
		}
	}
	if insideDir("", dir+sep+"agent.log") {
		t.Error("a path is inside an empty folder name")
	}
}

func TestDataFoldersLieUnderProgramData(t *testing.T) {
	base := filepath.Join(t.TempDir(), "ProgramData")
	alcoveDir, uiaDir, err := dataFolders(base)
	if err != nil {
		t.Fatal(err)
	}
	if alcoveDir != filepath.Join(base, "Alcove") || uiaDir != filepath.Join(base, "Alcove", "uia") {
		t.Fatalf("folders %q and %q", alcoveDir, uiaDir)
	}
	if _, err := os.Stat(alcoveDir); !os.IsNotExist(err) {
		t.Fatalf("the folder was created: %v", err)
	}
}

func TestDataFoldersNameNoFolderWithoutProgramData(t *testing.T) {
	alcoveDir, uiaDir, err := dataFolders("")
	want := "the UI helper cannot start because the ProgramData folder could not be located; restart alcove-agent through its scheduled task"
	if err == nil || err.Error() != want {
		t.Fatalf("err %v", err)
	}
	if alcoveDir != "" || uiaDir != "" {
		t.Fatalf("folders %q and %q", alcoveDir, uiaDir)
	}
}

func TestInstallLogIsNotWrittenThroughALink(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symbolic links need a privilege on Windows")
	}
	dir := t.TempDir()
	target := filepath.Join(t.TempDir(), "target")
	if err := os.WriteFile(target, []byte("kept\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(dir, "install.log")); err != nil {
		t.Fatal(err)
	}
	writeInstallLog(dir, "installed")
	if got, _ := os.ReadFile(target); string(got) != "kept\n" {
		t.Fatalf("the link target holds %q", got)
	}
}

func TestInstallLogIsAppended(t *testing.T) {
	dir := t.TempDir()
	writeInstallLog(dir, "one")
	writeInstallLog(dir, "two")
	got, _ := os.ReadFile(filepath.Join(dir, "install.log"))
	if lines := strings.Split(strings.TrimSpace(string(got)), "\n"); len(lines) != 2 || !strings.HasSuffix(lines[0], " one") || !strings.HasSuffix(lines[1], " two") {
		t.Fatalf("install.log %q", got)
	}
}

func TestPeerFlagTakesRangesAndSingleAddresses(t *testing.T) {
	var peers peerFlag
	for _, v := range []string{"192.168.64.0/24", "10.0.2.15", "fd00::/8", "::1"} {
		if err := peers.Set(v); err != nil {
			t.Fatalf("Set(%q): %v", v, err)
		}
	}
	want := "192.168.64.0/24,10.0.2.15/32,fd00::/8,::1/128"
	if peers.String() != want {
		t.Fatalf("peers %q, expected %q", peers.String(), want)
	}
	if got := peers.args(); strings.Join(got, " ") != "--allow-peer 192.168.64.0/24 --allow-peer 10.0.2.15/32 --allow-peer fd00::/8 --allow-peer ::1/128" {
		t.Fatalf("args %q", got)
	}
}

func TestPeerFlagRefusesAnythingElse(t *testing.T) {
	for _, v := range []string{"", "localhost", "10.0.2.2/33", "10.0.2.2:7645", "192.168.64.1/24"} {
		var peers peerFlag
		err := peers.Set(v)
		if err == nil || !strings.Contains(err.Error(), "an address such as 10.0.2.2 or a range such as 192.168.64.0/24") {
			t.Fatalf("Set(%q): %v", v, err)
		}
	}
}

func TestNoHelperAnswersEveryCallWithItsError(t *testing.T) {
	_, _, err := dataFolders("")
	ui := noHelper{err}
	for _, op := range []string{"ping", "win.list", "ui.tree", "ui.at"} {
		out, got := ui.CallContext(context.Background(), op, map[string]any{"window": "foreground"}, 0)
		if out != nil || got == nil || got.Error() != errNoProgramData {
			t.Fatalf("%s: %v %v", op, out, got)
		}
	}
}
