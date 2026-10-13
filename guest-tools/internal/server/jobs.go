package server

import (
	"errors"
	"fmt"
	"io"
	"sync"
	"time"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

var (
	jobBufferBytes = 1 << 20
	maxJobs        = 64
)

const maxReadBytes = 262144

// ring keeps the newest max bytes and counts every byte written.
type ring struct {
	mu    sync.Mutex
	buf   []byte
	max   int
	total int
}

func newRing(max int) *ring { return &ring{max: max} }

func (r *ring) Write(p []byte) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.total += len(p)
	if len(p) >= r.max {
		r.buf = append(r.buf[:0], p[len(p)-r.max:]...)
		return len(p), nil
	}
	r.buf = append(r.buf, p...)
	if len(r.buf) > r.max {
		n := copy(r.buf, r.buf[len(r.buf)-r.max:])
		r.buf = r.buf[:n]
	}
	return len(p), nil
}

// ReadFrom returns up to max bytes starting at the absolute offset. When the
// offset lies before the retained window, reading starts at the oldest
// retained byte and dropped is true.
func (r *ring) ReadFrom(offset, max int) (data []byte, next int, dropped bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	start := r.total - len(r.buf)
	if offset < start {
		offset, dropped = start, true
	}
	if offset > r.total {
		offset = r.total
	}
	end := r.total
	if max >= 0 && offset+max < end {
		end = offset + max
	}
	data = append([]byte(nil), r.buf[offset-start:end-start]...)
	return data, end, dropped
}

// snapshot returns the retained bytes and whether older bytes were dropped.
func (r *ring) snapshot() ([]byte, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]byte(nil), r.buf...), r.total > len(r.buf)
}

func (r *ring) written() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.total
}

type job struct {
	id      string
	pid     int
	cmdline string
	started time.Time
	out     *ring
	err     *ring
	done    chan struct{}

	mu       sync.Mutex
	stdin    io.WriteCloser
	stdinOff bool
	exited   bool
	code     int
}

func (j *job) state() (exited bool, code int) {
	j.mu.Lock()
	defer j.mu.Unlock()
	return j.exited, j.code
}

func (j *job) closeStdin() {
	j.mu.Lock()
	defer j.mu.Unlock()
	if !j.stdinOff {
		j.stdinOff = true
		_ = j.stdin.Close()
	}
}

type jobTable struct {
	mu    sync.Mutex
	jobs  map[string]*job
	order []string
	next  int
}

func newJobTable() *jobTable { return &jobTable{jobs: map[string]*job{}} }

func (t *jobTable) get(id string) (*job, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	j := t.jobs[id]
	if j == nil {
		return nil, fmt.Errorf("no job '%s'; call exec.list", id)
	}
	return j, nil
}

// add registers a job, forgetting the oldest exited jobs to stay within maxJobs.
func (t *jobTable) add(j *job) error {
	t.mu.Lock()
	defer t.mu.Unlock()
	for len(t.order) >= maxJobs {
		evicted := false
		for i, id := range t.order {
			if exited, _ := t.jobs[id].state(); exited {
				delete(t.jobs, id)
				t.order = append(t.order[:i], t.order[i+1:]...)
				evicted = true
				break
			}
		}
		if !evicted {
			return fmt.Errorf("%d jobs are running; stop one with exec.kill", len(t.order))
		}
	}
	t.jobs[j.id] = j
	t.order = append(t.order, j.id)
	return nil
}

func (t *jobTable) nextID() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.next++
	return fmt.Sprintf("j%d", t.next)
}

func (t *jobTable) list() []*job {
	t.mu.Lock()
	defer t.mu.Unlock()
	out := make([]*job, 0, len(t.order))
	for _, id := range t.order {
		out = append(out, t.jobs[id])
	}
	return out
}

func (s *Server) registerJobs() {
	s.register("exec.start", true, s.execStart)
	s.register("exec.read", true, s.execRead)
	s.register("exec.write", true, s.execWrite)
	s.register("exec.kill", true, s.execKill)
	s.register("exec.list", true, s.execList)
}

