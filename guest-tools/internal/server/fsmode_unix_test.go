//go:build !windows

package server

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"testing"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

func TestWriteWithExecutableMakesTheFileExecutable(t *testing.T) {
	home := t.TempDir()
	c, _ := newRPCClient(t, Options{HomeDir: home})
	data := base64.StdEncoding.EncodeToString([]byte("#!/bin/sh\necho ran\n"))
	run := filepath.Join(home, "app", "run.sh")
	c.ok("fs.write", proto.Message{"path": run, "data": data, "truncate": true, "mkdirs": true, "executable": true})
	fi, err := os.Stat(run)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm()&0o100 == 0 {
		t.Fatalf("mode %v lacks the owner's execute bit", fi.Mode())
	}
	if fi.Mode().Perm()&0o044 != 0 && fi.Mode().Perm()&0o011 != (fi.Mode().Perm()&0o044)>>2 {
		t.Fatalf("mode %v: execute bits do not follow the read bits", fi.Mode())
	}
	out := c.ok("exec.run", proto.Message{"argv": []string{run}}).String("stdout")
	if out != "ran\n" {
		t.Fatalf("the written script printed %q", out)
	}
}

func TestWriteWithoutExecutableKeepsTheFilePlain(t *testing.T) {
	home := t.TempDir()
	c, _ := newRPCClient(t, Options{HomeDir: home})
	path := filepath.Join(home, "data.txt")
	c.ok("fs.write", proto.Message{"path": path, "data": base64.StdEncoding.EncodeToString([]byte("x")), "truncate": true})
	if fi, err := os.Stat(path); err != nil || fi.Mode().Perm()&0o111 != 0 {
		t.Fatalf("mode %v, %v", fi.Mode(), err)
	}
}

func TestExecutableModeAddsExecuteWhereReadIsSet(t *testing.T) {
	cases := map[os.FileMode]os.FileMode{0o644: 0o755, 0o600: 0o700, 0o640: 0o750, 0o755: 0o755}
	for in, want := range cases {
		if got := executableMode(in); got != want {
			t.Errorf("executableMode(%o) = %o, want %o", in, got, want)
		}
	}
}
