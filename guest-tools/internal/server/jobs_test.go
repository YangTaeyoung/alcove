package server

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

func TestRingOffsets(t *testing.T) {
	r := newRing(4)
	r.Write([]byte("0123456789"))
	data, next, dropped := r.ReadFrom(0, 10)
	if string(data) != "6789" || next != 10 || !dropped {
		t.Fatalf("from 0: %q %d %v", data, next, dropped)
	}
	data, next, dropped = r.ReadFrom(8, 10)
	if string(data) != "89" || next != 10 || dropped {
		t.Fatalf("from 8: %q %d %v", data, next, dropped)
	}
	data, next, dropped = r.ReadFrom(10, 10)
	if len(data) != 0 || next != 10 || dropped {
		t.Fatalf("from 10: %q %d %v", data, next, dropped)
	}
	data, next, _ = r.ReadFrom(6, 2)
	if string(data) != "67" || next != 8 {
		t.Fatalf("capped: %q %d", data, next)
	}
}

// waitJobExited polls exec.read until the job has exited and returns the
// accumulated output.
func waitJobExited(t *testing.T, c *rpcClient, job string) (out, errOut string, last proto.Message) {
	t.Helper()
	outOff, errOff := 0, 0
	deadline := time.Now().Add(8 * time.Second)
	for {
		last = c.ok("exec.read", proto.Message{"job": job, "out_offset": outOff, "err_offset": errOff})
		out += last.String("out")
		errOut += last.String("err")
		outOff, errOff = last.Int("out_next"), last.Int("err_next")
		if last.String("state") == "exited" {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("job %s still running", job)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestJobTableForgetsOldestExited(t *testing.T) {
	old := maxJobs
	maxJobs = 3
	t.Cleanup(func() { maxJobs = old })
	c, _ := newRPCClient(t, Options{})
	var ids []string
	for i := 0; i < 5; i++ {
		job := c.ok("exec.start", proto.Message{"cmd": "exit 0"}).String("job")
		waitJobExited(t, c, job)
		ids = append(ids, job)
	}
	list, _ := c.ok("exec.list", nil)["jobs"].([]any)
	if len(list) != 3 {
		t.Fatalf("listed %d jobs", len(list))
	}
	for i, j := range list {
		if got := j.(map[string]any)["job"]; got != ids[i+2] {
			t.Fatalf("job %d is %v, want %s", i, got, ids[i+2])
		}
	}
	res := c.call("exec.read", proto.Message{"job": ids[0]})
	if res["ok"] != false || !strings.HasPrefix(res.String("error"), "no job ") {
		t.Fatalf("forgotten job: %v", res)
	}
}

func TestJobTableFullOfRunningJobs(t *testing.T) {
	old := maxJobs
	maxJobs = 2
	t.Cleanup(func() { maxJobs = old })
	c, _ := newRPCClient(t, Options{})
	var jobs []string
	for i := 0; i < 2; i++ {
		jobs = append(jobs, c.ok("exec.start", proto.Message{"cmd": "sleep 30"}).String("job"))
	}
	t.Cleanup(func() {
		for _, j := range jobs {
			c.call("exec.kill", proto.Message{"job": j})
		}
	})
	res := c.call("exec.start", proto.Message{"cmd": "exit 0"})
	if res["ok"] != false || !strings.Contains(res.String("error"), "exec.kill") {
		t.Fatalf("res %v", res)
	}
}

func TestJobExitedEventReachesOtherConnection(t *testing.T) {
	c, s := newRPCClient(t, Options{})
	c2, _ := startSecondConn(t, s)
	job := c.ok("exec.start", proto.Message{"cmd": "exit 0"}).String("job")
	ev := c2.event("job.exited")
	if ev.String("job") != job {
		t.Fatalf("event %v", ev)
	}
}

func TestRejectedStartDoesNotRunCommand(t *testing.T) {
	old := maxJobs
	maxJobs = 2
	t.Cleanup(func() { maxJobs = old })
	c, _ := newRPCClient(t, Options{})
	var jobs []string
	for i := 0; i < 2; i++ {
		jobs = append(jobs, c.ok("exec.start", proto.Message{"cmd": "sleep 30"}).String("job"))
	}
	t.Cleanup(func() {
		for _, j := range jobs {
			c.call("exec.kill", proto.Message{"job": j})
		}
	})
	marker := filepath.Join(t.TempDir(), "marker")
	res := c.call("exec.start", proto.Message{"cmd": "echo x > '" + marker + "'"})
	if res["ok"] != false {
		t.Fatalf("res %v", res)
	}
	time.Sleep(500 * time.Millisecond)
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("rejected start ran its command")
	}
}

func TestFailedStartLeavesNoJob(t *testing.T) {
	c, _ := newRPCClient(t, Options{})
	res := c.call("exec.start", proto.Message{"shell": "none", "argv": []any{"/nonexistent/binary"}})
	if res["ok"] != false {
		t.Fatalf("res %v", res)
	}
	if jobs, _ := c.ok("exec.list", nil)["jobs"].([]any); len(jobs) != 0 {
		t.Fatalf("leftover jobs %v", jobs)
	}
	if id := c.ok("exec.start", proto.Message{"cmd": "exit 0"}).String("job"); id != "j1" {
		t.Fatalf("next job id %q", id)
	}
}

func TestRingKeepsTheNewestBytesAcrossWrites(t *testing.T) {
	r := newRing(8)
	all := ""
	for i, piece := range []string{"ab", "cdefg", "h", "ijk", "", "lmnopqrst", "u", "vwxyz0123456789", "!"} {
		r.Write([]byte(piece))
		all += piece
		keep := all
		if len(keep) > 8 {
			keep = keep[len(keep)-8:]
		}
		got, cut := r.snapshot()
		if string(got) != keep || cut != (len(all) > 8) || r.written() != len(all) {
			t.Fatalf("after write %d: %q cut %v, expected %q", i, got, cut, keep)
		}
		for from := len(all) - len(keep); from <= len(all); from++ {
			data, next, dropped := r.ReadFrom(from, 3)
			want := all[from:min(from+3, len(all))]
			if string(data) != want || next != from+len(want) || dropped {
				t.Fatalf("after write %d, from %d: %q next %d dropped %v, expected %q", i, from, data, next, dropped, want)
			}
		}
	}
}

func TestAReservedJobIsNotVisibleBeforeItStarted(t *testing.T) {
	tab := newJobTable()
	j := &job{out: newRing(4), err: newRing(4), done: make(chan struct{})}
	if err := tab.reserve(j); err != nil {
		t.Fatal(err)
	}
	if _, err := tab.get(j.id); err == nil || err.Error() != "no job '"+j.id+"'; call exec.list" {
		t.Fatalf("get of a reserved job: %v", err)
	}
	if got := tab.list(); len(got) != 0 {
		t.Fatalf("list holds %d jobs", len(got))
	}
	j.markStarted(42)
	if got, err := tab.get(j.id); err != nil || got != j || got.processID() != 42 {
		t.Fatalf("get of a started job: %v %v", got, err)
	}
	if got := tab.list(); len(got) != 1 {
		t.Fatalf("list holds %d jobs", len(got))
	}
}
