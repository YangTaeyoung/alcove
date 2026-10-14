package server

import (
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

// fakeDeployRoot creates its folder on Lock and reports locked as set.
type fakeDeployRoot struct {
	mu     sync.Mutex
	path   string
	locks  int
	fail   error
	locked bool
}

func (f *fakeDeployRoot) root() *DeployRoot {
	return &DeployRoot{Path: f.path, Lock: f.lock, Locked: f.isLocked}
}

func (f *fakeDeployRoot) lock() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.locks++
	if f.fail != nil {
		return f.fail
	}
	f.locked = true
	return os.Mkdir(f.path, 0o755)
}

func (f *fakeDeployRoot) isLocked() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.locked
}

func (f *fakeDeployRoot) lockCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.locks
}

func deployClient(t *testing.T) (*rpcClient, *fakeDeployRoot) {
	t.Helper()
	f := &fakeDeployRoot{path: filepath.Join(t.TempDir(), "alcove-apps")}
	c, _ := newRPCClient(t, Options{DeployRoot: f.root()})
	return c, f
}

func TestFsMkdirBelowAMissingDeployRootLocksTheRootFirst(t *testing.T) {
	c, f := deployClient(t)
	c.ok("fs.mkdir", proto.Message{"path": filepath.Join(f.path, "app", "bin")})
	if f.lockCount() != 1 {
		t.Fatalf("Lock ran %d times", f.lockCount())
	}
	if fi, err := os.Stat(filepath.Join(f.path, "app", "bin")); err != nil || !fi.IsDir() {
		t.Fatalf("the folder was not created: %v", err)
	}
	c.ok("fs.mkdir", proto.Message{"path": filepath.Join(f.path, "other")})
	if f.lockCount() != 1 {
		t.Fatalf("Lock ran %d times for an existing root", f.lockCount())
	}
}

func TestFsMkdirOfTheMissingDeployRootLocksIt(t *testing.T) {
	c, f := deployClient(t)
	c.ok("fs.mkdir", proto.Message{"path": f.path})
	if f.lockCount() != 1 {
		t.Fatalf("Lock ran %d times", f.lockCount())
	}
}

func TestFsWriteWithMkdirsIntoAMissingDeployRootLocksTheRootFirst(t *testing.T) {
	c, f := deployClient(t)
	path := filepath.Join(f.path, "app", "a.txt")
	c.ok("fs.write", proto.Message{"path": path, "data": b64([]byte("x")), "mkdirs": true})
	if f.lockCount() != 1 {
		t.Fatalf("Lock ran %d times", f.lockCount())
	}
	if got, _ := os.ReadFile(path); string(got) != "x" {
		t.Fatalf("file holds %q", got)
	}
}

func TestFsWriteWithoutMkdirsIntoAMissingDeployRootCreatesNothing(t *testing.T) {
	c, f := deployClient(t)
	res := c.call("fs.write", proto.Message{"path": filepath.Join(f.path, "a.txt"), "data": b64([]byte("x"))})
	if res["ok"] != false || f.lockCount() != 0 {
		t.Fatalf("answered %v after %d locks", res, f.lockCount())
	}
	if _, err := os.Lstat(f.path); !os.IsNotExist(err) {
		t.Fatalf("the root exists: %v", err)
	}
}

func TestFsRenameIntoAMissingDeployRootLocksTheRootFirst(t *testing.T) {
	c, f := deployClient(t)
	src := filepath.Join(t.TempDir(), "src")
	if err := os.Mkdir(src, 0o755); err != nil {
		t.Fatal(err)
	}
	res := c.call("fs.rename", proto.Message{"from": src, "to": f.path})
	if f.lockCount() != 1 {
		t.Fatalf("Lock ran %d times", f.lockCount())
	}
	if res["ok"] != false {
		t.Fatalf("a folder was renamed onto the locked root: %v", res)
	}
	if _, err := os.Stat(src); err != nil {
		t.Fatalf("the source moved: %v", err)
	}
}

func TestAFailedLockOfTheMissingDeployRootRefusesTheOperation(t *testing.T) {
	c, f := deployClient(t)
	f.fail = errors.New("access denied")
	res := c.call("fs.mkdir", proto.Message{"path": filepath.Join(f.path, "app")})
	want := f.path + " is missing and could not be created locked (access denied); remove what is in its way as an administrator and retry"
	if res["ok"] != false || res.String("error") != want {
		t.Fatalf("answered %v", res)
	}
	if _, err := os.Lstat(f.path); !os.IsNotExist(err) {
		t.Fatalf("the root exists: %v", err)
	}
}

func TestAPathOutsideTheDeployRootDoesNotLockIt(t *testing.T) {
	c, f := deployClient(t)
	c.ok("fs.mkdir", proto.Message{"path": f.path + "-sibling"})
	c.ok("fs.mkdir", proto.Message{"path": filepath.Join(t.TempDir(), "elsewhere")})
	if f.lockCount() != 0 {
		t.Fatalf("Lock ran %d times", f.lockCount())
	}
}

func TestFsStatReportsWhetherTheDeployRootIsLocked(t *testing.T) {
	c, f := deployClient(t)
	if res := c.ok("fs.stat", proto.Message{"path": f.path}); res.Has("locked") {
		t.Fatalf("a missing root has locked: %v", res)
	}
	if err := os.Mkdir(f.path, 0o755); err != nil {
		t.Fatal(err)
	}
	if res := c.ok("fs.stat", proto.Message{"path": f.path}); res["locked"] != false {
		t.Fatalf("a root another program created: %v", res)
	}
	f.mu.Lock()
	f.locked = true
	f.mu.Unlock()
	if res := c.ok("fs.stat", proto.Message{"path": f.path + string(filepath.Separator)}); res["locked"] != true {
		t.Fatalf("a locked root: %v", res)
	}
	if res := c.ok("fs.stat", proto.Message{"path": filepath.Dir(f.path)}); res.Has("locked") {
		t.Fatalf("another path has locked: %v", res)
	}
}

func TestFsStatWithoutADeployRootHasNoLocked(t *testing.T) {
	c, _ := newRPCClient(t, Options{})
	if res := c.ok("fs.stat", proto.Message{"path": t.TempDir()}); res.Has("locked") {
		t.Fatalf("stat %v", res)
	}
}
