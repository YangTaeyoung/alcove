package server

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"io"
	"net"
	"runtime"
	"time"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

// KeyStore keeps the Ed25519 public key of the host the agent is paired with.
type KeyStore interface {
	// Load returns the stored public key, or nil and no error when none is stored.
	Load() ([]byte, error)
	// Save stores key; it fails when a key is stored already.
	Save(key []byte) error
}

// KeySize is the length in bytes of a host public key and of a hello nonce.
const KeySize = 32

// authContext comes before the nonce in the message the host signs.
const authContext = "alcove-agent-auth-v1"

// defaultAuthTimeout is how long a connection may take from the hello to its
// pair or auth message.
const defaultAuthTimeout = 30 * time.Second

const (
	errAuthMismatch    = "the host did not prove the key this alcove-agent is paired with; when the VM's agentKey changed (a re-created VM, or a disk taken from another VM), run alcove-agent --forget-host-key as an administrator in the guest and connect again"
	errPairedOther     = "this alcove-agent is already paired with another host key; run alcove-agent --forget-host-key as an administrator in the guest and connect again"
	errNotPaired       = "this alcove-agent holds no host key; connect again to pair it"
	errBadPairKey      = "the publicKey in pair is not 64 hexadecimal digits; send the public key of the VM's agentKey"
	errUnauthenticated = "this alcove-agent serves only a host that pairs with it or proves its key; update the Alcove app on the host"
	errAuthTimeout     = "no pair or auth message arrived within 30 s; the host pairs or authenticates right after the hello"
)

// keyError is the refusal for a stored key that cannot be read or a key that
// cannot be stored.
func keyError(err error) string {
	return "this alcove-agent cannot use its host key: " + err.Error()
}

// sameSecret reports whether a and b hold the same bytes, taking a time that
// depends on their lengths only.
func sameSecret(a, b []byte) bool {
	return subtle.ConstantTimeCompare(a, b) == 1
}

// hostSigned reports whether signatureText is the hex Ed25519 signature by
// the private key of public of authContext followed by nonce.
func hostSigned(public, nonce []byte, signatureText string) bool {
	if len(public) != ed25519.PublicKeySize || len(signatureText) != 2*ed25519.SignatureSize {
		return false
	}
	signature, err := hex.DecodeString(signatureText)
	if err != nil {
		return false
	}
	message := append([]byte(authContext), nonce...)
	return ed25519.Verify(ed25519.PublicKey(public), message, signature)
}

// decodeSecret returns the KeySize bytes that 2*KeySize hexadecimal digits
// encode, or false.
func decodeSecret(text string) ([]byte, bool) {
	if len(text) != 2*KeySize {
		return nil, false
	}
	b, err := hex.DecodeString(text)
	return b, err == nil
}

// pair stores the public key keyText encodes when no key is stored and
// accepts a key equal to the stored one. It returns the refusal sentence, or
// "" when the host is served.
func (s *Server) pair(keyText string) string {
	key, ok := decodeSecret(keyText)
	if !ok {
		return errBadPairKey
	}
	s.pairMu.Lock()
	defer s.pairMu.Unlock()
	stored, err := s.opt.HostKey.Load()
	if err != nil {
		return keyError(err)
	}
	if stored != nil {
		if sameSecret(stored, key) {
			return ""
		}
		return errPairedOther
	}
	if err := s.opt.HostKey.Save(key); err != nil {
		return keyError(err)
	}
	s.opt.Logger.Printf("paired with a host key")
	return ""
}

// auth checks that signatureText is the host's signature of nonce under the
// stored public key. It returns the refusal sentence, or "" when the host is
// served.
func (s *Server) auth(signatureText string, nonce []byte) string {
	stored, err := s.opt.HostKey.Load()
	if err != nil {
		return keyError(err)
	}
	if stored == nil {
		return errNotPaired
	}
	if !hostSigned(stored, nonce, signatureText) {
		return errAuthMismatch
	}
	return ""
}

// authTimeout returns Options.AuthTimeout, or defaultAuthTimeout when it is 0.
func (s *Server) authTimeout() time.Duration {
	if s.opt.AuthTimeout > 0 {
		return s.opt.AuthTimeout
	}
	return defaultAuthTimeout
}

// handshake writes the hello and, with a HostKey, reads messages until the
// host paired or authenticated. It reports whether the connection is served.
// A refused connection gets the answer unauthenticatedAnswer gives, if any,
// and a refused line.
func (s *Server) handshake(c net.Conn, r *proto.Reader) bool {
	w := proto.NewWriter(c)
	write := func(m proto.Message) bool {
		_ = c.SetWriteDeadline(time.Now().Add(refusalWriteTimeout))
		return w.Send(m) == nil
	}
	hello := proto.Message{"t": "hello", "v": proto.Version, "proto": proto.RPCVersion, "os": runtime.GOOS, "agent": AgentVersion,
		"token": s.opt.Token, "caps": s.caps()}
	if s.opt.HostKey == nil {
		return write(hello)
	}
	nonce := make([]byte, KeySize)
	if _, err := rand.Read(nonce); err != nil {
		s.opt.Logger.Printf("refused the connection from %s: no random nonce: %v", c.RemoteAddr(), err)
		return false
	}
	stored, _ := s.opt.HostKey.Load()
	hello["auth"] = "key"
	hello["nonce"] = hex.EncodeToString(nonce)
	hello["paired"] = stored != nil
	if !write(hello) {
		return false
	}
	refuse := func(text string) bool {
		s.opt.Logger.Printf("refused the connection from %s: %s", c.RemoteAddr(), text)
		write(proto.Message{"t": "refused", "error": text})
		return false
	}
	_ = c.SetReadDeadline(time.Now().Add(s.authTimeout()))
	for {
		m, err := r.Next()
		if err != nil {
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				return refuse(errAuthTimeout)
			}
			if err != io.EOF {
				s.opt.Logger.Printf("read before authentication: %v", err)
			}
			return false
		}
		var refusal string
		switch m.Type() {
		case "welcome", "ping", "pong":
			continue
		case "pair":
			refusal = s.pair(m.String("publicKey"))
		case "auth":
			refusal = s.auth(m.String("signature"), nonce)
		default:
			if answer := unauthenticatedAnswer(m); answer != nil {
				write(answer)
			}
			refusal = errUnauthenticated
		}
		if refusal != "" {
			return refuse(refusal)
		}
		_ = c.SetReadDeadline(time.Time{})
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
