// Package server implements the agent side of docs/agent-protocol.md.
package server

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"log"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/clipboard"
	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

const AgentVersion = "0.2.0"

// Options configure the agent.
type Options struct {
	Token     string
	AllowExec bool
	Clipboard clipboard.Clipboard
	// HomeDir overrides the user profile directory used for file drops.
	HomeDir string
	// Shutdown runs an OS shutdown; nil uses the platform default.
	Shutdown func() error
	Logger   *log.Logger
	// UI serves the ui and win ops; nil means the guest has no ui capability.
	UI UI
	// AllowPeers holds the address ranges whose connections are served; empty
	// means DefaultPeers.
	AllowPeers []netip.Prefix
	// HostKey keeps the key of the host the agent is paired with; a connection
	// is served after it paired or proved that key. Nil serves every
	// connection from AllowPeers without pairing.
	HostKey KeyStore
	// AuthTimeout bounds the time from the hello to the pair or auth message;
	// 0 means 30 s.
	AuthTimeout time.Duration
}

// DefaultPeers is the address from which QEMU's user-mode network delivers the
// connections it forwards from the host.
var DefaultPeers = []netip.Prefix{netip.MustParsePrefix("10.0.2.2/32")}

// refusalWriteTimeout bounds the write of the refusal line to a peer that is
// not served.
const refusalWriteTimeout = 5 * time.Second

// Server serves one connection at a time (the app reconnects as needed).
type Server struct {
	opt Options

	ops    map[string]opEntry
	connMu sync.Mutex
	conns  map[*conn]struct{}
	jobs   *jobTable

	// pairMu orders the pair messages of all connections.
	pairMu sync.Mutex

	launchMu sync.Mutex
	// claimed holds the ids of windows an app.launch has taken; a concurrent
	// launch does not take one of them. An id leaves the set when its window
	// closes, and the set is emptied when a UI helper starts.
	claimed claimSet

	ownMu   sync.Mutex
	ownSeq  uint64
	ownTime time.Time
}

func New(opt Options) *Server {
	if opt.Logger == nil {
		opt.Logger = log.Default()
	}
	if opt.Clipboard == nil {
		opt.Clipboard = clipboard.New()
	}
	if opt.HomeDir == "" {
		opt.HomeDir, _ = os.UserHomeDir()
	}
	s := &Server{opt: opt, ops: map[string]opEntry{}, conns: map[*conn]struct{}{}, jobs: newJobTable()}
	s.registerBuiltins()
	return s
}

// Close shuts the UI helper down when the server has one.
func (s *Server) Close() {
	if c, ok := s.opt.UI.(interface{ Close() }); ok {
		c.Close()
	}
}

// Serve accepts connections on l until it is closed.
func (s *Server) Serve(l net.Listener) error {
	for {
		c, err := l.Accept()
		if err != nil {
			return err
		}
		go s.handle(c)
	}
}

func (s *Server) caps() []string {
	caps := []string{"files", "shutdown", "resolution"}
	if s.opt.Clipboard.Available() {
		caps = append(caps, "clipboard")
	}
	if s.opt.AllowExec {
		caps = append(caps, "exec")
	}
	caps = append(caps, "rpc")
	if s.opt.AllowExec {
		caps = append(caps, "jobs", "proc", "fs")
	}
	if s.opt.UI != nil {
		caps = append(caps, "ui")
	}
	return caps
}

type fileXfer struct {
	f    *os.File
	path string
	size int
	got  int
	h    interface{ Write([]byte) (int, error) }
	sum  func() []byte
}

// allowPeers returns the address ranges whose connections are served.
func (s *Server) allowPeers() []netip.Prefix {
	if len(s.opt.AllowPeers) == 0 {
		return DefaultPeers
	}
	return s.opt.AllowPeers
}

// peerAllowed returns the IP address of a peer, with an IPv4-mapped IPv6
// address turned into IPv4, and whether it lies in one of the allowed ranges.
// A peer without an IP address is not allowed.
func (s *Server) peerAllowed(remote net.Addr) (netip.Addr, bool) {
	tcp, ok := remote.(*net.TCPAddr)
	if !ok {
		return netip.Addr{}, false
	}
	addr := tcp.AddrPort().Addr().Unmap().WithZone("")
	for _, p := range s.allowPeers() {
		if p.Contains(addr) {
			return addr, true
		}
	}
	return addr, false
}

