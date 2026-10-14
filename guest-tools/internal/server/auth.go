package server

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"runtime"
	"sync"
	"time"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

// NonceSize is the length in bytes of a hello nonce.
const NonceSize = 32

// authContext comes first in the message the host signs, before the token and
// the nonce.
const authContext = "alcove-agent-auth-v2"

// defaultAuthTimeout is how long a connection may take from the hello to its
// auth message.
const defaultAuthTimeout = 10 * time.Second

// preAuthLineMax bounds a line the agent reads before authed.
const preAuthLineMax = 64 << 10

// maxHandshakes bounds the connections between their hello and authed; a
// newer one closes the oldest.
const maxHandshakes = 16

const (
	errNoHostKey         = "this alcove-agent serves nothing because the VM's SMBIOS strings lack alcove-hostkey or alcove-token; start the VM with Alcove 0.2 or later"
	errAuthMismatch      = "the host's signature does not match this VM's alcove-hostkey and alcove-token; restart the VM with Alcove so the guest reads the key and token in its config.json"
	errUnauthenticated   = "this alcove-agent serves only a host that proves the VM's key; update the Alcove app on the host"
	errAuthTimeout       = "no auth message arrived within 10 s; the host authenticates right after the hello"
	errPreAuthLine       = "a line before auth is longer than 65536 bytes; the host sends only auth before authed"
	errHandshakeReplaced = "this connection was closed for a newer one because 16 connections were authenticating; the host authenticates right after the hello"
)

// refusalReason names the kind of a refusal; the refusal log counts by it.
type refusalReason string

const (
	reasonPeer            refusalReason = "peer"
	reasonNoHostKey       refusalReason = "no host key"
	reasonSignature       refusalReason = "signature"
	reasonUnauthenticated refusalReason = "unauthenticated"
	reasonTimeout         refusalReason = "timeout"
	reasonLongLine        refusalReason = "long line"
	reasonReplaced        refusalReason = "replaced"
	reasonReadError       refusalReason = "read error"
)

// hostSigned reports whether signatureText is the hex Ed25519 signature by
// the private key of public of authContext, token and nonce. An empty token
// or a public key of another length is never signed.
func hostSigned(public []byte, token string, nonce []byte, signatureText string) bool {
	if len(public) != ed25519.PublicKeySize || token == "" || len(signatureText) != 2*ed25519.SignatureSize {
		return false
	}
	signature, err := hex.DecodeString(signatureText)
	if err != nil {
		return false
	}
	return ed25519.Verify(ed25519.PublicKey(public), authMessage(token, nonce), signature)
}

// authMessage is authContext, the UTF-8 bytes of token and nonce.
func authMessage(token string, nonce []byte) []byte {
	m := make([]byte, 0, len(authContext)+len(token)+len(nonce))
	m = append(m, authContext...)
	m = append(m, token...)
	return append(m, nonce...)
}

// keyed reports whether the server has a host key and a token to check a
// signature with.
func (s *Server) keyed() bool {
	return len(s.opt.HostKey) == ed25519.PublicKeySize && s.opt.Token != ""
}

// authTimeout returns Options.AuthTimeout, or defaultAuthTimeout when it is 0.
func (s *Server) authTimeout() time.Duration {
	if s.opt.AuthTimeout > 0 {
		return s.opt.AuthTimeout
	}
	return defaultAuthTimeout
}

// errLongLine is the read error of a line longer than preAuthLineMax.
var errLongLine = errors.New("line longer than the limit before authentication")

// lineLimit passes reads through and fails one that makes the bytes since the
// last newline exceed max, while max is above 0.
type lineLimit struct {
	r   io.Reader
	mu  sync.Mutex
	max int
	run int
}

func (l *lineLimit) Read(p []byte) (int, error) {
	n, err := l.r.Read(p)
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.max <= 0 {
		return n, err
	}
	for _, b := range p[:n] {
		if b == '\n' {
			l.run = 0
			continue
		}
		l.run++
		if l.run > l.max {
			return 0, errLongLine
		}
	}
	return n, err
}

// lift ends the limit.
func (l *lineLimit) lift() {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.max = 0
}

// pendingHandshake is a connection between its hello and authed.
type pendingHandshake struct {
	c        net.Conn
	replaced bool
}

// handshakeQueue holds the pending handshakes, oldest first.
type handshakeQueue struct {
	mu      sync.Mutex
	entries []*pendingHandshake
}

