package main

import (
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
