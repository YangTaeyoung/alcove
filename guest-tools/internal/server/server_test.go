package server

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

type fakeClipboard struct {
	mu   sync.Mutex
	text string
	seq  uint64
}

func (f *fakeClipboard) Available() bool { return true }
func (f *fakeClipboard) Text() (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.text, nil
}
func (f *fakeClipboard) SetText(s string) error { f.external(s); return nil }
func (f *fakeClipboard) Sequence() uint64 {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.seq
}
func (f *fakeClipboard) external(s string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.text = s
	f.seq++
}

// loopbackPeers is the AllowPeers of the servers the tests connect to.
var loopbackPeers = []netip.Prefix{netip.MustParsePrefix("127.0.0.0/8")}

func startServer(t *testing.T, opt Options) (*proto.Reader, *proto.Writer, net.Conn) {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	opt.AllowPeers = loopbackPeers
	go New(opt).Serve(l)
	c, err := net.Dial("tcp", l.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close(); l.Close() })
	return proto.NewReader(c), proto.NewWriter(c), c
}

func expect(t *testing.T, r *proto.Reader, typ string) proto.Message {
	t.Helper()
	for {
		m, err := r.Next()
		if err != nil {
			t.Fatalf("waiting for %s: %v", typ, err)
		}
		if m.Type() == typ {
			return m
		}
	}
}

func TestHelloClipboardAndFiles(t *testing.T) {
	home := t.TempDir()
	cb := &fakeClipboard{}
	r, w, c := startServer(t, Options{Token: "tok", Clipboard: cb, HomeDir: home, AllowExec: true,
		Shutdown: func() error { return errors.New("not in tests") }})
	c.SetDeadline(time.Now().Add(10 * time.Second))

	hello := expect(t, r, "hello")
	if hello.String("token") != "tok" || hello.Int("v") != 1 {
		t.Fatalf("hello %v", hello)
	}
	caps, _ := hello["caps"].([]any)
	if len(caps) < 4 {
		t.Fatalf("caps %v", caps)
	}

	// host -> guest clipboard
	w.Send(proto.Message{"t": "clipboard.set", "text": "from host"})
	time.Sleep(600 * time.Millisecond)
	if got, _ := cb.Text(); got != "from host" {
		t.Fatalf("clipboard not set: %q", got)
	}
	// guest -> host clipboard (a foreign change must be reported, our own must not)
	cb.external("typed in guest")
	m := expect(t, r, "clipboard.changed")
	if m.String("text") != "typed in guest" {
		t.Fatalf("changed %v", m)
	}

	// explicit read
	w.Send(proto.Message{"t": "clipboard.get"})
	if got := expect(t, r, "clipboard.text"); got.String("text") != "typed in guest" {
		t.Fatalf("clipboard.get %v", got)
	}

	// file push
	payload := []byte("hello file")
	sum := sha256.Sum256(payload)
	w.Send(proto.Message{"t": "file.begin", "id": "f1", "name": "../evil/../note.txt", "size": len(payload), "dest": "desktop"})
	w.Send(proto.Message{"t": "file.chunk", "id": "f1", "data": base64.StdEncoding.EncodeToString(payload)})
	w.Send(proto.Message{"t": "file.end", "id": "f1", "sha256": hex.EncodeToString(sum[:])})
	done := expect(t, r, "file.done")
	if done.String("error") != "" {
		t.Fatalf("file error %v", done)
	}
	if got, _ := os.ReadFile(filepath.Join(home, "Desktop", "note.txt")); string(got) != "hello file" {
		t.Fatalf("file content %q (path %s)", got, done.String("path"))
	}
	// digest mismatch is rejected and the file removed
	w.Send(proto.Message{"t": "file.begin", "id": "f2", "name": "bad.txt", "size": 3})
	w.Send(proto.Message{"t": "file.chunk", "id": "f2", "data": base64.StdEncoding.EncodeToString([]byte("abc"))})
	w.Send(proto.Message{"t": "file.end", "id": "f2", "sha256": "00"})
	done = expect(t, r, "file.done")
	if done.String("error") == "" {
		t.Fatalf("expected digest error")
	}
	if _, err := os.Stat(filepath.Join(home, "Desktop", "bad.txt")); err == nil {
		t.Fatal("bad file kept")
	}

	// exec
	w.Send(proto.Message{"t": "exec", "cmd": "echo hi"})
	res := expect(t, r, "exec.result")
	if res.Int("code") != 0 || len(res.String("out")) < 2 {
		t.Fatalf("exec %v", res)
	}

	// ping/pong
	w.Send(proto.Message{"t": "ping"})
	expect(t, r, "pong")
}

func TestFileChunkOverOnePieceEndsThePush(t *testing.T) {
	home := t.TempDir()
	r, w, c := startServer(t, Options{Token: "tok", Clipboard: &fakeClipboard{}, HomeDir: home})
	c.SetDeadline(time.Now().Add(10 * time.Second))
	expect(t, r, "hello")
	send(t, w, proto.Message{"t": "file.begin", "id": "f1", "name": "big.bin", "size": 262145, "dest": "desktop"})
	send(t, w, proto.Message{"t": "file.chunk", "id": "f1", "data": base64.StdEncoding.EncodeToString(make([]byte, 262145))})
	done := expect(t, r, "file.done")
	if done.String("id") != "f1" || done.String("error") != "a file.chunk carries at most 262144 bytes; send smaller chunks" {
		t.Fatalf("file.done %v", done)
	}
	if _, err := os.Stat(filepath.Join(home, "Desktop", "big.bin")); err == nil {
		t.Fatal("the file was kept")
	}
}

// closingUI records Close calls.
type closingUI struct {
	fakeUI
	closed chan struct{}
}

func (c *closingUI) Close() { close(c.closed) }

func TestShutdownClosesTheUIHelperOnlyAfterTheShutdownStarted(t *testing.T) {
	for _, failed := range []bool{true, false} {
		ui := &closingUI{closed: make(chan struct{})}
		ran := make(chan struct{})
		_, r, w, _ := startServerS(t, Options{Clipboard: &fakeClipboard{}, HomeDir: t.TempDir(), UI: ui,
			Shutdown: func() error {
				defer close(ran)
				select {
				case <-ui.closed:
					t.Error("the helper was closed before the shutdown ran")
				default:
				}
				if failed {
					return errors.New("the shutdown was cancelled")
				}
				return nil
			}})
		expect(t, r, "hello")
		send(t, w, proto.Message{"t": "shutdown"})
		<-ran
		send(t, w, proto.Message{"t": "ping"})
		expect(t, r, "pong")
		select {
		case <-ui.closed:
			if failed {
				t.Fatal("a failed shutdown closed the helper")
			}
		default:
			if !failed {
				t.Fatal("a shutdown that started left the helper open")
			}
		}
	}
}

func TestExecDisabledByDefault(t *testing.T) {
	r, w, c := startServer(t, Options{Token: "x", Clipboard: &fakeClipboard{}, HomeDir: t.TempDir()})
	c.SetDeadline(time.Now().Add(5 * time.Second))
	expect(t, r, "hello")
	w.Send(proto.Message{"t": "exec", "cmd": "echo hi"})
	if res := expect(t, r, "exec.result"); res.Int("code") != -1 {
		t.Fatalf("exec should be disabled: %v", res)
	}
}
