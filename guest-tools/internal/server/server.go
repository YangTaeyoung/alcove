// Package server implements the agent side of docs/agent-protocol.md.
package server

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"log"
	"net"
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
}

// Server serves one connection at a time (the app reconnects as needed).
type Server struct {
	opt Options

	ops    map[string]opEntry
	connMu sync.Mutex
	conns  map[*conn]struct{}
	jobs   *jobTable
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

func (s *Server) handle(c net.Conn) {
	defer c.Close()
	lg := s.opt.Logger
	lg.Printf("connection from %s", c.RemoteAddr())
	var wmu sync.Mutex
	w := proto.NewWriter(c)
	send := func(m proto.Message) {
		wmu.Lock()
		defer wmu.Unlock()
		if err := w.Send(m); err != nil {
			lg.Printf("send: %v", err)
		}
	}
	cn := &conn{send: send}
	send(proto.Message{"t": "hello", "v": proto.Version, "proto": proto.RPCVersion, "os": runtime.GOOS, "agent": AgentVersion,
		"token": s.opt.Token, "caps": s.caps()})
	s.addConn(cn)
	defer s.removeConn(cn)

	done := make(chan struct{})
	defer close(done)
	if s.opt.Clipboard.Available() {
		go s.watchClipboard(send, done)
	}
	go func() { // keepalive
		t := time.NewTicker(10 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-done:
				return
			case <-t.C:
				send(proto.Message{"t": "ping"})
			}
		}
	}()

	xfers := map[string]*fileXfer{}
	r := proto.NewReader(c)
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
			go s.dispatch(m, send)
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

var (
	ownMu   sync.Mutex
	ownSeq  uint64
	ownTime time.Time
)

func (s *Server) markOwnClipboard() {
	ownMu.Lock()
	ownSeq = s.opt.Clipboard.Sequence()
	ownTime = time.Now()
	ownMu.Unlock()
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
		ownMu.Lock()
		own := seq == ownSeq && time.Since(ownTime) < 2*time.Second
		ownMu.Unlock()
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
	out, _ := combined.snapshot()
	code := 0
	if err != nil {
		code = 1
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		}
	}
	return tailUTF8(out, runStreamBytes), code
}
