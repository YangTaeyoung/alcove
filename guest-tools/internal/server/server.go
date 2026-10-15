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
	"os/user"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/clipboard"
	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
	"github.com/YangTaeyoung/alcove/guest-tools/internal/session"
)

const AgentVersion = "0.2.1"

// Options configure the agent.
type Options struct {
	Token     string
	AllowExec bool
	Clipboard clipboard.Clipboard
	// HomeDir is the home directory of home-relative paths, file drops and
	// the default working directory; empty means the home directory of the
	// desktop session, or the agent's own without a session.
	HomeDir string
	// Session returns the desktop session whose user runs app.launch and the
	// clipboard tools; nil means the platform default (loginctl outside
	// Windows, none on Windows).
	Session func() (session.Session, bool)
	// Shutdown runs an OS shutdown; nil uses the platform default.
	Shutdown func() error
	Logger   *log.Logger
	// UI serves the ui and win ops; nil means the guest has no ui capability.
	UI UI
	// AllowPeers holds the address ranges whose connections are served; empty
	// means DefaultPeers.
	AllowPeers []netip.Prefix
	// HostKey is the host's Ed25519 public key (the SMBIOS alcove-hostkey). A
	// connection is served after the host signed its nonce and Token with the
	// matching private key. Without a HostKey of 32 bytes and a Token the
	// server serves nothing, unless Unauthenticated is set.
	HostKey []byte
	// Unauthenticated serves every connection from AllowPeers without a
	// signature and sends a hello without auth.
	Unauthenticated bool
	// AuthTimeout bounds the time from the hello to the auth message; 0 means
	// 30 s.
	AuthTimeout time.Duration
	// DeployRoot is a folder the agent keeps locked; nil means none.
	DeployRoot *DeployRoot
}

// DeployRoot names a folder that the fs operations create through Lock when
// they would create it, and whose lock fs.stat reports.
type DeployRoot struct {
	Path string
	// Lock creates the folder locked.
	Lock func() error
	// Locked reports whether the folder is locked now.
	Locked func() bool
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

	// handshakes holds the connections between their hello and authed.
	handshakes handshakeQueue
	// deployMu orders the creations of the deploy root.
	deployMu sync.Mutex

	launchMu sync.Mutex
	// claimed holds the ids of windows an app.launch has taken; a concurrent
	// launch does not take one of them. An id leaves the set when its window
	// closes, and the set is emptied when a UI helper starts.
	claimed claimSet

	ownMu   sync.Mutex
	ownSeq  uint64
	ownTime time.Time

	// refusals writes the refused connections to the log.
	refusals refusalLog

	// ownHome is the agent's own home directory, used without HomeDir and
	// without a session.
	ownHome string
}

func New(opt Options) *Server {
	if opt.Logger == nil {
		opt.Logger = log.Default()
	}
	if opt.Session == nil {
		opt.Session = defaultSessionSource()
	}
	if opt.Clipboard == nil {
		opt.Clipboard = newClipboard(opt.Session)
	}
	s := &Server{opt: opt, ops: map[string]opEntry{}, conns: map[*conn]struct{}{}, jobs: newJobTable(), ownHome: agentHome()}
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

// session returns the desktop session, when there is one.
func (s *Server) session() (session.Session, bool) {
	if s.opt.Session == nil {
		return session.Session{}, false
	}
	return s.opt.Session()
}

// homeDir returns Options.HomeDir, else the home directory of the desktop
// session, else the agent's own home directory.
func (s *Server) homeDir() string {
	if s.opt.HomeDir != "" {
		return s.opt.HomeDir
	}
	if sess, ok := s.session(); ok && sess.Home != "" {
		return sess.Home
	}
	return s.ownHome
}

// agentHome returns the home directory of the agent's user: $HOME, else the
// one in the user database.
func agentHome() string {
	if h, err := os.UserHomeDir(); err == nil && h != "" {
		return h
	}
	if u, err := user.Current(); err == nil {
		return u.HomeDir
	}
	return ""
}

// capsCheckInterval is the time between two checks of the capabilities of
// an open connection.
var capsCheckInterval = 3 * time.Second

func (s *Server) caps() []string {
	caps := []string{"files", "shutdown"}
	if resolutionSupported {
		caps = append(caps, "resolution")
	}
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
		sentence := refusal(s.allowPeers(), addr)
		s.refusals.write(lg, reasonPeer, c.RemoteAddr(), sentence)
		_ = c.SetWriteDeadline(time.Now().Add(refusalWriteTimeout))
		_ = proto.NewWriter(c).Send(proto.Message{"t": "refused", "error": sentence})
		return
	}
	limit := &lineLimit{r: c, max: preAuthLineMax}
	r := proto.NewReader(limit)
	sentCaps := s.caps()
	if !s.handshakeWith(c, r, limit, sentCaps) {
		return
	}
	lg.Printf("connection from %s", c.RemoteAddr())
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
	go s.watchClipboard(send, quit)
	go s.watchCaps(send, quit, sentCaps)
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
					s.dispatch(ctx, m, cn.sendReply)
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
			home := s.homeDir()
			dir := filepath.Join(home, "Desktop")
			if m.String("dest") == "downloads" {
				dir = filepath.Join(home, "Downloads")
			}
			name := filepath.Base(m.String("name"))
			if name == "." || name == "" || name == ".." {
				send(proto.Message{"t": "file.done", "id": id, "error": "bad name"})
				continue
			}
			owner := s.dropOwner()
			if _, err := os.Lstat(dir); err != nil {
				_ = os.MkdirAll(dir, 0o755)
				owner.give(dir)
			}
			path := uniquePath(filepath.Join(dir, name))
			f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
			if err != nil {
				send(proto.Message{"t": "file.done", "id": id, "error": err.Error()})
				continue
			}
			owner.give(path)
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

// watchCaps checks the capabilities every capsCheckInterval and sends
// {"t":"caps"} with the new list when it differs from the one sent last,
// starting with sent, the hello's list.
func (s *Server) watchCaps(send func(proto.Message), done chan struct{}, sent []string) {
	t := time.NewTicker(capsCheckInterval)
	defer t.Stop()
	for {
		select {
		case <-done:
			return
		case <-t.C:
		}
		caps := s.caps()
		if slices.Equal(caps, sent) {
			continue
		}
		sent = caps
		send(proto.Message{"t": "caps", "caps": caps})
	}
}

// dropOwner returns the owner that the files and folders a file push creates
// are given: the desktop session's user while the agent runs as root and
// HomeDir is not set, otherwise nobody.
func (s *Server) dropOwner() fileOwner {
	if s.opt.HomeDir != "" || os.Geteuid() != 0 {
		return fileOwner{}
	}
	sess, ok := s.session()
	if !ok || sess.UID == 0 {
		return fileOwner{}
	}
	return fileOwner{set: true, uid: int(sess.UID), gid: int(sess.GID)}
}

// fileOwner is a user and group that give hands entries to when set is true.
type fileOwner struct {
	set      bool
	uid, gid int
}

// give makes the owner own path, without following a link at its end.
func (o fileOwner) give(path string) {
	if o.set {
		_ = os.Lchown(path, o.uid, o.gid)
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
