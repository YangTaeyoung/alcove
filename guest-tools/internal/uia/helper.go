// Package uia runs the UI Automation helper as a child process and talks to
// it over newline-delimited JSON on its stdin and stdout.
package uia

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"strconv"
	"sync"
	"time"
)

const maxLineBytes = 8 << 20

const (
	errExited = "UI helper exited; retry"
	errClosed = "UI helper is closed"
)

// Launcher starts the helper child and returns its pipes.
type Launcher func() (stdin io.WriteCloser, stdout io.ReadCloser, kill func(), err error)

type result struct {
	fields map[string]any
	err    error
}

// child is one running helper process.
type child struct {
	stdin  io.WriteCloser
	stdout io.ReadCloser
	kill   func()

	wmu sync.Mutex // serializes request lines on stdin

	// guarded by Helper.mu
	pending map[int64]chan result
	dead    bool

	readerDone chan struct{}
}

// Helper manages the helper child: it starts lazily, serves one child at a
// time and starts a new one after the child exits or times out.
type Helper struct {
	launch  Launcher
	onEvent func(name string, fields map[string]any)

	mu     sync.Mutex
	logger *log.Logger
	cur    *child
	nextID int64
	closed bool
}

// New returns a Helper that starts the child through launch on the first Call.
// onEvent receives helper events with the "ev" key removed; it may be nil.
func New(launch Launcher, onEvent func(name string, fields map[string]any)) *Helper {
	return &Helper{launch: launch, onEvent: onEvent, logger: log.Default()}
}

// SetLogger sets the logger used for lines the helper writes that are not JSON.
func (h *Helper) SetLogger(l *log.Logger) {
	h.mu.Lock()
	h.logger = l
	h.mu.Unlock()
}

// Call sends one request and waits for its reply; it starts or restarts the
// child as needed. The returned fields exclude "id" and "ok".
func (h *Helper) Call(op string, params map[string]any, timeout time.Duration) (map[string]any, error) {
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return nil, errors.New(errClosed)
	}
	c := h.cur
	if c == nil {
		stdin, stdout, kill, err := h.launch()
		if err != nil {
			h.mu.Unlock()
			return nil, fmt.Errorf("could not start the UI helper through PowerShell: %v", err)
		}
		c = &child{stdin: stdin, stdout: stdout, kill: kill, pending: map[int64]chan result{}, readerDone: make(chan struct{})}
		h.cur = c
		go h.readLoop(c)
	}
	h.nextID++
	id := h.nextID
	ch := make(chan result, 1)
	c.pending[id] = ch
	h.mu.Unlock()

	req := make(map[string]any, len(params)+2)
	for k, v := range params {
		req[k] = v
	}
	req["id"] = id
	req["op"] = op
	line, err := json.Marshal(req)
	if err != nil {
		h.drop(c, id)
		return nil, fmt.Errorf("UI request '%s' cannot be encoded: %v", op, err)
	}
	line = append(line, '\n')
	c.wmu.Lock()
	_, err = c.stdin.Write(line)
	c.wmu.Unlock()
	if err != nil {
		h.terminate(c, errors.New(errExited))
		r := <-ch
		return r.fields, r.err
	}

	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case r := <-ch:
		return r.fields, r.err
	case <-timer.C:
	}
	select {
	case r := <-ch:
		return r.fields, r.err
	default:
	}
	h.drop(c, id)
	h.terminate(c, errors.New(errExited))
	return nil, fmt.Errorf("UI helper did not answer '%s' within %s s; it was restarted", op,
		strconv.FormatFloat(timeout.Seconds(), 'f', -1, 64))
}

// Close kills the child and fails pending calls; later calls fail.
func (h *Helper) Close() {
	h.mu.Lock()
	h.closed = true
	c := h.cur
	h.mu.Unlock()
	if c != nil {
		h.terminate(c, errors.New(errClosed))
		<-c.readerDone
	}
}

func (h *Helper) drop(c *child, id int64) {
	h.mu.Lock()
	delete(c.pending, id)
	h.mu.Unlock()
}

// terminate fails every pending call of c with err and stops the process. It
// does nothing when c was already terminated.
func (h *Helper) terminate(c *child, err error) {
	h.mu.Lock()
	if c.dead {
		h.mu.Unlock()
		return
	}
	c.dead = true
	if h.cur == c {
		h.cur = nil
	}
	pending := c.pending
	c.pending = nil
	h.mu.Unlock()

	for _, ch := range pending {
		ch <- result{err: err}
	}
	if c.kill != nil {
		c.kill()
	}
	c.stdin.Close()
	c.stdout.Close()
}

func (h *Helper) readLoop(c *child) {
	defer close(c.readerDone)
	sc := bufio.NewScanner(c.stdout)
	sc.Buffer(make([]byte, 64*1024), maxLineBytes+1)
	for sc.Scan() {
		h.handleLine(c, sc.Bytes())
	}
	h.terminate(c, errors.New(errExited))
}

func (h *Helper) handleLine(c *child, line []byte) {
	line = trimBOM(line)
	if len(line) == 0 {
		return
	}
	var m map[string]any
	if err := json.Unmarshal(line, &m); err != nil {
		h.mu.Lock()
		lg := h.logger
		h.mu.Unlock()
		lg.Printf("UI helper wrote a line that is not JSON: %.200s", line)
		return
	}
	if rawID, ok := m["id"]; ok {
		idf, ok := rawID.(float64)
		if !ok {
			return
		}
		id := int64(idf)
		h.mu.Lock()
		ch := c.pending[id]
		delete(c.pending, id)
		h.mu.Unlock()
		if ch == nil {
			return
		}
		if okVal, _ := m["ok"].(bool); !okVal {
			msg, _ := m["error"].(string)
			if msg == "" {
				msg = "UI helper reported an error without a message"
			}
			ch <- result{err: errors.New(msg)}
			return
		}
		delete(m, "id")
		delete(m, "ok")
		ch <- result{fields: m}
		return
	}
	name, ok := m["ev"].(string)
	if !ok {
		return
	}
	delete(m, "ev")
	if name == "fatal" {
		msg, _ := m["error"].(string)
		h.terminate(c, fmt.Errorf("UI helper failed to start through PowerShell: %s", msg))
		return
	}
	if h.onEvent != nil {
		h.onEvent(name, m)
	}
}

func trimBOM(b []byte) []byte {
	if len(b) >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF {
		return b[3:]
	}
	return b
}
