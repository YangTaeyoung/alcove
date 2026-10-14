package server

import (
	"bytes"
	"encoding/hex"
	"log"
	"net"
	"net/netip"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

// logBuffer collects log lines; it is safe for concurrent use.
type logBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *logBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

// lines returns the lines that contain part.
func (b *logBuffer) lines(part string) []string {
	b.mu.Lock()
	defer b.mu.Unlock()
	var out []string
	for _, l := range strings.Split(b.buf.String(), "\n") {
		if strings.Contains(l, part) {
			out = append(out, l)
		}
	}
	return out
}

// fakeClock is a time that moves only when advanced.
type fakeClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *fakeClock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *fakeClock) advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(d)
}

func TestARepeatedRefusalIsLoggedOncePerMinutePerReason(t *testing.T) {
	logs := &logBuffer{}
	a := startAuthServer(t, Options{Logger: log.New(logs, "", 0)})
	clock := &fakeClock{t: time.Date(2026, 10, 14, 9, 0, 0, 0, time.UTC)}
	a.s.refusals.setClock(clock.now)

	badSignature := func() {
		c := a.dial()
		c.send(t, proto.Message{"t": "auth", "signature": c.sign(t, otherPrivate)})
		c.expectRefusedAndClosed(t, errAuthMismatch)
	}
	for i := 0; i < 3; i++ {
		badSignature()
	}
	other := a.dial()
	other.send(t, proto.Message{"t": "pair", "publicKey": hex.EncodeToString(testKey)})
	other.expectRefusedAndClosed(t, errUnauthenticated)

	if got := logs.lines(errAuthMismatch); len(got) != 1 || !strings.HasSuffix(got[0], ": "+errAuthMismatch) {
		t.Fatalf("lines for the mismatch %q", got)
	}
	if got := logs.lines(errUnauthenticated); len(got) != 1 {
		t.Fatalf("lines for the pair %q", got)
	}

	clock.advance(59 * time.Second)
	badSignature()
	if got := logs.lines(errAuthMismatch); len(got) != 1 {
		t.Fatalf("lines for the mismatch within the minute %q", got)
	}

	clock.advance(time.Second)
	badSignature()
	got := logs.lines(errAuthMismatch)
	if len(got) != 2 || !strings.HasSuffix(got[1], errAuthMismatch+" (3 more refused for this reason since the last line)") {
		t.Fatalf("lines for the mismatch after the minute %q", got)
	}

	clock.advance(time.Minute)
	badSignature()
	got = logs.lines(errAuthMismatch)
	if len(got) != 3 || !strings.HasSuffix(got[2], ": "+errAuthMismatch) {
		t.Fatalf("lines for the mismatch after a quiet minute %q", got)
	}
}

func TestRefusalsFromManyAddressesAreOneReason(t *testing.T) {
	logs := &logBuffer{}
	lg := log.New(logs, "", 0)
	var r refusalLog
	r.setClock((&fakeClock{t: time.Date(2026, 10, 14, 9, 0, 0, 0, time.UTC)}).now)
	for i := 2; i < 5002; i++ {
		addr := netip.AddrFrom4([4]byte{127, 0, byte(i >> 8), byte(i)})
		remote := net.TCPAddrFromAddrPort(netip.AddrPortFrom(addr, 40000))
		r.write(lg, reasonPeer, remote, refusal(DefaultPeers, addr))
	}
	if got := logs.lines("refused the connection from"); len(got) != 1 || !strings.HasPrefix(got[0], "refused the connection from 127.0.0.2:40000: ") {
		t.Fatalf("lines %q", got)
	}
	if len(r.entries) != 1 {
		t.Fatalf("%d entries", len(r.entries))
	}
}

func TestARefusedConnectionWritesNoConnectionLine(t *testing.T) {
	logs := &logBuffer{}
	a := startAuthServer(t, Options{Logger: log.New(logs, "", 0)})
	refused := a.dial()
	refused.send(t, proto.Message{"t": "auth", "signature": refused.sign(t, otherPrivate)})
	refused.expectRefusedAndClosed(t, errAuthMismatch)
	if got := logs.lines("connection from"); len(got) != 1 || !strings.HasPrefix(got[0], "refused the connection from ") {
		t.Fatalf("lines %q", got)
	}

	served := a.dial()
	served.authenticate(t)
	served.ping(t)
	if got := logs.lines("connection from"); len(got) != 2 || !strings.HasPrefix(got[1], "connection from 127.0.0.1:") {
		t.Fatalf("lines %q", got)
	}
}

func TestARepeatedPeerRefusalIsLoggedOncePerMinute(t *testing.T) {
	logs := &logBuffer{}
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	s := New(Options{Token: "tok", Clipboard: &fakeClipboard{}, HomeDir: t.TempDir(), Logger: log.New(logs, "", 0),
		AllowPeers: []netip.Prefix{netip.MustParsePrefix("10.0.2.2/32")}})
	go s.Serve(l)
	sentence := "alcove-agent serves only connections from 10.0.2.2/32 and this one comes from 127.0.0.1; start alcove-agent with --allow-peer 127.0.0.1/32 to serve it"
	for i := 0; i < 3; i++ {
		c, err := net.Dial("tcp", l.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		c.SetDeadline(time.Now().Add(10 * time.Second))
		m, err := proto.NewReader(c).Next()
		c.Close()
		if err != nil || m.String("error") != sentence {
			t.Fatalf("answer %v, %v", m, err)
		}
	}
	if got := logs.lines("refused the connection from"); len(got) != 1 || !strings.HasSuffix(got[0], ": "+sentence) {
		t.Fatalf("lines %q", got)
	}
}
