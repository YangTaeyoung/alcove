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
	noReady  bool // the child announces "ready" itself
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
		go func() {
			if !f.noReady {
				sendReady(resW)
			}
			f.play(n, reqR, resW)
		}()
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

func sendReady(out io.Writer) { writeLine(out, map[string]any{"ev": "ready"}) }

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

// waitQueued blocks until n calls wait for their turn.
func waitQueued(t *testing.T, h *Helper, n int) {
	t.Helper()
	deadline := time.Now().Add(longWait)
	for {
		h.mu.Lock()
		got := len(h.waiters)
		h.mu.Unlock()
		if got == n {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("%d calls wait for their turn, expected %d", got, n)
		}
		time.Sleep(time.Millisecond)
	}
}

func TestCallsReachTheHelperOneAtATimeInArrivalOrder(t *testing.T) {
	const n = 12
	var inside, most atomic.Int32
	var mu sync.Mutex
	var order []float64
	release := make(chan struct{})
	f := newFake(func(_ int, in io.Reader, out io.Writer) {
		reqs := make(chan map[string]any, n)
		go readRequests(in, func(req map[string]any) bool {
			now := inside.Add(1)
			for {
				seen := most.Load()
				if now <= seen || most.CompareAndSwap(seen, now) {
					break
				}
			}
			reqs <- req
			return true
		})
		for req := range reqs {
			mu.Lock()
			order = append(order, req["x"].(float64))
			first := len(order) == 1
			mu.Unlock()
			if first {
				<-release
			}
			time.Sleep(2 * time.Millisecond)
			inside.Add(-1)
			writeLine(out, map[string]any{"id": req["id"], "ok": true, "x": req["x"]})
		}
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
				errs <- "a call received the reply of another call"
			}
		}(i)
		if i == 0 {
			for h.busyNow() != "echo" {
				time.Sleep(time.Millisecond)
			}
		} else {
			waitQueued(t, h, i)
		}
	}
	close(release)
	wg.Wait()
	close(errs)
	for e := range errs {
		t.Error(e)
	}
	if got := most.Load(); got != 1 {
		t.Errorf("%d requests were inside the helper at once", got)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(order) != n {
		t.Fatalf("the helper received %d requests", len(order))
	}
	for i, x := range order {
		if x != float64(i) {
			t.Fatalf("the helper received the calls in the order %v", order)
		}
	}
}

func TestTimeoutOfAQueuedCallStartsWhenTheHelperReceivesIt(t *testing.T) {
	f := newFake(func(_ int, in io.Reader, out io.Writer) {
		readRequests(in, func(req map[string]any) bool {
			if req["op"] == "slow" {
				time.Sleep(400 * time.Millisecond)
			}
			writeLine(out, map[string]any{"id": req["id"], "ok": true, "op": req["op"]})
			return true
		})
	})
	h := New(f.launcher(), nil)
	defer h.Close()
	slow := make(chan error, 1)
	go func() {
		_, err := h.Call("slow", nil, longWait)
		slow <- err
	}()
	for h.busyNow() != "slow" {
		time.Sleep(time.Millisecond)
	}
	got, err := h.Call("fast", nil, 200*time.Millisecond)
	if err != nil || got["op"] != "fast" {
		t.Fatalf("queued call: %v %v", got, err)
	}
	if err := <-slow; err != nil {
		t.Fatal(err)
	}
	if got := f.launches.Load(); got != 1 {
		t.Fatalf("launches %d", got)
	}
}

// busyNow returns the op of the call that holds the helper, or "".
func (h *Helper) busyNow() string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.busyOp
}

func TestQueuedCallAnswersBusyAfterTheQueueWaitAndTheHelperKeepsRunning(t *testing.T) {
	release := make(chan struct{})
	f := newFake(func(_ int, in io.Reader, out io.Writer) {
		readRequests(in, func(req map[string]any) bool {
			if req["op"] == "ui.tree" {
				<-release
			}
			writeLine(out, map[string]any{"id": req["id"], "ok": true, "op": req["op"]})
			return true
		})
	})
	h := New(f.launcher(), nil)
	h.queueWait = 100 * time.Millisecond
	defer h.Close()
	long := make(chan error, 1)
	go func() {
		_, err := h.Call("ui.tree", nil, longWait)
		long <- err
	}()
	for h.busyNow() != "ui.tree" {
		time.Sleep(time.Millisecond)
	}
	_, err := h.Call("win.list", nil, longWait)
	if err == nil || err.Error() != "the UI helper is busy with 'ui.tree'; retry" {
		t.Fatalf("err %v", err)
	}
	waitQueued(t, h, 0)
	select {
	case <-f.killed[0]:
		t.Fatal("the helper was killed")
	default:
	}
	close(release)
	if err := <-long; err != nil {
		t.Fatalf("the call that held the helper: %v", err)
	}
	if got, err := h.Call("win.list", nil, longWait); err != nil || got["op"] != "win.list" {
		t.Fatalf("call after the busy answer: %v %v", got, err)
	}
	if got := f.launches.Load(); got != 1 {
		t.Fatalf("launches %d", got)
	}
}