// join adds c. When maxHandshakes are pending, the oldest is marked replaced
// and its read deadline is set in the past, which ends its wait for auth.
func (q *handshakeQueue) join(c net.Conn) *pendingHandshake {
	q.mu.Lock()
	defer q.mu.Unlock()
	if len(q.entries) >= maxHandshakes {
		oldest := q.entries[0]
		q.entries = q.entries[1:]
		oldest.replaced = true
		_ = oldest.c.SetReadDeadline(time.Unix(1, 0))
	}
	p := &pendingHandshake{c: c}
	q.entries = append(q.entries, p)
	return p
}

// leave removes p and reports whether a newer handshake replaced it.
func (q *handshakeQueue) leave(p *pendingHandshake) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	for i, e := range q.entries {
		if e == p {
			q.entries = append(q.entries[:i], q.entries[i+1:]...)
			break
		}
	}
	return p.replaced
}

// handshake writes the hello and, unless the server is Unauthenticated, reads
// messages until the host signed the nonce. It reports whether the
// connection is served. A refused connection gets the answer
// unauthenticatedAnswer gives, if any, and a refused line. limit is lifted
// once the connection is served.
func (s *Server) handshake(c net.Conn, r *proto.Reader, limit *lineLimit) bool {
	w := proto.NewWriter(c)
	write := func(m proto.Message) bool {
		_ = c.SetWriteDeadline(time.Now().Add(refusalWriteTimeout))
		return w.Send(m) == nil
	}
	refuse := func(reason refusalReason, text string) bool {
		s.refusals.write(s.opt.Logger, reason, c.RemoteAddr(), text)
		write(proto.Message{"t": "refused", "error": text})
		return false
	}
	hello := proto.Message{"t": "hello", "v": proto.Version, "proto": proto.RPCVersion, "os": runtime.GOOS, "agent": AgentVersion,
		"token": s.opt.Token, "caps": s.caps()}
	if s.opt.Unauthenticated {
		limit.lift()
		return write(hello)
	}
	if !s.keyed() {
		return refuse(reasonNoHostKey, errNoHostKey)
	}
	_ = c.SetReadDeadline(time.Now().Add(s.authTimeout()))
	pending := s.handshakes.join(c)
	served := false
	defer func() {
		if !served {
			s.handshakes.leave(pending)
		}
	}()
	nonce := make([]byte, NonceSize)
	if _, err := rand.Read(nonce); err != nil {
		s.opt.Logger.Printf("refused the connection from %s: no random nonce: %v", c.RemoteAddr(), err)
		return false
	}
	hello["auth"] = "key"
	hello["nonce"] = hex.EncodeToString(nonce)
	if !write(hello) {
		return false
	}
	for {
		m, err := r.Next()
		if err != nil {
			var ne net.Error
			switch {
			case errors.Is(err, errLongLine):
				return refuse(reasonLongLine, errPreAuthLine)
			case errors.As(err, &ne) && ne.Timeout():
				if s.handshakes.leave(pending) {
					_ = c.SetReadDeadline(time.Time{})
					return refuse(reasonReplaced, errHandshakeReplaced)
				}
				return refuse(reasonTimeout, errAuthTimeout)
			case err != io.EOF:
				s.refusals.write(s.opt.Logger, reasonReadError, c.RemoteAddr(), fmt.Sprintf("the connection failed before auth (%v)", err))
			}
			return false
		}
		switch m.Type() {
		case "welcome", "ping", "pong":
			continue
		case "auth":
			if !hostSigned(s.opt.HostKey, s.opt.Token, nonce, m.String("signature")) {
				return refuse(reasonSignature, errAuthMismatch)
			}
		default:
			if answer := unauthenticatedAnswer(m); answer != nil {
				write(answer)
			}
			return refuse(reasonUnauthenticated, errUnauthenticated)
		}
		s.handshakes.leave(pending)
		served = true
		_ = c.SetReadDeadline(time.Time{})
		limit.lift()
		return write(proto.Message{"t": "authed"})
	}
}

// unauthenticatedAnswer returns the reply that carries errUnauthenticated to
// a host without key support for a message that waits for one, or nil.
func unauthenticatedAnswer(m proto.Message) proto.Message {
	switch m.Type() {
	case "req":
		return proto.Message{"t": "res", "id": m["id"], "ok": false, "error": errUnauthenticated}
	case "exec":
		return proto.Message{"t": "exec.result", "code": -1, "out": errUnauthenticated}
	case "file.end":
		return proto.Message{"t": "file.done", "id": m.String("id"), "error": errUnauthenticated}
	}
	return nil
}
