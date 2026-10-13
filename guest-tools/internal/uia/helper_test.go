package uia

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"log"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const longWait = 10 * time.Second

// fakeHelper starts in-process "children": play runs once per launch with the
// launch number, the child's stdin and its stdout.
type fakeHelper struct {
	launches atomic.Int32
	play     func(n int, in io.Reader, out io.Writer)
	killed   [8]chan struct{}
}

func newFake(play func(n int, in io.Reader, out io.Writer)) *fakeHelper {
	f := &fakeHelper{play: play}
	for i := range f.killed {
		f.killed[i] = make(chan struct{})
	}
	return f
}

func (f *fakeHelper) launcher() Launcher {
	return func() (io.WriteCloser, io.ReadCloser, func(), error) {
		n := int(f.launches.Add(1)) - 1
		reqR, reqW := io.Pipe()
		resR, resW := io.Pipe()
		go f.play(n, reqR, resW)
		var once sync.Once
		kill := func() {
			once.Do(func() {
				close(f.killed[n])
				resW.Close()
				reqR.Close()
			})
		}
		return reqW, resR, kill, nil
	}
}

func readRequests(in io.Reader, each func(req map[string]any) bool) {
	sc := bufio.NewScanner(in)
	sc.Buffer(make([]byte, 1<<20), 16<<20)
	for sc.Scan() {
		var req map[string]any
		if json.Unmarshal(sc.Bytes(), &req) != nil {
			return
		}
		if !each(req) {
			return
		}
	}
}

func writeLine(out io.Writer, m map[string]any) {
	b, _ := json.Marshal(m)
	out.Write(append(b, '\n'))
}

func echoPlay(n int, in io.Reader, out io.Writer) {
	readRequests(in, func(req map[string]any) bool {
		writeLine(out, map[string]any{"id": req["id"], "ok": true, "op": req["op"], "x": req["x"]})
		return true
	})
}

func TestCallRoundTrip(t *testing.T) {
	h := New(newFake(echoPlay).launcher(), nil)
	defer h.Close()
	got, err := h.Call("ui.echo", map[string]any{"x": "hello"}, longWait)
	if err != nil {
		t.Fatal(err)
	}
	if got["op"] != "ui.echo" || got["x"] != "hello" {
		t.Fatalf("fields %v", got)
	}
	if _, ok := got["id"]; ok {
		t.Fatalf("id not removed: %v", got)
	}
	if _, ok := got["ok"]; ok {
		t.Fatalf("ok not removed: %v", got)
	}
}

func TestConcurrentCallsMatchedByID(t *testing.T) {
	const n = 20
	f := newFake(func(_ int, in io.Reader, out io.Writer) {
		var reqs []map[string]any
		readRequests(in, func(req map[string]any) bool {
			reqs = append(reqs, req)
			if len(reqs) < n {
				return true
			}
			for i := len(reqs) - 1; i >= 0; i-- {
				writeLine(out, map[string]any{"id": reqs[i]["id"], "ok": true, "x": reqs[i]["x"]})
			}
			return false
		})
	})
	h := New(f.launcher(), nil)
	defer h.Close()
	var wg sync.WaitGroup
	errs := make(chan string, n)
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			got, err := h.Call("echo", map[string]any{"x": float64(i)}, longWait)
			if err != nil {
				errs <- err.Error()
				return
			}
			if got["x"] != float64(i) {
				errs <- "wrong reply for call " + string(rune('A'+i))
			}
		}(i)
	}
	wg.Wait()
	close(errs)
	for e := range errs {
		t.Error(e)
	}
}

func TestErrorReply(t *testing.T) {
	f := newFake(func(_ int, in io.Reader, out io.Writer) {
		readRequests(in, func(req map[string]any) bool {
			writeLine(out, map[string]any{"id": req["id"], "ok": false, "error": "no element matches {}; call ui.tree to see what exists"})
			return true
		})
	})
	h := New(f.launcher(), nil)
	defer h.Close()
	_, err := h.Call("ui.find", nil, longWait)
	if err == nil || err.Error() != "no element matches {}; call ui.tree to see what exists" {
		t.Fatalf("err %v", err)
	}
}

