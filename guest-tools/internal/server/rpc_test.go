package server

import (
	"context"
	"errors"
	"net"
	"testing"
	"time"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

func startServerS(t *testing.T, opt Options) (*Server, *proto.Reader, *proto.Writer, net.Conn) {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	s := New(opt)
	go s.Serve(l)
	c, err := net.Dial("tcp", l.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	c.SetDeadline(time.Now().Add(10 * time.Second))
	t.Cleanup(func() { c.Close(); l.Close() })
	return s, proto.NewReader(c), proto.NewWriter(c), c
}

func capSet(m proto.Message) map[string]bool {
	set := map[string]bool{}
	caps, _ := m["caps"].([]any)
	for _, c := range caps {
		if s, ok := c.(string); ok {
			set[s] = true
		}
	}
	return set
}

func TestHelloAnnouncesRPC(t *testing.T) {
	_, r, _, _ := startServerS(t, Options{Clipboard: &fakeClipboard{}, HomeDir: t.TempDir()})
	hello := expect(t, r, "hello")
	if hello.Int("v") != 1 || hello.Int("proto") != 2 {
		t.Fatalf("hello %v", hello)
	}
	caps := capSet(hello)
	if !caps["rpc"] || caps["jobs"] || caps["proc"] || caps["fs"] {
		t.Fatalf("caps without exec %v", hello["caps"])
	}

	_, r, _, _ = startServerS(t, Options{Clipboard: &fakeClipboard{}, HomeDir: t.TempDir(), AllowExec: true})
	caps = capSet(expect(t, r, "hello"))
	for _, c := range []string{"rpc", "jobs", "proc", "fs"} {
		if !caps[c] {
			t.Fatalf("caps with exec lack %s: %v", c, caps)
		}
	}
}

func TestReqResRoundTrip(t *testing.T) {
	_, r, w, _ := startServerS(t, Options{Clipboard: &fakeClipboard{}, HomeDir: t.TempDir()})
	expect(t, r, "hello")
	w.Send(proto.Message{"t": "req", "id": 7, "op": "ping"})
	res := expect(t, r, "res")
	if res.Int("id") != 7 || res["ok"] != true || res["pong"] != true {
		t.Fatalf("res %v", res)
	}
}

func TestUnknownOp(t *testing.T) {
	_, r, w, _ := startServerS(t, Options{Clipboard: &fakeClipboard{}, HomeDir: t.TempDir()})
	expect(t, r, "hello")
	w.Send(proto.Message{"t": "req", "id": 1, "op": "nope"})
	res := expect(t, r, "res")
	if res["ok"] != false || res.String("error") != "unknown op 'nope'; update alcove-agent" {
		t.Fatalf("res %v", res)
	}
}

func TestGatedOpWithoutAllowExec(t *testing.T) {
	s, r, w, _ := startServerS(t, Options{Clipboard: &fakeClipboard{}, HomeDir: t.TempDir()})
	s.register("t.gated", true, func(context.Context, proto.Message) (proto.Message, error) {
		return proto.Message{"ran": true}, nil
	})
	expect(t, r, "hello")
	w.Send(proto.Message{"t": "req", "id": 2, "op": "t.gated"})
	res := expect(t, r, "res")
	if res["ok"] != false || res.String("error") != "exec disabled; start alcove-agent with --allow-exec" || res.Has("ran") {
		t.Fatalf("res %v", res)
	}
}

func TestGatedOpWithAllowExec(t *testing.T) {
	s, r, w, _ := startServerS(t, Options{Clipboard: &fakeClipboard{}, HomeDir: t.TempDir(), AllowExec: true})
	s.register("t.gated", true, func(_ context.Context, req proto.Message) (proto.Message, error) {
		return proto.Message{"echo": req.String("v")}, nil
	})
	expect(t, r, "hello")
	w.Send(proto.Message{"t": "req", "id": 3, "op": "t.gated", "v": "hi"})
	res := expect(t, r, "res")
	if res["ok"] != true || res.String("echo") != "hi" {
		t.Fatalf("res %v", res)
	}
}

func TestHandlerErrorBecomesFailure(t *testing.T) {
	s, r, w, _ := startServerS(t, Options{Clipboard: &fakeClipboard{}, HomeDir: t.TempDir()})
	s.register("t.fail", false, func(context.Context, proto.Message) (proto.Message, error) {
		return nil, errors.New("no such thing; check the name")
	})
	expect(t, r, "hello")
	w.Send(proto.Message{"t": "req", "id": 4, "op": "t.fail"})
	res := expect(t, r, "res")
	if res.Int("id") != 4 || res["ok"] != false || res.String("error") != "no such thing; check the name" {
		t.Fatalf("res %v", res)
	}
}

func TestRequestsRunConcurrently(t *testing.T) {
	s, r, w, _ := startServerS(t, Options{Clipboard: &fakeClipboard{}, HomeDir: t.TempDir()})
	release := make(chan struct{})
	s.register("t.slow", false, func(context.Context, proto.Message) (proto.Message, error) {
		<-release
		return proto.Message{"which": "slow"}, nil
	})
	s.register("t.fast", false, func(context.Context, proto.Message) (proto.Message, error) {
		return proto.Message{"which": "fast"}, nil
	})
	expect(t, r, "hello")
	w.Send(proto.Message{"t": "req", "id": 1, "op": "t.slow"})
	w.Send(proto.Message{"t": "req", "id": 2, "op": "t.fast"})
	first := expect(t, r, "res")
	if first.Int("id") != 2 || first.String("which") != "fast" {
		t.Fatalf("first res %v", first)
	}
	close(release)
	second := expect(t, r, "res")
	if second.Int("id") != 1 || second.String("which") != "slow" {
		t.Fatalf("second res %v", second)
	}
}

func TestHandlerPanicBecomesError(t *testing.T) {
	s, r, w, _ := startServerS(t, Options{Clipboard: &fakeClipboard{}, HomeDir: t.TempDir()})
	s.register("t.panic", false, func(context.Context, proto.Message) (proto.Message, error) {
		panic("boom")
	})
	expect(t, r, "hello")
	w.Send(proto.Message{"t": "req", "id": 1, "op": "t.panic"})
	res := expect(t, r, "res")
	if res.Int("id") != 1 || res["ok"] != false || res.String("error") == "" {
		t.Fatalf("res %v", res)
	}
	w.Send(proto.Message{"t": "req", "id": 2, "op": "ping"})
	res = expect(t, r, "res")
	if res.Int("id") != 2 || res["ok"] != true {
		t.Fatalf("ping after panic %v", res)
	}
}

func TestEmitReachesAllConnections(t *testing.T) {
	s, r1, _, _ := startServerS(t, Options{Clipboard: &fakeClipboard{}, HomeDir: t.TempDir()})
	expect(t, r1, "hello")
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go s.Serve(l)
	c2, err := net.Dial("tcp", l.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c2.Close() })
	c2.SetDeadline(time.Now().Add(10 * time.Second))
	r2 := proto.NewReader(c2)
	expect(t, r2, "hello")

	deadline := time.Now().Add(5 * time.Second)
	for {
		s.connMu.Lock()
		n := len(s.conns)
		s.connMu.Unlock()
		if n == 2 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("connections registered: %d", n)
		}
		time.Sleep(10 * time.Millisecond)
	}

	s.emit("x", proto.Message{"n": 1})
	for i, r := range []*proto.Reader{r1, r2} {
		ev := expect(t, r, "ev")
		if ev.String("name") != "x" || ev.Int("n") != 1 {
			t.Fatalf("connection %d ev %v", i, ev)
		}
	}
}

func TestV1MessagesStillWork(t *testing.T) {
	cb := &fakeClipboard{text: "v1 text"}
	_, r, w, _ := startServerS(t, Options{Clipboard: cb, HomeDir: t.TempDir()})
	expect(t, r, "hello")
	w.Send(proto.Message{"t": "req", "id": 1, "op": "ping"})
	expect(t, r, "res")
	w.Send(proto.Message{"t": "clipboard.get"})
	if got := expect(t, r, "clipboard.text"); got.String("text") != "v1 text" {
		t.Fatalf("clipboard.text %v", got)
	}
}