// refusal is the sentence sent to a peer whose address is not allowed.
func refusal(allowed []netip.Prefix, addr netip.Addr) string {
	ranges := make([]string, len(allowed))
	for i, p := range allowed {
		ranges[i] = p.String()
	}
	head := "alcove-agent serves only connections from " + strings.Join(ranges, ", ")
	if !addr.IsValid() {
		return head + " and this one has no IP address; connect over TCP"
	}
	return fmt.Sprintf("%s and this one comes from %s; start alcove-agent with --allow-peer %s to serve it",
		head, addr, netip.PrefixFrom(addr, addr.BitLen()))
}

func (s *Server) handle(c net.Conn) {
	defer c.Close()
	lg := s.opt.Logger
	addr, ok := s.peerAllowed(c.RemoteAddr())
	if !ok {
		lg.Printf("refused the connection from %s", c.RemoteAddr())
		_ = c.SetWriteDeadline(time.Now().Add(refusalWriteTimeout))
		_ = proto.NewWriter(c).Send(proto.Message{"t": "refused", "error": refusal(s.allowPeers(), addr)})
		return
	}
	lg.Printf("connection from %s", c.RemoteAddr())
	r := proto.NewReader(c)
	if !s.handshake(c, r) {
		return
	}
	cn := newConn(c, lg)
	go cn.writeLoop()
	defer cn.stopWriter()
	send := cn.send
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	s.addConn(cn)
	defer s.removeConn(cn)

	quit := make(chan struct{})
	defer close(quit)
	if s.opt.Clipboard.Available() {
		go s.watchClipboard(send, quit)
	}
	go func() { // keepalive
		t := time.NewTicker(10 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-quit:
				return
			case <-t.C:
				send(proto.Message{"t": "ping"})
			}
		}
	}()

	inFlight := make(chan struct{}, maxInFlight)
	xfers := map[string]*fileXfer{}
	for {
		m, err := r.Next()
		if err != nil {
			if err != io.EOF {
				lg.Printf("read: %v", err)
			}
			return
		}
		switch m.Type() {
		case "ping":
			send(proto.Message{"t": "pong"})
		case "pong", "welcome":
		case "req":
			select {
			case inFlight <- struct{}{}:
				go func(m proto.Message) {
					defer func() { <-inFlight }()
					s.dispatch(ctx, m, send)
				}(m)
			default:
				send(proto.Message{"t": "res", "id": m["id"], "ok": false, "error": tooManyRequests()})
			}
		case "clipboard.get":
			text, err := s.opt.Clipboard.Text()
			if err != nil {
				lg.Printf("clipboard.get: %v", err)
			}
			send(proto.Message{"t": "clipboard.text", "text": cutUTF8Bytes(text, clipboardMaxBytes)})
		case "clipboard.set":
			if err := s.opt.Clipboard.SetText(m.String("text")); err != nil {
				lg.Printf("clipboard.set: %v", err)
			} else {
				s.markOwnClipboard()
			}
		case "resolution.set":
			if err := setResolution(m.Int("w"), m.Int("h")); err != nil {
				lg.Printf("resolution.set: %v", err)
			}
			if wdt, hgt, ok := currentResolution(); ok {
				send(proto.Message{"t": "resolution", "w": wdt, "h": hgt})
			}
		case "file.begin":
			id := m.String("id")
			dir := filepath.Join(s.opt.HomeDir, "Desktop")
			if m.String("dest") == "downloads" {
				dir = filepath.Join(s.opt.HomeDir, "Downloads")
			}
			name := filepath.Base(m.String("name"))
			if name == "." || name == "" || name == ".." {
				send(proto.Message{"t": "file.done", "id": id, "error": "bad name"})
				continue
			}
			_ = os.MkdirAll(dir, 0o755)
			path := uniquePath(filepath.Join(dir, name))
			f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
			if err != nil {
				send(proto.Message{"t": "file.done", "id": id, "error": err.Error()})
				continue
			}
			h := sha256.New()
			xfers[id] = &fileXfer{f: f, path: path, size: m.Int("size"), h: h, sum: func() []byte { return h.Sum(nil) }}
		case "file.chunk":
			x := xfers[m.String("id")]
			if x == nil {
				continue
			}
			data, err := base64.StdEncoding.DecodeString(m.String("data"))
			if err == nil && len(data) > fsChunkMax {
				err = fmt.Errorf("a file.chunk carries at most %d bytes; send smaller chunks", fsChunkMax)
			}
			if err == nil {
				_, err = x.f.Write(data)
				x.h.Write(data)
				x.got += len(data)
			}
			if err != nil {
				x.f.Close()
				os.Remove(x.path)
				delete(xfers, m.String("id"))
				send(proto.Message{"t": "file.done", "id": m.String("id"), "error": err.Error()})
			}
		case "file.end":
			id := m.String("id")
			x := xfers[id]
			if x == nil {
				continue
			}
			delete(xfers, id)
			x.f.Close()
			if want := m.String("sha256"); (want != "" && want != hex.EncodeToString(x.sum())) || (x.size > 0 && x.got != x.size) {
				os.Remove(x.path)
				send(proto.Message{"t": "file.done", "id": id, "error": "digest or size mismatch"})
				continue
			}
			send(proto.Message{"t": "file.done", "id": id, "path": x.path})
		case "shutdown":
			fn := s.opt.Shutdown
			if fn == nil {
				fn = platformShutdown
			}
			if err := fn(); err != nil {
				lg.Printf("shutdown: %v", err)
			} else {
				s.Close()
			}
		case "exec":
			if !s.opt.AllowExec {
				send(proto.Message{"t": "exec.result", "code": -1, "out": "exec disabled"})
				continue
			}
			out, code := runShell(m.String("cmd"))
			send(proto.Message{"t": "exec.result", "code": code, "out": out})
		}
	}
}