func TestEventsReachCallback(t *testing.T) {
	f := newFake(func(_ int, in io.Reader, out io.Writer) {
		readRequests(in, func(req map[string]any) bool {
			writeLine(out, map[string]any{"ev": "window.opened", "window": map[string]any{"id": "0x10"}})
			writeLine(out, map[string]any{"id": req["id"], "ok": true})
			return true
		})
	})
	type event struct {
		name   string
		fields map[string]any
	}
	events := make(chan event, 4)
	h := New(f.launcher(), func(name string, fields map[string]any) { events <- event{name, fields} })
	defer h.Close()
	if _, err := h.Call("ping", nil, longWait); err != nil {
		t.Fatal(err)
	}
	select {
	case ev := <-events:
		if ev.name != "window.opened" {
			t.Fatalf("event %q", ev.name)
		}
		if _, ok := ev.fields["ev"]; ok {
			t.Fatalf("ev key not removed: %v", ev.fields)
		}
		if w, _ := ev.fields["window"].(map[string]any); w["id"] != "0x10" {
			t.Fatalf("fields %v", ev.fields)
		}
	case <-time.After(longWait):
		t.Fatal("no event")
	}
}

type syncBuf struct {
	mu sync.Mutex
	sb strings.Builder
	ch chan struct{}
}

func (b *syncBuf) Write(p []byte) (int, error) {
	b.mu.Lock()
	b.sb.Write(p)
	b.mu.Unlock()
	select {
	case b.ch <- struct{}{}:
	default:
	}
	return len(p), nil
}

func (b *syncBuf) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.sb.String()
}

func TestNonJSONLineIsLoggedAndIgnored(t *testing.T) {
	f := newFake(func(_ int, in io.Reader, out io.Writer) {
		readRequests(in, func(req map[string]any) bool {
			io.WriteString(out, "WARNING: not json\n")
			writeLine(out, map[string]any{"id": req["id"], "ok": true})
			return true
		})
	})
	buf := &syncBuf{ch: make(chan struct{}, 1)}
	h := New(f.launcher(), nil)
	h.SetLogger(log.New(buf, "", 0))
	defer h.Close()
	if _, err := h.Call("ping", nil, longWait); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(buf.String(), "WARNING: not json") {
		t.Fatalf("log %q", buf.String())
	}
}

func TestLargeReplyLine(t *testing.T) {
	big := strings.Repeat("a", 8<<20-200)
	f := newFake(func(_ int, in io.Reader, out io.Writer) {
		readRequests(in, func(req map[string]any) bool {
			writeLine(out, map[string]any{"id": req["id"], "ok": true, "text": big})
			return true
		})
	})
	h := New(f.launcher(), nil)
	defer h.Close()
	got, err := h.Call("ui.text", nil, longWait)
	if err != nil {
		t.Fatal(err)
	}
	if s, _ := got["text"].(string); len(s) != len(big) {
		t.Fatalf("text length %d", len(s))
	}
}

func TestHelperRestartsAfterExit(t *testing.T) {
	f := newFake(func(n int, in io.Reader, out io.Writer) {
		if n == 0 {
			readRequests(in, func(map[string]any) bool { return false })
			out.(io.Closer).Close()
			return
		}
		echoPlay(n, in, out)
	})
	h := New(f.launcher(), nil)
	defer h.Close()
	_, err := h.Call("ui.tree", nil, longWait)
	if err == nil || err.Error() != "UI helper exited; retry" {
		t.Fatalf("err %v", err)
	}
	if _, err := h.Call("ping", map[string]any{"x": 1}, longWait); err != nil {
		t.Fatal(err)
	}
	if got := f.launches.Load(); got != 2 {
		t.Fatalf("launches %d", got)
	}
}

