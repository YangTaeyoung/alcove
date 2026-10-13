package server

import (
	"context"
	"errors"
	"time"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

const errNoUI = "UI Automation is only available on Windows guests"

// UI is the UI Automation helper behind the ui and win ops. The helper starts
// on the first call.
type UI interface {
	CallContext(ctx context.Context, op string, params map[string]any, timeout time.Duration) (map[string]any, error)
}

// HandleUIEvent re-emits a helper event to every open connection and releases
// the claim on a window that closed.
func (s *Server) HandleUIEvent(name string, fields map[string]any) {
	if name == "window.closed" {
		if w, ok := fields["window"].(map[string]any); ok {
			s.unclaimWindow(windowID(w))
		}
	}
	s.emit(name, fields)
}

// HandleUIStart forgets the windows taken by launches that have answered; it
// runs when a UI helper process has started.
func (s *Server) HandleUIStart() {
	s.launchMu.Lock()
	s.claimed.clearReleased()
	s.launchMu.Unlock()
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
		{"ui.at", "ui.at", normal},
		{"ui.ping", "ping", normal},
	}
	for _, o := range ops {
		o := o
		s.register(o.op, false, func(ctx context.Context, req proto.Message) (proto.Message, error) {
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
			out, err := s.opt.UI.CallContext(ctx, o.helperOp, params, o.timeout)
			if err != nil {
				return nil, err
			}
			return proto.Message(out), nil
		})
	}
}