func uniquePath(p string) string {
	if _, err := os.Stat(p); err != nil {
		return p
	}
	ext := filepath.Ext(p)
	base := p[:len(p)-len(ext)]
	for i := 2; ; i++ {
		q := fmt.Sprintf("%s (%d)%s", base, i, ext)
		if _, err := os.Stat(q); err != nil {
			return q
		}
	}
}

func (s *Server) markOwnClipboard() {
	s.ownMu.Lock()
	s.ownSeq = s.opt.Clipboard.Sequence()
	s.ownTime = time.Now()
	s.ownMu.Unlock()
}

// watchClipboard polls the clipboard sequence and reports foreign changes.
func (s *Server) watchClipboard(send func(proto.Message), done chan struct{}) {
	last := s.opt.Clipboard.Sequence()
	t := time.NewTicker(400 * time.Millisecond)
	defer t.Stop()
	for {
		select {
		case <-done:
			return
		case <-t.C:
		}
		seq := s.opt.Clipboard.Sequence()
		if seq == last {
			continue
		}
		last = seq
		s.ownMu.Lock()
		own := seq == s.ownSeq && time.Since(s.ownTime) < 2*time.Second
		s.ownMu.Unlock()
		if own {
			continue
		}
		text, err := s.opt.Clipboard.Text()
		if err != nil || text == "" {
			continue
		}
		send(proto.Message{"t": "clipboard.changed", "text": cutUTF8Bytes(text, clipboardMaxBytes)})
	}
}

func runShell(cmd string) (string, int) {
	c, err := buildCommand(proto.Message{"cmd": cmd}, runtime.GOOS)
	if err != nil {
		return err.Error(), 1
	}
	hideWindow(c)
	// The child's input is a pipe at end-of-file.
	c.Stdin = strings.NewReader("")
	combined := newRing(runStreamBytes)
	c.Stdout, c.Stderr = combined, combined
	err = c.Run()
	out, cut := combined.snapshot()
	code := 0
	if err != nil {
		code = 1
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		}
	}
	return streamText(out, cut), code
}