func TestHelperTimeoutKillsAndRestarts(t *testing.T) {
	got := make(chan struct{}, 4)
	f := newFake(func(n int, in io.Reader, out io.Writer) {
		if n == 0 {
			readRequests(in, func(map[string]any) bool { got <- struct{}{}; return true })
			return
		}
		echoPlay(n, in, out)
	})
	h := New(f.launcher(), nil)
	defer h.Close()

	other := make(chan error, 1)
	go func() {
		_, err := h.Call("win.list", nil, longWait)
		other <- err
	}()
	<-got
	_, err := h.Call("ui.tree", nil, 100*time.Millisecond)
	if err == nil || err.Error() != "UI helper did not answer 'ui.tree' within 0.1 s; it was restarted" {
		t.Fatalf("err %v", err)
	}
	select {
	case <-f.killed[0]:
	case <-time.After(longWait):
		t.Fatal("child not killed")
	}
	select {
	case err := <-other:
		if err == nil || err.Error() != "UI helper exited; retry" {
			t.Fatalf("other pending call: %v", err)
		}
	case <-time.After(longWait):
		t.Fatal("other pending call not failed")
	}
	if _, err := h.Call("ping", map[string]any{"x": 1}, longWait); err != nil {
		t.Fatal(err)
	}
	if got := f.launches.Load(); got != 2 {
		t.Fatalf("launches %d", got)
	}
}

func TestLaunchFailureIsReported(t *testing.T) {
	var launches int
	launch := func() (io.WriteCloser, io.ReadCloser, func(), error) {
		launches++
		if launches == 1 {
			return nil, nil, nil, errors.New("file not found")
		}
		return newFake(echoPlay).launcher()()
	}
	h := New(launch, nil)
	defer h.Close()
	_, err := h.Call("ping", nil, longWait)
	if err == nil || !strings.Contains(err.Error(), "PowerShell") || !strings.Contains(err.Error(), "file not found") {
		t.Fatalf("err %v", err)
	}
	if _, err := h.Call("ping", nil, longWait); err != nil {
		t.Fatalf("retry: %v", err)
	}
}

func TestFatalEventIsLaunchFailure(t *testing.T) {
	f := newFake(func(n int, in io.Reader, out io.Writer) {
		if n == 0 {
			readRequests(in, func(map[string]any) bool {
				writeLine(out, map[string]any{"ev": "fatal", "error": "compile failed: CS1002"})
				return false
			})
			return
		}
		echoPlay(n, in, out)
	})
	h := New(f.launcher(), nil)
	defer h.Close()
	_, err := h.Call("ping", nil, longWait)
	if err == nil || !strings.Contains(err.Error(), "PowerShell") || !strings.Contains(err.Error(), "compile failed: CS1002") {
		t.Fatalf("err %v", err)
	}
	if _, err := h.Call("ping", nil, longWait); err != nil {
		t.Fatalf("retry: %v", err)
	}
}

func TestCloseStopsChild(t *testing.T) {
	got := make(chan struct{}, 1)
	f := newFake(func(_ int, in io.Reader, out io.Writer) {
		readRequests(in, func(map[string]any) bool { got <- struct{}{}; return true })
	})
	h := New(f.launcher(), nil)

	pending := make(chan error, 1)
	go func() {
		_, err := h.Call("ui.tree", nil, longWait)
		pending <- err
	}()
	<-got
	h.mu.Lock()
	readerDone := h.cur.readerDone
	h.mu.Unlock()

	h.Close()
	select {
	case <-f.killed[0]:
	default:
		t.Fatal("child not killed")
	}
	select {
	case <-readerDone:
	case <-time.After(longWait):
		t.Fatal("reader goroutine still running")
	}
	if err := <-pending; err == nil || err.Error() != "UI helper is closed" {
		t.Fatalf("pending call: %v", err)
	}
	if _, err := h.Call("ping", nil, longWait); err == nil || err.Error() != "UI helper is closed" {
		t.Fatalf("call after close: %v", err)
	}
	h.Close()
}
