// Package uia runs the UI Automation helper as a child process and talks to
// it over newline-delimited JSON on its stdin and stdout.
package uia

import (
	"bufio"
	"context"
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
	errExited    = "UI helper exited; retry"
	errClosed    = "the UI helper is shut down; restart alcove-agent"
	errCancelled = "the request was cancelled"
)

const (
	defaultStartTimeout = 120 * time.Second
	defaultQueueWait    = 60 * time.Second
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

	// guarded by Helper.mu
	pending    map[int64]chan result
	dead       bool
	isReady    bool
	err        error // why the child ended; set before done is closed
	startTimer *time.Timer

	ready      chan struct{} // closed when the helper announced "ready"
	done       chan struct{} // closed when the child was terminated
	readerDone chan struct{}
}

// waiter is a call that waits for its turn in the helper.
type waiter struct {
	op   string
	turn chan struct{} // closed when the call may proceed or the Helper was closed

	// guarded by Helper.mu
	granted bool
}

// Helper manages the helper child: it starts lazily, serves one child at a
// time and starts a new one after the child exits or times out. Calls go to
// the child one at a time, in the order they arrived.
type Helper struct {
	launch  Launcher
	onEvent func(name string, fields map[string]any)
	onStart func()

	startTimeout time.Duration
	queueWait    time.Duration
	logPath      string

	mu      sync.Mutex
	logger  *log.Logger
	cur     *child
	nextID  int64
	closed  bool
	busy    bool   // a call holds the helper
	busyOp  string // the op of that call
	waiters []*waiter
}

// New returns a Helper that starts the child through launch on the first Call.
// onEvent receives helper events with the "ev" key removed; it may be nil.
func New(launch Launcher, onEvent func(name string, fields map[string]any)) *Helper {
	return &Helper{launch: launch, onEvent: onEvent, logger: log.Default(),
		startTimeout: defaultStartTimeout, queueWait: defaultQueueWait}
}

// SetOnStart sets a function that runs each time a helper child has announced
// that it is ready.
func (h *Helper) SetOnStart(fn func()) {
	h.mu.Lock()
	h.onStart = fn
	h.mu.Unlock()
}

// SetLogPath sets the helper log file named in start-timeout errors.
func (h *Helper) SetLogPath(path string) {
	h.mu.Lock()
	h.logPath = path
	h.mu.Unlock()
}

// SetLogger sets the logger used for lines the helper writes that are not JSON.
func (h *Helper) SetLogger(l *log.Logger) {
	h.mu.Lock()
	h.logger = l
	h.mu.Unlock()
}

// acquire waits until no other call is inside the helper. A call that waits
// longer than the queue wait gives up and names the op that holds the helper;
// a call whose context is cancelled leaves the queue at once.
func (h *Helper) acquire(ctx context.Context, op string) error {
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return errors.New(errClosed)
	}
	if err := ctx.Err(); err != nil {
		h.mu.Unlock()
		return errors.New(errCancelled)
	}
	if !h.busy {
		h.busy, h.busyOp = true, op
		h.mu.Unlock()
		return nil
	}
	w := &waiter{op: op, turn: make(chan struct{})}
	h.waiters = append(h.waiters, w)
	wait := h.queueWait
	h.mu.Unlock()

	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case <-w.turn:
	case <-timer.C:
	case <-ctx.Done():
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if w.granted {
		// A grant that arrives together with cancellation hands the turn back.
		if ctx.Err() != nil {
			h.releaseLocked()
			return errors.New(errCancelled)
		}
		return nil
	}
	if h.closed {
		return errors.New(errClosed)
	}
	for i, other := range h.waiters {
		if other == w {
			h.waiters = append(h.waiters[:i], h.waiters[i+1:]...)
			break
		}
	}
	if ctx.Err() != nil {
		return errors.New(errCancelled)
	}
	return fmt.Errorf("the UI helper is busy with '%s'; retry", h.busyOp)
}

// release hands the helper to the call that has waited longest, if any.
func (h *Helper) release() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.releaseLocked()
}

func (h *Helper) releaseLocked() {
	if len(h.waiters) == 0 {
		h.busy, h.busyOp = false, ""
		return
	}
	w := h.waiters[0]
	h.waiters = h.waiters[1:]
	w.granted = true
	h.busyOp = w.op
	close(w.turn)
}

// Call sends one request with no cancellation; see CallContext.
func (h *Helper) Call(op string, params map[string]any, timeout time.Duration) (map[string]any, error) {
	return h.CallContext(context.Background(), op, params, timeout)
}

// CallContext sends one request and waits for its reply; it starts or restarts
// the child as needed. The returned fields exclude "id" and "ok". The call
// waits for its turn first; timeout counts from the moment the request is
// handed to the child, and a child that does not answer within it is killed. A
// call whose context is cancelled before its request reaches the child, while
// it waits for its turn or for a starting child to become ready, gives up its
// turn without sending the request; a request already handed to the child runs
// to its end.
func (h *Helper) CallContext(ctx context.Context, op string, params map[string]any, timeout time.Duration) (map[string]any, error) {
	if err := h.acquire(ctx, op); err != nil {
		return nil, err
	}
	defer h.release()

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
		c = &child{stdin: stdin, stdout: stdout, kill: kill, pending: map[int64]chan result{},
			ready: make(chan struct{}), done: make(chan struct{}), readerDone: make(chan struct{})}
		h.cur = c
		logPath := h.logPath
		if logPath == "" {
			logPath = "helper.log in the agent's uia folder"
		}
		startErr := fmt.Errorf("UI helper did not start within %s s; see %s",
			strconv.FormatFloat(h.startTimeout.Seconds(), 'f', -1, 64), logPath)
		c.startTimer = time.AfterFunc(h.startTimeout, func() { h.terminate(c, startErr) })
		go h.readLoop(c)
	}
	h.mu.Unlock()

	select {
	case <-c.ready:
	case <-c.done:
		return nil, c.err
	case <-ctx.Done():
		return nil, errors.New(errCancelled)
	}

	if err := ctx.Err(); err != nil {
		return nil, errors.New(errCancelled)
	}

	h.mu.Lock()
	if c.dead {
		h.mu.Unlock()
		return nil, c.err
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

	timer := time.NewTimer(timeout)
	defer timer.Stop()
	go func() {
		if _, err := c.stdin.Write(line); err != nil {
			h.terminate(c, errors.New(errExited))
		}
	}()
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

// Close kills the child and fails pending and waiting calls; later calls fail.
func (h *Helper) Close() {
	h.mu.Lock()
	h.closed = true
	c := h.cur
	for _, w := range h.waiters {
		close(w.turn)
	}
	h.waiters = nil
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
	c.err = err
	close(c.done)
	if c.startTimer != nil {
		c.startTimer.Stop()
	}
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
	if name == "ready" {
		h.mu.Lock()
		first := !c.isReady
		if first {
			c.isReady = true
			c.startTimer.Stop()
			close(c.ready)
		}
		onStart := h.onStart
		h.mu.Unlock()
		if first && onStart != nil {
			onStart()
		}
		return
	}
	if name == "fatal" {
		msg, _ := m["error"].(string)
		h.mu.Lock()
		started := c.isReady
		h.mu.Unlock()
		if started {
			h.terminate(c, errors.New(msg))
		} else {
			h.terminate(c, fmt.Errorf("UI helper failed to start through PowerShell: %s", msg))
		}
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
