package server

import (
	"context"
	"fmt"
	"log"
	"net"
	"slices"
	"sync"
	"time"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

const errExecDisabled = "exec disabled; start alcove-agent with --allow-exec"

const (
	// eventQueueSize bounds the events waiting to be written to one connection.
	eventQueueSize = 256
	// connWriteTimeout closes a connection whose write does not finish in time.
	connWriteTimeout = 30 * time.Second
	// maxReplyLine bounds the encoded line of a reply, 64 KiB below the 8 MiB
	// line the host reads.
	maxReplyLine = 8<<20 - 64<<10
	// maxInFlight bounds the requests that run at once for one connection.
	maxInFlight = 256
)

const errNoID = "the request has no id; give every req an id to match its answer"

// Handler serves one request; the returned message carries result fields only.
// The context is cancelled when the connection the request arrived on closes.
type Handler func(ctx context.Context, req proto.Message) (proto.Message, error)

type opEntry struct {
	gated bool
	h     Handler
}

// conn is one open agent connection. A single writer goroutine drains out:
// replies and keepalives wait for room; an event that finds no room is dropped
// and counted. The count goes out as an events.dropped event at the place of
// the dropped events: in the queue just before the next event that is queued,
// or written by the writer when the queue is empty. A write that does not
// finish within connWriteTimeout closes the connection.
type conn struct {
	nc  net.Conn
	w   *proto.Writer
	lg  *log.Logger
	out chan outgoing

	// mu orders the events put into out and guards dropped.
	mu      sync.Mutex
	dropped int64

	done chan struct{} // closed when the writer has stopped
	stop chan struct{} // closed to ask the writer to stop

	// caps is the capability list sent last on the connection; capsFollowed
	// is set once the host has sent its first message after the handshake.
	capsMu       sync.Mutex
	caps         []string
	capsFollowed bool
}

// setCaps records caps as the list sent on the connection.
func (c *conn) setCaps(caps []string) {
	c.capsMu.Lock()
	c.caps = caps
	c.capsMu.Unlock()
}

// followCaps records that the host has sent its first message after the
// handshake.
func (c *conn) followCaps() {
	c.capsMu.Lock()
	c.capsFollowed = true
	c.capsMu.Unlock()
}

// capsFollowedYet reports whether followCaps has run.
func (c *conn) capsFollowedYet() bool {
	c.capsMu.Lock()
	defer c.capsMu.Unlock()
	return c.capsFollowed
}

// replaceCaps records caps and reports whether it differs from the list
// sent last.
func (c *conn) replaceCaps(caps []string) bool {
	c.capsMu.Lock()
	defer c.capsMu.Unlock()
	if slices.Equal(c.caps, caps) {
		return false
	}
	c.caps = caps
	return true
}

// outgoing is a queued message; line, when set, is its encoded line, which is
// written as it is.
type outgoing struct {
	m    proto.Message
	line []byte
}

func newConn(nc net.Conn, lg *log.Logger) *conn {
	return &conn{nc: nc, w: proto.NewWriter(nc), lg: lg, out: make(chan outgoing, eventQueueSize),
		done: make(chan struct{}), stop: make(chan struct{})}
}

// send queues a reply or other message; it waits for room or for the
// connection to close.
func (c *conn) send(m proto.Message) { c.sendReply(m, nil) }

// sendReply queues m like send; a non-nil line is m's encoded line and is
// written instead of encoding m again.
func (c *conn) sendReply(m proto.Message, line []byte) {
	select {
	case c.out <- outgoing{m: m, line: line}:
	case <-c.done:
	}
}

// enqueueEvent queues an event without blocking. Without room it drops and
// counts the event. After a drop the event needs room for two messages: the
// events.dropped message with the count is queued first, then the event.
func (c *conn) enqueueEvent(ev proto.Message) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.dropped > 0 {
		if cap(c.out)-len(c.out) < 2 {
			c.dropped++
			return
		}
		select {
		case c.out <- outgoing{m: droppedEvent(c.dropped)}:
			c.dropped = 0
		case <-c.done:
			return
		default:
			c.dropped++
			return
		}
	}
	select {
	case c.out <- outgoing{m: ev}:
	case <-c.done:
	default:
		c.dropped++
	}
}

func droppedEvent(n int64) proto.Message {
	return proto.Message{"t": "ev", "name": "events.dropped", "count": n}
}

// takeDroppedWhenIdle returns the dropped count and resets it when events
// were dropped and the queue is empty; otherwise it returns 0.
func (c *conn) takeDroppedWhenIdle() int64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.dropped == 0 || len(c.out) > 0 {
		return 0
	}
	n := c.dropped
	c.dropped = 0
	return n
}

// writeLoop writes queued messages until it is asked to stop or a write fails.
func (c *conn) writeLoop() {
	defer close(c.done)
	for {
		select {
		case <-c.stop:
			return
		case o := <-c.out:
			if !c.write(o) {
				return
			}
			if n := c.takeDroppedWhenIdle(); n > 0 {
				if !c.write(outgoing{m: droppedEvent(n)}) {
					return
				}
			}
		}
	}
}