func TestCallQueuedBehindATimedOutCallRunsInTheNextHelper(t *testing.T) {
	f := newFake(func(n int, in io.Reader, out io.Writer) {
		readRequests(in, func(req map[string]any) bool {
			if n > 0 {
				writeLine(out, map[string]any{"id": req["id"], "ok": true, "op": req["op"], "launch": n})
			}
			return true
		})
	})
	h := New(f.launcher(), nil)
	defer h.Close()
	stuck := make(chan error, 1)
	go func() {
		_, err := h.Call("ui.tree", nil, 150*time.Millisecond)
		stuck <- err
	}()
	for h.busyNow() != "ui.tree" {
		time.Sleep(time.Millisecond)
	}
	type reply struct {
		fields map[string]any
		err    error
	}
	queued := make(chan reply, 2)
	for _, op := range []string{"win.list", "ui.find"} {
		op := op
		go func() {
			got, err := h.Call(op, nil, longWait)
			queued <- reply{got, err}
		}()
		for !h.queuedOp(op) {
			time.Sleep(time.Millisecond)
		}
	}
	if err := <-stuck; err == nil || err.Error() != "UI helper did not answer 'ui.tree' within 0.15 s; it was restarted" {
		t.Fatalf("err %v", err)
	}
	seen := map[string]bool{}
	for i := 0; i < 2; i++ {
		r := <-queued
		if r.err != nil {
			t.Fatalf("queued call: %v", r.err)
		}
		if r.fields["launch"] != float64(1) {
			t.Fatalf("queued call answered by %v", r.fields)
		}
		seen[r.fields["op"].(string)] = true
	}
	if !seen["win.list"] || !seen["ui.find"] {
		t.Fatalf("answered ops %v", seen)
	}
	if got := f.launches.Load(); got != 2 {
		t.Fatalf("launches %d", got)
	}
}

// queuedOp reports whether a call of op waits for its turn.
func (h *Helper) queuedOp(op string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, w := range h.waiters {
		if w.op == op {
			return true
		}
	}
	return false
}

func TestCallQueuedBehindACallWhoseHelperExitedRunsInTheNextHelper(t *testing.T) {
	die := make(chan struct{})
	f := newFake(func(n int, in io.Reader, out io.Writer) {
		if n == 0 {
			<-die
			out.(io.Closer).Close()
			return
		}
		echoPlay(n, in, out)
	})
	h := New(f.launcher(), nil)
	defer h.Close()
	first := make(chan error, 1)
	go func() {
		_, err := h.Call("ui.tree", nil, longWait)
		first <- err
	}()
	for h.busyNow() != "ui.tree" {
		time.Sleep(time.Millisecond)
	}
	second := make(chan error, 1)
	go func() {
		_, err := h.Call("win.list", map[string]any{"x": 1}, longWait)
		second <- err
	}()
	waitQueued(t, h, 1)
	close(die)
	if err := <-first; err == nil || err.Error() != "UI helper exited; retry" {
		t.Fatalf("call inside the helper that exited: %v", err)
	}
	if err := <-second; err != nil {
		t.Fatalf("queued call: %v", err)
	}
	if got := f.launches.Load(); got != 2 {
		t.Fatalf("launches %d", got)
	}
}

func TestCallTimesOutWhenTheHelperDoesNotReadItsInput(t *testing.T) {
	f := newFake(func(n int, in io.Reader, out io.Writer) {
		if n > 0 {
			echoPlay(n, in, out)
		}
	})
	h := New(f.launcher(), nil)
	defer h.Close()
	_, err := h.Call("ui.tree", nil, 100*time.Millisecond)
	if err == nil || err.Error() != "UI helper did not answer 'ui.tree' within 0.1 s; it was restarted" {
		t.Fatalf("err %v", err)
	}
	select {
	case <-f.killed[0]:
	case <-time.After(longWait):
		t.Fatal("child not killed")
	}
	if _, err := h.Call("ping", map[string]any{"x": 1}, longWait); err != nil {
		t.Fatal(err)
	}
}

