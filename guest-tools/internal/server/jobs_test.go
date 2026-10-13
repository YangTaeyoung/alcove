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

func TestJobLifecycle(t *testing.T) {
	c, _ := newRPCClient(t, Options{})
	start := c.ok("exec.start", proto.Message{"cmd": "for i in 1 2 3; do echo $i; sleep 0.1; done"})
	job := start.String("job")
	if job == "" || start.Int("pid") <= 0 {
		t.Fatalf("start %v", start)
	}
	out, _, last := waitJobExited(t, c, job)
	if out != "1\n2\n3\n" || last.Int("code") != 0 {
		t.Fatalf("out %q last %v", out, last)
	}
	list := c.ok("exec.list", nil)
	jobs, _ := list["jobs"].([]any)
	found := false
	for _, j := range jobs {
		m, _ := j.(map[string]any)
		if m["job"] == job {
			found = true
			if m["state"] != "exited" || m["cmd"] == "" || m["started"] == "" {
				t.Fatalf("listed job %v", m)
			}
		}
	}
	if !found {
		t.Fatalf("job %s missing from %v", job, list)
	}
	ev := c.event("job.exited")
	if ev.String("job") != job || ev.Int("code") != 0 {
		t.Fatalf("event %v", ev)
	}
}

func TestJobStdinAndKill(t *testing.T) {
	c, _ := newRPCClient(t, Options{})
	job := c.ok("exec.start", proto.Message{"cmd": "cat"}).String("job")
	t.Cleanup(func() { c.call("exec.kill", proto.Message{"job": job}) })
	c.ok("exec.write", proto.Message{"job": job, "data": "hi\n"})

	deadline := time.Now().Add(8 * time.Second)
	got := ""
	for got != "hi\n" {
		got += c.ok("exec.read", proto.Message{"job": job, "out_offset": len(got)}).String("out")
		if time.Now().After(deadline) {
			t.Fatalf("output %q", got)
		}
		time.Sleep(20 * time.Millisecond)
	}
	if st := c.ok("exec.kill", proto.Message{"job": job}).String("state"); st != "exited" {
		t.Fatalf("state after kill %q", st)
	}
	res := c.call("exec.kill", proto.Message{"job": "nope"})
	if res["ok"] != false || res.String("error") != "no job 'nope'; call exec.list" {
		t.Fatalf("unknown job: %v", res)
	}
}

func TestJobStdinEOFEndsJob(t *testing.T) {
	c, _ := newRPCClient(t, Options{})
	job := c.ok("exec.start", proto.Message{"cmd": "cat"}).String("job")
	t.Cleanup(func() { c.call("exec.kill", proto.Message{"job": job}) })
	c.ok("exec.write", proto.Message{"job": job, "data": "last\n", "eof": true})
	out, _, last := waitJobExited(t, c, job)
	if out != "last\n" || last.Int("code") != 0 {
		t.Fatalf("out %q last %v", out, last)
	}
	res := c.call("exec.write", proto.Message{"job": job, "data": "more"})
	if res["ok"] != false {
		t.Fatalf("write after exit: %v", res)
	}
}

func TestJobBufferDropsOldest(t *testing.T) {
	old := jobBufferBytes
	jobBufferBytes = 1024
	t.Cleanup(func() { jobBufferBytes = old })
	c, _ := newRPCClient(t, Options{})
	job := c.ok("exec.start", proto.Message{"cmd": "head -c 5000 /dev/zero | tr '\\0' 'a'"}).String("job")
	_, _, _ = waitJobExited(t, c, job)
	res := c.ok("exec.read", proto.Message{"job": job})
	if !res.Bool("dropped") || res.Int("out_next") != 5000 || len(res.String("out")) != 1024 {
		t.Fatalf("dropped=%v out_next=%d len=%d", res.Bool("dropped"), res.Int("out_next"), len(res.String("out")))
	}
}

func TestJobReadCapsMax(t *testing.T) {
	c, _ := newRPCClient(t, Options{})
	job := c.ok("exec.start", proto.Message{"cmd": "printf abcdefghij"}).String("job")
	waitJobExited(t, c, job)
	res := c.ok("exec.read", proto.Message{"job": job, "max": 4})
	if res.String("out") != "abcd" || res.Int("out_next") != 4 {
		t.Fatalf("res %v", res)
	}
}

func TestJobTableForgetsOldestExited(t *testing.T) {
	old := maxJobs
	maxJobs = 3
	t.Cleanup(func() { maxJobs = old })
	c, _ := newRPCClient(t, Options{})
	var ids []string
	for i := 0; i < 5; i++ {
		job := c.ok("exec.start", proto.Message{"cmd": "true"}).String("job")
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
	res := c.call("exec.start", proto.Message{"cmd": "true"})
	if res["ok"] != false || !strings.Contains(res.String("error"), "exec.kill") {
		t.Fatalf("res %v", res)
	}
}

func TestJobExitedEventReachesOtherConnection(t *testing.T) {
	c, s := newRPCClient(t, Options{})
	c2, _ := startSecondConn(t, s)
	job := c.ok("exec.start", proto.Message{"cmd": "true"}).String("job")
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
	res := c.call("exec.start", proto.Message{"cmd": "touch " + marker})
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
	if id := c.ok("exec.start", proto.Message{"cmd": "true"}).String("job"); id != "j1" {
		t.Fatalf("next job id %q", id)
	}
}

func TestJobWriteTimesOutWhenInputIsNotRead(t *testing.T) {
	old := stdinWriteTimeout
	stdinWriteTimeout = 200 * time.Millisecond
	t.Cleanup(func() { stdinWriteTimeout = old })
	c, _ := newRPCClient(t, Options{})
	job := c.ok("exec.start", proto.Message{"cmd": "sleep 30"}).String("job")
	t.Cleanup(func() { c.call("exec.kill", proto.Message{"job": job}) })
	started := time.Now()
	res := c.call("exec.write", proto.Message{"job": job, "data": strings.Repeat("x", 512<<10)})
	if time.Since(started) > 2*time.Second {
		t.Fatalf("write took %v", time.Since(started))
	}
	if res["ok"] != false || res.String("error") != "job '"+job+"' is not reading its input; exec.kill it or retry later" {
		t.Fatalf("res %v", res)
	}
	if st := c.ok("exec.kill", proto.Message{"job": job}).String("state"); st != "exited" {
		t.Fatalf("state %q", st)
	}
}
