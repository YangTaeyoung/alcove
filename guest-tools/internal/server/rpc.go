package server

import (
	"fmt"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

const errExecDisabled = "exec disabled; start alcove-agent with --allow-exec"

// Handler serves one request; the returned message carries result fields only.
type Handler func(req proto.Message) (proto.Message, error)

type opEntry struct {
	gated bool
	h     Handler
}

// conn is one open agent connection; send is safe for concurrent use.
type conn struct {
	send func(proto.Message)
}

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
		c.send(ev)
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
func (s *Server) dispatch(req proto.Message, send func(proto.Message)) {
	res := proto.Message{"t": "res", "id": req["id"]}
	fields, err := s.invoke(req)
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

func (s *Server) invoke(req proto.Message) (out proto.Message, err error) {
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
	return e.h(req)
}

func (s *Server) registerBuiltins() {
	s.register("ping", false, func(proto.Message) (proto.Message, error) {
		return proto.Message{"pong": true}, nil
	})
	s.registerShell()
	s.registerFiles()
	s.registerUI()
}