func TestCloseFailsCallsThatWaitForTheirTurn(t *testing.T) {
	f := newFake(func(_ int, in io.Reader, out io.Writer) {
		readRequests(in, func(map[string]any) bool { return true })
	})
	h := New(f.launcher(), nil)
	errs := make(chan error, 2)
	go func() {
		_, err := h.Call("ui.tree", nil, longWait)
		errs <- err
	}()
	for h.busyNow() != "ui.tree" {
		time.Sleep(time.Millisecond)
	}
	go func() {
		_, err := h.Call("win.list", nil, longWait)
		errs <- err
	}()
	waitQueued(t, h, 1)
	h.Close()
	for i := 0; i < 2; i++ {
		select {
		case err := <-errs:
			if err == nil || err.Error() != "UI helper is closed" {
				t.Fatalf("err %v", err)
			}
		case <-time.After(longWait):
			t.Fatal("a call did not return after Close")
		}
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
	f := newFake(func(n int, in io.Reader, out io.Writer) {
		if n == 0 {
			readRequests(in, func(map[string]any) bool { return true })
			return
		}
		echoPlay(n, in, out)
	})
	h := New(f.launcher(), nil)
	defer h.Close()

	_, err := h.Call("ui.tree", nil, 100*time.Millisecond)
	if err == nil || err.Error() != "UI helper did not answer 'ui.tree' within 0.1 s; it was restarted" {
		t.Fatalf("err %v", err)
	}
	select {
	case <-f.killed[0]:
	case <-time.After(longWait):
		t.Fatal("child not killed")
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
			writeLine(out, map[string]any{"ev": "fatal", "error": "compile failed: CS1002"})
			return
		}
		sendReady(out)
		echoPlay(n, in, out)
	})
	f.noReady = true
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

func TestCallWaitsForSlowReady(t *testing.T) {
	f := newFake(func(n int, in io.Reader, out io.Writer) {
		time.Sleep(200 * time.Millisecond)
		sendReady(out)
		echoPlay(n, in, out)
	})
	f.noReady = true
	h := New(f.launcher(), nil)
	defer h.Close()
	if _, err := h.Call("ping", map[string]any{"x": 1}, 50*time.Millisecond); err != nil {
		t.Fatal(err)
	}
}

func TestStartTimeoutKillsAndRestarts(t *testing.T) {
	f := newFake(func(n int, in io.Reader, out io.Writer) {
		if n == 0 {
			readRequests(in, func(map[string]any) bool { return true })
			return
		}
		sendReady(out)
		echoPlay(n, in, out)
	})
	f.noReady = true
	h := New(f.launcher(), nil)
	h.startTimeout = 100 * time.Millisecond
	h.SetLogPath("C:\\uia\\helper.log")
	defer h.Close()
	_, err := h.Call("ping", nil, longWait)
	want := "UI helper did not start within 0.1 s; see C:\\uia\\helper.log"
	if err == nil || err.Error() != want {
		t.Fatalf("err %v", err)
	}
	select {
	case <-f.killed[0]:
	case <-time.After(longWait):
		t.Fatal("child not killed")
	}
	if _, err := h.Call("ping", map[string]any{"x": 1}, longWait); err != nil {
		t.Fatalf("retry: %v", err)
	}
	if got := f.launches.Load(); got != 2 {
		t.Fatalf("launches %d", got)
	}
}

func TestStartTimeoutNamesLogFolderWithoutPath(t *testing.T) {
	f := newFake(func(n int, in io.Reader, out io.Writer) {
		readRequests(in, func(map[string]any) bool { return true })
	})
	f.noReady = true
	h := New(f.launcher(), nil)
	h.startTimeout = 50 * time.Millisecond
	defer h.Close()
	_, err := h.Call("ping", nil, longWait)
	if err == nil || !strings.Contains(err.Error(), "helper.log in the agent's uia folder") {
		t.Fatalf("err %v", err)
	}
}

func TestConcurrentCallsDuringStartShareOneChild(t *testing.T) {
	release := make(chan struct{})
	f := newFake(func(n int, in io.Reader, out io.Writer) {
		<-release
		sendReady(out)
		echoPlay(n, in, out)
	})
	f.noReady = true
	h := New(f.launcher(), nil)
	defer h.Close()
	errs := make(chan error, 2)
	for i := 0; i < 2; i++ {
		go func() {
			_, err := h.Call("ping", map[string]any{"x": 1}, longWait)
			errs <- err
		}()
	}
	close(release)
	for i := 0; i < 2; i++ {
		if err := <-errs; err != nil {
			t.Fatal(err)
		}
	}
	if got := f.launches.Load(); got != 1 {
		t.Fatalf("launches %d", got)
	}
}

func TestReadyIsNotForwarded(t *testing.T) {
	events := make(chan string, 4)
	h := New(newFake(echoPlay).launcher(), func(name string, _ map[string]any) { events <- name })
	if _, err := h.Call("ping", nil, longWait); err != nil {
		t.Fatal(err)
	}
	h.Close()
	select {
	case name := <-events:
		t.Fatalf("forwarded event %q", name)
	default:
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
