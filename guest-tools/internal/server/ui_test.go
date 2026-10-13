package server

import (
	"context"
	"errors"
	"io"
	"log"
	"net"
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

// fakeUI records the calls it receives.
type fakeUI struct {
	mu    sync.Mutex
	calls []uiCall
	err   error
}

func (f *fakeUI) CallContext(_ context.Context, op string, params map[string]any, timeout time.Duration) (map[string]any, error) {
	f.mu.Lock()
	f.calls = append(f.calls, uiCall{op, params, timeout})
	f.mu.Unlock()
	if f.err != nil {
		return nil, f.err
	}
	return map[string]any{"echo": op}, nil
}

func (f *fakeUI) callCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.calls)
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

func TestHelperStartsOnTheFirstUIOpNotOnConnect(t *testing.T) {
	ui := &fakeUI{}
	_, r, w, _ := startServerS(t, Options{Clipboard: &fakeClipboard{}, HomeDir: t.TempDir(), UI: ui})
	expect(t, r, "hello")

	w.Send(proto.Message{"t": "req", "id": 1, "op": "ping"})
	res := expect(t, r, "res")
	if res["ok"] != true || res["pong"] != true {
		t.Fatalf("ping res %v", res)
	}
	if n := ui.callCount(); n != 0 {
		t.Fatalf("the helper was called %d times before any ui op", n)
	}

	w.Send(proto.Message{"t": "req", "id": 2, "op": "ui.ping"})
	res = expect(t, r, "res")
	if res["ok"] != true || res["echo"] != "ping" {
		t.Fatalf("ui.ping res %v", res)
	}
	if n := ui.callCount(); n != 1 {
		t.Fatalf("the helper was called %d times for one ui.ping", n)
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

func TestConnDropsEventsWhenThePeerDoesNotReadAndAnnouncesTheCount(t *testing.T) {
	cli, srv := net.Pipe()
	defer cli.Close()
	c := newConn(srv, log.New(io.Discard, "", 0))
	go c.writeLoop()
	defer c.stopWriter()

	total := eventQueueSize + 50
	for i := 0; i < total; i++ {
		c.enqueueEvent(proto.Message{"t": "ev", "name": "window.title", "i": i})
	}

	_ = cli.SetReadDeadline(time.Now().Add(10 * time.Second))
	r := proto.NewReader(cli)
	read, dropped := 0, 0
	for read+dropped < total {
		m, err := r.Next()
		if err != nil {
			t.Fatalf("read %d events, %d dropped, no more: %v", read, dropped, err)
		}
		if m.String("name") == "events.dropped" {
			dropped += m.Int("count")
		} else {
			read++
		}
	}
	if dropped <= 0 {
		t.Fatalf("events.dropped count is %d", dropped)
	}
	if read >= total {
		t.Fatalf("the peer received %d of %d events with none dropped", read, total)
	}
	if read+dropped != total {
		t.Fatalf("%d read plus %d dropped is not %d", read, dropped, total)
	}
}

func TestEmitDoesNotBlockOnAStuckConnection(t *testing.T) {
	s := New(Options{Clipboard: &fakeClipboard{}, HomeDir: t.TempDir(), UI: &fakeUI{}})

	stuckCli, stuckSrv := net.Pipe()
	defer stuckCli.Close()
	stuck := newConn(stuckSrv, log.New(io.Discard, "", 0))
	go stuck.writeLoop()
	defer stuck.stopWriter()
	s.addConn(stuck)

	okCli, okSrv := net.Pipe()
	defer okCli.Close()
	ok := newConn(okSrv, log.New(io.Discard, "", 0))
	go ok.writeLoop()
	defer ok.stopWriter()
	s.addConn(ok)

	done := make(chan struct{})
	go func() {
		for i := 0; i < eventQueueSize+100; i++ {
			s.emit("window.title", proto.Message{"window": map[string]any{"id": "0x1", "i": i}})
		}
		close(done)
	}()

	_ = okCli.SetReadDeadline(time.Now().Add(10 * time.Second))
	r := proto.NewReader(okCli)
	for i := 0; i < 10; i++ {
		if _, err := r.Next(); err != nil {
			t.Fatalf("the reading connection stopped answering: %v", err)
		}
	}
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("emit blocked on the stuck connection")
	}
}