func (c *conn) write(o outgoing) bool {
	_ = c.nc.SetWriteDeadline(time.Now().Add(connWriteTimeout))
	var err error
	if o.line != nil {
		_, err = c.nc.Write(o.line)
	} else {
		err = c.w.Send(o.m)
	}
	if err != nil {
		c.lg.Printf("send: %v", err)
		_ = c.nc.Close()
		return false
	}
	return true
}

func (c *conn) stopWriter() { close(c.stop) }

// register adds an op; gated ops need Options.AllowExec.
func (s *Server) register(op string, gated bool, h Handler) {
	s.connMu.Lock()
	defer s.connMu.Unlock()
	s.ops[op] = opEntry{gated: gated, h: h}
}

// emit sends an event to every open connection.
func (s *Server) emit(name string, fields proto.Message) {
	ev := proto.Message{}
	for k, v := range fields {
		ev[k] = v
	}
	ev["t"] = "ev"
	ev["name"] = name

	s.connMu.Lock()
	conns := make([]*conn, 0, len(s.conns))
	for c := range s.conns {
		conns = append(conns, c)
	}
	s.connMu.Unlock()
	for _, c := range conns {
		c.enqueueEvent(ev)
	}
}

func (s *Server) addConn(c *conn) {
	s.connMu.Lock()
	s.conns[c] = struct{}{}
	s.connMu.Unlock()
}

func (s *Server) removeConn(c *conn) {
	s.connMu.Lock()
	delete(s.conns, c)
	s.connMu.Unlock()
}

// dispatch runs one "req" message and sends the matching "res" with its
// encoded line, or with a nil line when it was not encoded. A request without
// an id is not run. A reply whose line would reach maxReplyLine is replaced by
// an error that asks for less.
func (s *Server) dispatch(ctx context.Context, req proto.Message, send func(m proto.Message, line []byte)) {
	if req["id"] == nil {
		send(proto.Message{"t": "res", "id": nil, "ok": false, "error": errNoID}, nil)
		return
	}
	fail := func(text string) proto.Message {
		return proto.Message{"t": "res", "id": req["id"], "ok": false, "error": text}
	}
	fields, err := s.invoke(ctx, req)
	if err != nil {
		send(fail(err.Error()), nil)
		return
	}
	res := proto.Message{}
	for k, v := range fields {
		res[k] = v
	}
	res["t"] = "res"
	res["id"] = req["id"]
	res["ok"] = true
	line, err := proto.Encode(res)
	switch {
	case err != nil:
		s.opt.Logger.Printf("op %s: the answer could not be encoded: %v", req.String("op"), err)
		send(fail(fmt.Sprintf("the answer to '%s' could not be encoded; see the agent log", req.String("op"))), nil)
	case len(line) >= maxReplyLine:
		send(fail(fmt.Sprintf("the answer to '%s' is larger than the 8 MiB line the host reads; ask for less (a lower max, depth or limit, a narrower path or a name filter)", req.String("op"))), nil)
	default:
		send(res, line)
	}
}

// tooManyRequests is the error of a request that arrives while maxInFlight
// requests of its connection run.
func tooManyRequests() string {
	return fmt.Sprintf("%d requests are running on this connection; wait for an answer before sending another", maxInFlight)
}

func (s *Server) invoke(ctx context.Context, req proto.Message) (out proto.Message, err error) {
	op := req.String("op")
	s.connMu.Lock()
	e, ok := s.ops[op]
	s.connMu.Unlock()
	if !ok {
		return nil, fmt.Errorf("unknown op '%s'; update alcove-agent", op)
	}
	if e.gated && !s.opt.AllowExec {
		return nil, fmt.Errorf("%s", errExecDisabled)
	}
	defer func() {
		if r := recover(); r != nil {
			s.opt.Logger.Printf("op %s panicked: %v", op, r)
			out, err = nil, fmt.Errorf("op '%s' failed internally; see the agent log", op)
		}
	}()
	return e.h(ctx, req)
}

func (s *Server) registerBuiltins() {
	s.register("ping", false, func(context.Context, proto.Message) (proto.Message, error) {
		return proto.Message{"pong": true}, nil
	})
	s.registerShell()
	s.registerFiles()
	s.registerUI()
	s.registerLaunch()
	if s.opt.Session != nil {
		s.register("session.info", true, s.sessionInfo)
	}
}

// sessionInfo describes the desktop session; without one the reply has no
// fields.
func (s *Server) sessionInfo(context.Context, proto.Message) (proto.Message, error) {
	sess, ok := s.session()
	if !ok {
		return proto.Message{}, nil
	}
	return proto.Message{"session": sess.ID, "user": sess.User, "uid": sess.UID, "home": sess.Home,
		"type": sess.Type, "locked": sess.Locked}, nil
}
