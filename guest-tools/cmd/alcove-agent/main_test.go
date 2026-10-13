package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
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
	want := "the UI helper cannot start because %ProgramData% is not set; start alcove-agent through its scheduled task"
	if err == nil || err.Error() != want {
		t.Fatalf("err %v", err)
	}
	if alcoveDir != "" || uiaDir != "" {
		t.Fatalf("folders %q and %q", alcoveDir, uiaDir)
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