func (s *Server) execStart(req proto.Message) (proto.Message, error) {
	c, err := s.newCommand(req)
	if err != nil {
		return nil, err
	}
	j := &job{
		id:      s.jobs.nextID(),
		cmdline: commandLine(req),
		started: time.Now(),
		out:     newRing(jobBufferBytes),
		err:     newRing(jobBufferBytes),
		done:    make(chan struct{}),
	}
	c.Stdout, c.Stderr = j.out, j.err
	if j.stdin, err = c.StdinPipe(); err != nil {
		return nil, startError(err)
	}
	if err := c.Start(); err != nil {
		return nil, startError(err)
	}
	j.pid = c.Process.Pid
	if err := s.jobs.add(j); err != nil {
		_ = killTree(j.pid)
		go c.Wait()
		return nil, err
	}
	go func() {
		_ = c.Wait()
		code := -1
		if c.ProcessState != nil {
			code = c.ProcessState.ExitCode()
		}
		j.mu.Lock()
		j.exited, j.code = true, code
		j.mu.Unlock()
		close(j.done)
		s.emit("job.exited", proto.Message{"job": j.id, "code": code})
	}()
	return proto.Message{"job": j.id, "pid": j.pid}, nil
}

func (s *Server) execRead(req proto.Message) (proto.Message, error) {
	j, err := s.jobs.get(req.String("job"))
	if err != nil {
		return nil, err
	}
	limit := req.Int("max")
	if limit <= 0 || limit > maxReadBytes {
		limit = maxReadBytes
	}
	exited, code := j.state()
	out, outNext, outDropped := j.out.ReadFrom(req.Int("out_offset"), limit)
	errOut, errNext, errDropped := j.err.ReadFrom(req.Int("err_offset"), limit)
	finished := exited && outNext == j.out.written() && errNext == j.err.written()
	if !finished {
		outNext -= len(out) - completeUTF8Len(out)
		out = out[:completeUTF8Len(out)]
		errNext -= len(errOut) - completeUTF8Len(errOut)
		errOut = errOut[:completeUTF8Len(errOut)]
	}
	res := proto.Message{
		"state":    "running",
		"pid":      j.pid,
		"out":      text(out),
		"err":      text(errOut),
		"out_next": outNext,
		"err_next": errNext,
		"dropped":  outDropped || errDropped,
	}
	if exited {
		res["state"] = "exited"
		res["code"] = code
	}
	return res, nil
}

func (s *Server) execWrite(req proto.Message) (proto.Message, error) {
	j, err := s.jobs.get(req.String("job"))
	if err != nil {
		return nil, err
	}
	if exited, _ := j.state(); exited {
		return nil, fmt.Errorf("job '%s' has exited; start a new job with exec.start", j.id)
	}
	if data := req.String("data"); data != "" {
		j.mu.Lock()
		closed := j.stdinOff
		j.mu.Unlock()
		if closed {
			return nil, fmt.Errorf("stdin of job '%s' is closed; start a new job with exec.start", j.id)
		}
		if _, err := io.WriteString(j.stdin, data); err != nil {
			return nil, fmt.Errorf("cannot write to job '%s': %v; call exec.list to check its state", j.id, err)
		}
	}
	if req.Bool("eof") {
		j.closeStdin()
	}
	return proto.Message{}, nil
}

func (s *Server) execKill(req proto.Message) (proto.Message, error) {
	j, err := s.jobs.get(req.String("job"))
	if err != nil {
		return nil, err
	}
	if exited, _ := j.state(); !exited {
		_ = killTree(j.pid)
		select {
		case <-j.done:
		case <-time.After(5 * time.Second):
			return nil, errors.New("job did not exit after the kill; call exec.list to check its state")
		}
	}
	exited, _ := j.state()
	state := "running"
	if exited {
		state = "exited"
	}
	return proto.Message{"state": state}, nil
}

func (s *Server) execList(proto.Message) (proto.Message, error) {
	jobs := []any{}
	for _, j := range s.jobs.list() {
		exited, code := j.state()
		m := map[string]any{
			"job":     j.id,
			"pid":     j.pid,
			"state":   "running",
			"cmd":     j.cmdline,
			"started": j.started.Format(time.RFC3339),
		}
		if exited {
			m["state"] = "exited"
			m["code"] = code
		}
		jobs = append(jobs, m)
	}
	return proto.Message{"jobs": jobs}, nil
}
