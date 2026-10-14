//go:build windows

package main

import (
	"os"
	"strings"
	"testing"
)

func TestTheProgramDataFolderIsNotTakenFromTheEnvironment(t *testing.T) {
	want, err := programDataFolder()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(strings.ToLower(want), `\programdata`) {
		t.Fatalf("ProgramData is %s", want)
	}
	t.Setenv("ProgramData", t.TempDir())
	got, err := programDataFolder()
	if err != nil || got != want {
		t.Fatalf("with ProgramData=%s the folder is %q, %v; expected %q", os.Getenv("ProgramData"), got, err, want)
	}
}
