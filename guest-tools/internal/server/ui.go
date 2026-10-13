package server

import (
	"errors"
	"time"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

const errNoUI = "UI Automation is only available on Windows guests"

// UI is the UI Automation helper behind the ui and win ops.
type UI interface {
	Call(op string, params map[string]any, timeout time.Duration) (map[string]any, error)
}

// HandleUIEvent re-emits a helper event to every open connection.
func (s *Server) HandleUIEvent(name string, fields map[string]any) {
	s.emit(name, fields)
}

func (s *Server) registerUI() {
	const normal, long = 20 * time.Second, 30 * time.Second
	ops := []struct {
		op, helperOp string
		timeout      time.Duration
	}{
		{"win.list", "win.list", normal},
		{"win.action", "win.action", normal},
		{"ui.tree", "ui.tree", long},
		{"ui.find", "ui.find", normal},
		{"ui.text", "ui.text", long},
		{"ui.rect", "ui.rect", normal},
		{"ui.act", "ui.act", normal},
		{"ui.focused", "ui.focused", normal},
		{"ui.ping", "ping", normal},
	}
	for _, o := range ops {
		o := o
		s.register(o.op, false, func(req proto.Message) (proto.Message, error) {
			if s.opt.UI == nil {
				return nil, errors.New(errNoUI)
			}
			params := make(map[string]any, len(req))
			for k, v := range req {
				switch k {
				case "t", "id", "op":
				default:
					params[k] = v
				}
			}
			out, err := s.opt.UI.Call(o.helperOp, params, o.timeout)
			if err != nil {
				return nil, err
			}
			return proto.Message(out), nil
		})
	}
}
