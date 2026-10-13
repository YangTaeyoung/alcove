package server

import (
	"context"
	"fmt"
	"log"
	"net"
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
)

// Handler serves one request; the returned message carries result fields only.
// The context is cancelled when the connection the request arrived on closes.
type Handler func(ctx context.Context, req proto.Message) (proto.Message, error)

type opEntry struct {
	gated bool
	h     Handler
}

// conn is one open agent connection. A single writer goroutine drains out:
// replies and keepalives wait for room, events are dropped and counted when
// the queue is full, and the dropped count is announced once the writer catches
// up. A write that does not finish within connWriteTimeout closes the
// connection.
type conn struct {
	nc  net.Conn
	w   *proto.Writer
	lg  *log.Logger
	out chan proto.Message

	mu      sync.Mutex
	dropped int64

	done chan struct{} // closed when the writer has stopped
	stop chan struct{} // closed to ask the writer to stop
}

func newConn(nc net.Conn, lg *log.Logger) *conn {
	return &conn{nc: nc, w: proto.NewWriter(nc), lg: lg, out: make(chan proto.Message, eventQueueSize),
		done: make(chan struct{}), stop: make(chan struct{})}
}

// send queues a reply or other message; it waits for room or for the
// connection to close.
func (c *conn) send(m proto.Message) {
	select {
	case c.out <- m:
	case <-c.done:
	}
}

// enqueueEvent queues an event without blocking; a full queue drops and counts
// it instead.
func (c *conn) enqueueEvent(ev proto.Message) {
	select {
	case c.out <- ev:
	case <-c.done:
	default:
		c.mu.Lock()
		c.dropped++
		c.mu.Unlock()
	}
}

func (c *conn) takeDropped() int64 {
	c.mu.Lock()
	defer c.mu.Unlock()
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
		case m := <-c.out:
			if !c.write(m) {
				return
			}
			if n := c.takeDropped(); n > 0 {
				if !c.write(proto.Message{"t": "ev", "name": "events.dropped", "count": n}) {
					return
				}
			}
		}
	}
}

func (c *conn) write(m proto.Message) bool {
	_ = c.nc.SetWriteDeadline(time.Now().Add(connWriteTimeout))
	if err := c.w.Send(m); err != nil {
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

// dispatch runs one "req" message and sends the matching "res".
func (s *Server) dispatch(ctx context.Context, req proto.Message, send func(proto.Message)) {
	res := proto.Message{"t": "res", "id": req["id"]}
	fields, err := s.invoke(ctx, req)
	if err != nil {
		res["ok"] = false
		res["error"] = err.Error()
		send(res)
		return
	}
	for k, v := range fields {
		res[k] = v
	}
	res["t"] = "res"
	res["id"] = req["id"]
	res["ok"] = true
	send(res)
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
}
