package server

import (
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

// stuckClipboard is a clipboard whose Text waits until release is closed and
// that counts its Sequence calls.
type stuckClipboard struct {
	fakeClipboard
	release   chan struct{}
	stuck     atomic.Bool
	sequences atomic.Int64
}

func (c *stuckClipboard) Text() (string, error) {
	if c.stuck.Load() {
		<-c.release
	}
	return c.fakeClipboard.Text()
}

func (c *stuckClipboard) Sequence() uint64 {
	c.sequences.Add(1)
	return c.fakeClipboard.Sequence()
}

func TestAHungClipboardDoesNotStopPongsOrRequests(t *testing.T) {
	cb := &stuckClipboard{release: make(chan struct{})}
	cb.stuck.Store(true)
	t.Cleanup(func() { close(cb.release) })
	_, r, w, _ := startServerS(t, Options{Clipboard: cb, HomeDir: t.TempDir(), AllowExec: true})
	expect(t, r, "hello")
	send(t, w, proto.Message{"t": "clipboard.get"})
	send(t, w, proto.Message{"t": "ping"})
	expect(t, r, "pong")
	send(t, w, proto.Message{"t": "req", "id": 1, "op": "ping"})
	if res := expect(t, r, "res"); res["ok"] != true {
		t.Fatalf("res %v", res)
	}
}

func TestClipboardSetAndGetOfAConnectionRunInOrder(t *testing.T) {
	cb := &fakeClipboard{}
	_, r, w, _ := startServerS(t, Options{Clipboard: cb, HomeDir: t.TempDir()})
	expect(t, r, "hello")
	for _, text := range []string{"one", "two", "three"} {
		send(t, w, proto.Message{"t": "clipboard.set", "text": text})
		send(t, w, proto.Message{"t": "clipboard.get"})
		if got := expect(t, r, "clipboard.text"); got.String("text") != text {
			t.Fatalf("clipboard.get after set %q answered %v", text, got)
		}
	}
}

func TestOneClipboardWatcherPollsLessWhileNothingChanges(t *testing.T) {
	oldMin, oldMax := clipboardPollMin, clipboardPollMax
	clipboardPollMin, clipboardPollMax = 10*time.Millisecond, 80*time.Millisecond
	t.Cleanup(func() { clipboardPollMin, clipboardPollMax = oldMin, oldMax })
	cb := &stuckClipboard{release: make(chan struct{})}
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go New(Options{Clipboard: cb, HomeDir: t.TempDir(), AllowPeers: loopbackPeers, Unauthenticated: true}).Serve(l)
	var wg sync.WaitGroup
	readers := make([]*proto.Reader, 3)
	for i := range readers {
		c, err := net.Dial("tcp", l.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		c.SetDeadline(time.Now().Add(10 * time.Second))
		t.Cleanup(func() { c.Close() })
		readers[i] = proto.NewReader(c)
		wg.Add(1)
		go func(r *proto.Reader) {
			defer wg.Done()
			expect(t, r, "hello")
		}(readers[i])
	}
	wg.Wait()
	time.Sleep(time.Second)
	if n := cb.sequences.Load(); n > 30 {
		t.Fatalf("the clipboard was polled %d times in 1 s by three connections", n)
	}
	cb.external("changed in the guest")
	for i, r := range readers {
		if m := expect(t, r, "clipboard.changed"); m.String("text") != "changed in the guest" {
			t.Fatalf("connection %d got %v", i, m)
		}
	}
}
