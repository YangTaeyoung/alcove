package server

import (
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

type uiCall struct {
	op      string
	params  map[string]any
	timeout time.Duration
}

// fakeUI records the calls of requests in calls and the calls the server
// makes on its own, which carry no parameters, in starts.
type fakeUI struct {
	mu     sync.Mutex
	calls  []uiCall
	starts []uiCall
	err    error
}

func (f *fakeUI) Call(op string, params map[string]any, timeout time.Duration) (map[string]any, error) {
	f.mu.Lock()
	if params == nil {
		f.starts = append(f.starts, uiCall{op, params, timeout})
	} else {
		f.calls = append(f.calls, uiCall{op, params, timeout})
	}
	f.mu.Unlock()
	if f.err != nil {
		return nil, f.err
	}
	return map[string]any{"echo": op}, nil
}

func TestUIOpsPassThrough(t *testing.T) {
	ui := &fakeUI{}
	_, r, w, _ := startServerS(t, Options{Clipboard: &fakeClipboard{}, HomeDir: t.TempDir(), UI: ui})
	hello := expect(t, r, "hello")
	if !capSet(hello)["ui"] {
		t.Fatalf("caps %v", hello["caps"])
	}

	cases := []struct {
		op, helperOp string
		timeout      time.Duration
	}{
		{"win.list", "win.list", 20 * time.Second},
		{"win.action", "win.action", 20 * time.Second},
		{"ui.tree", "ui.tree", 30 * time.Second},
		{"ui.find", "ui.find", 20 * time.Second},
		{"ui.text", "ui.text", 30 * time.Second},
		{"ui.rect", "ui.rect", 20 * time.Second},
		{"ui.act", "ui.act", 20 * time.Second},
		{"ui.focused", "ui.focused", 20 * time.Second},
		{"ui.ping", "ping", 20 * time.Second},
	}
	for i, c := range cases {
		w.Send(proto.Message{"t": "req", "id": i + 1, "op": c.op, "role": "button", "limit": 5})
		res := expect(t, r, "res")
		if res["ok"] != true || res["echo"] != c.helperOp {
			t.Fatalf("%s: res %v", c.op, res)
		}
	}
	ui.mu.Lock()
	defer ui.mu.Unlock()
	if len(ui.calls) != len(cases) {
		t.Fatalf("calls %d", len(ui.calls))
	}
	for i, c := range cases {
		got := ui.calls[i]
		if got.op != c.helperOp || got.timeout != c.timeout {
			t.Errorf("%s: call %s timeout %v", c.op, got.op, got.timeout)
		}
		if len(got.params) != 2 || got.params["role"] != "button" || got.params["limit"] != float64(5) {
			t.Errorf("%s: params %v", c.op, got.params)
		}
	}
}

func TestConnectionStartsTheUIHelper(t *testing.T) {
	ui := &fakeUI{}
	_, r, _, _ := startServerS(t, Options{Clipboard: &fakeClipboard{}, HomeDir: t.TempDir(), UI: ui})
	expect(t, r, "hello")
	deadline := time.Now().Add(10 * time.Second)
	for {
		ui.mu.Lock()
		starts := append([]uiCall(nil), ui.starts...)
		ui.mu.Unlock()
		if len(starts) == 1 {
			if starts[0].op != "ping" || starts[0].timeout != 20*time.Second {
				t.Fatalf("start call %+v", starts[0])
			}
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("start calls %d", len(starts))
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestUIHelperErrorPassesThrough(t *testing.T) {
	ui := &fakeUI{err: errors.New("element e3 no longer exists; call ui.tree again")}
	_, r, w, _ := startServerS(t, Options{Clipboard: &fakeClipboard{}, HomeDir: t.TempDir(), UI: ui})
	expect(t, r, "hello")
	w.Send(proto.Message{"t": "req", "id": 1, "op": "ui.act"})
	res := expect(t, r, "res")
	if res["ok"] != false || res.String("error") != "element e3 no longer exists; call ui.tree again" {
		t.Fatalf("res %v", res)
	}
}

func TestNoUICapWithoutHelper(t *testing.T) {
	_, r, w, _ := startServerS(t, Options{Clipboard: &fakeClipboard{}, HomeDir: t.TempDir()})
	hello := expect(t, r, "hello")
	if capSet(hello)["ui"] {
		t.Fatalf("caps %v", hello["caps"])
	}
	for i, op := range []string{"ui.tree", "win.list", "ui.ping"} {
		w.Send(proto.Message{"t": "req", "id": i + 1, "op": op})
		res := expect(t, r, "res")
		if res["ok"] != false || res.String("error") != "UI Automation is only available on Windows guests" {
			t.Fatalf("%s: res %v", op, res)
		}
	}
}

func TestUIEventsAreEmitted(t *testing.T) {
	s, r, _, _ := startServerS(t, Options{Clipboard: &fakeClipboard{}, HomeDir: t.TempDir(), UI: &fakeUI{}})
	expect(t, r, "hello")
	deadline := time.Now().Add(10 * time.Second)
	for {
		s.connMu.Lock()
		n := len(s.conns)
		s.connMu.Unlock()
		if n > 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("connection not registered")
		}
		time.Sleep(5 * time.Millisecond)
	}
	s.HandleUIEvent("window.opened", map[string]any{"window": map[string]any{"id": "0x10"}})
	ev := expect(t, r, "ev")
	if ev.String("name") != "window.opened" {
		t.Fatalf("ev %v", ev)
	}
	if w, _ := ev["window"].(map[string]any); w["id"] != "0x10" {
		t.Fatalf("ev %v", ev)
	}
}
