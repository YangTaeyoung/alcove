package server

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/hex"
	"io"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

// The host key pairs of the tests.
var (
	hostPrivate  = ed25519.NewKeyFromSeed(bytes.Repeat([]byte{0xA5}, 32))
	otherPrivate = ed25519.NewKeyFromSeed(bytes.Repeat([]byte{0x5A}, 32))
	testKey      = []byte(hostPrivate.Public().(ed25519.PublicKey))
)

// authServer is a listening server that checks the host key; dial opens a
// connection and returns its hello.
type authServer struct {
	t *testing.T
	s *Server
	l net.Listener
}

// startAuthServer starts a server with opt, testKey as its HostKey unless opt
// has one, and the token "tok" unless opt has one.
func startAuthServer(t *testing.T, opt Options) *authServer {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	opt.AllowPeers = loopbackPeers
	if opt.HostKey == nil {
		opt.HostKey = testKey
	}
	if opt.Token == "" {
		opt.Token = "tok"
	}
	if opt.Clipboard == nil {
		opt.Clipboard = &fakeClipboard{}
	}
	if opt.HomeDir == "" {
		opt.HomeDir = t.TempDir()
	}
	s := New(opt)
	go s.Serve(l)
	t.Cleanup(func() { l.Close() })
	return &authServer{t: t, s: s, l: l}
}

type authConn struct {
	c     net.Conn
	r     *proto.Reader
	w     *proto.Writer
	hello proto.Message
}

// open connects without reading anything.
func (a *authServer) open() *authConn {
	a.t.Helper()
	c, err := net.Dial("tcp", a.l.Addr().String())
	if err != nil {
		a.t.Fatal(err)
	}
	c.SetDeadline(time.Now().Add(10 * time.Second))
	a.t.Cleanup(func() { c.Close() })
	return &authConn{c: c, r: proto.NewReader(c), w: proto.NewWriter(c)}
}

// dial connects and reads the hello.
func (a *authServer) dial() *authConn {
	a.t.Helper()
	c := a.open()
	hello, err := c.r.Next()
	if err != nil || hello.Type() != "hello" {
		a.t.Fatalf("first message %v, %v", hello, err)
	}
	c.hello = hello
	return c
}

func (c *authConn) send(t *testing.T, m proto.Message) {
	t.Helper()
	if err := c.w.Send(m); err != nil {
		t.Fatalf("send %v: %v", m, err)
	}
}

func (c *authConn) next(t *testing.T) proto.Message {
	t.Helper()
	m, err := c.r.Next()
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	return m
}

// expectRefusedAndClosed reads a refused line with the given sentence and then
// the end of the connection.
func (c *authConn) expectRefusedAndClosed(t *testing.T, want string) {
	t.Helper()
	m := c.next(t)
	if m.Type() != "refused" || m.String("error") != want {
		t.Fatalf("got %v, expected the refusal %q", m, want)
	}
	if m, err := c.r.Next(); err != io.EOF {
		t.Fatalf("after the refusal came %v, %v", m, err)
	}
}

// nonce returns the 32 bytes of the hello's nonce.
func (c *authConn) nonce(t *testing.T) []byte {
	t.Helper()
	nonce, err := hex.DecodeString(c.hello.String("nonce"))
	if err != nil || len(nonce) != NonceSize {
		t.Fatalf("nonce %q", c.hello.String("nonce"))
	}
	return nonce
}

// signFor returns the hex signature by key of the auth context, token and the
// hello's nonce.
func (c *authConn) signFor(t *testing.T, key ed25519.PrivateKey, token string) string {
	t.Helper()
	return hex.EncodeToString(ed25519.Sign(key, authMessage(token, c.nonce(t))))
}

// sign returns the signature by key for the hello's token and nonce.
func (c *authConn) sign(t *testing.T, key ed25519.PrivateKey) string {
	t.Helper()
	return c.signFor(t, key, c.hello.String("token"))
}

// authenticate sends the host's signature and requires authed.
func (c *authConn) authenticate(t *testing.T) {
	t.Helper()
	c.send(t, proto.Message{"t": "auth", "signature": c.sign(t, hostPrivate)})
	if m := c.next(t); m.Type() != "authed" {
		t.Fatalf("auth answered %v", m)
	}
}

// ping sends a ping request and requires its ok answer.
func (c *authConn) ping(t *testing.T) {
	t.Helper()
	c.send(t, proto.Message{"t": "req", "id": 1, "op": "ping"})
	for {
		m := c.next(t)
		if m.Type() == "res" {
			if m["ok"] != true {
				t.Fatalf("ping answered %v", m)
			}
			return
		}
	}
}

func TestTheHelloAsksForASignatureOfANewNonce(t *testing.T) {
	a := startAuthServer(t, Options{})
	first, second := a.dial(), a.dial()
	for _, c := range []*authConn{first, second} {
		if c.hello.String("auth") != "key" || len(c.hello.String("nonce")) != 2*NonceSize || c.hello.String("token") != "tok" || c.hello.Has("paired") {
			t.Fatalf("hello %v", c.hello)
		}
	}
	if first.hello.String("nonce") == second.hello.String("nonce") {
		t.Fatal("two connections got the same nonce")
	}
}

func TestTheHostsSignatureOfTheTokenAndTheNonceIsServed(t *testing.T) {
	a := startAuthServer(t, Options{})
	c := a.dial()
	c.authenticate(t)
	c.ping(t)
}

func TestASignatureForAnotherTokenIsRefused(t *testing.T) {
	a := startAuthServer(t, Options{Token: "tok-b"})
	c := a.dial()
	c.send(t, proto.Message{"t": "auth", "signature": c.signFor(t, hostPrivate, "tok-a")})
	c.expectRefusedAndClosed(t, errAuthMismatch)
}

func TestARelayBetweenTwoAgentsWithTheSameKeyAndDifferentTokensIsRefused(t *testing.T) {
	a := startAuthServer(t, Options{Token: "tok-a"})
	b := startAuthServer(t, Options{Token: "tok-b"})
	toB := b.dial()
	// A program that holds A's port shows the host A's token with B's nonce;
	// the host signs A's token and that nonce.
	fake := &authConn{hello: proto.Message{"token": "tok-a", "nonce": toB.hello.String("nonce")}}
	relayed := fake.sign(t, hostPrivate)
	toB.send(t, proto.Message{"t": "auth", "signature": relayed})
	toB.expectRefusedAndClosed(t, errAuthMismatch)

	toA := a.dial()
	toA.authenticate(t)
	toA.ping(t)
}

func TestASignatureOfAnotherKeyIsRefused(t *testing.T) {
	a := startAuthServer(t, Options{})
	c := a.dial()
	c.send(t, proto.Message{"t": "auth", "signature": c.sign(t, otherPrivate)})
	c.expectRefusedAndClosed(t, errAuthMismatch)
}

func TestASignatureWithoutTheTokenIsRefused(t *testing.T) {
	a := startAuthServer(t, Options{})
	for _, prefix := range []string{"alcove-agent-auth-v1", authContext, ""} {
		c := a.dial()
		message := append([]byte(prefix), c.nonce(t)...)
		c.send(t, proto.Message{"t": "auth", "signature": hex.EncodeToString(ed25519.Sign(hostPrivate, message))})
		c.expectRefusedAndClosed(t, errAuthMismatch)
	}
}

func TestAMalformedSignatureIsRefused(t *testing.T) {
	a := startAuthServer(t, Options{})
	for _, sig := range []string{"", "zz", strings.Repeat("0", 127), strings.Repeat("0", 128), strings.Repeat("g", 128)} {
		c := a.dial()
		c.send(t, proto.Message{"t": "auth", "signature": sig})
		c.expectRefusedAndClosed(t, errAuthMismatch)
	}
}

func TestASignatureOfAnEarlierConnectionIsRefused(t *testing.T) {
	a := startAuthServer(t, Options{})
	first := a.dial()
	sig := first.sign(t, hostPrivate)
	first.send(t, proto.Message{"t": "auth", "signature": sig})
	if m := first.next(t); m.Type() != "authed" {
		t.Fatalf("auth answered %v", m)
	}
	replay := a.dial()
	replay.send(t, proto.Message{"t": "auth", "signature": sig})
	replay.expectRefusedAndClosed(t, errAuthMismatch)
}

func TestAPairMessageIsRefusedAsUnauthenticated(t *testing.T) {
	a := startAuthServer(t, Options{})
	c := a.dial()
	c.send(t, proto.Message{"t": "pair", "publicKey": hex.EncodeToString(testKey)})
	c.expectRefusedAndClosed(t, errUnauthenticated)
}

func TestAnAgentWithoutAHostKeyOrTokenServesNothing(t *testing.T) {
	for _, opt := range []Options{
		{Token: "tok", HostKey: []byte{}},
		{Token: "tok", HostKey: testKey[:31]},
		{Token: "tok", HostKey: append(append([]byte(nil), testKey...), 0)},
	} {
		a := startAuthServer(t, opt)
		c := a.open()
		c.expectRefusedAndClosed(t, errNoHostKey)
	}
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go New(Options{HostKey: testKey, AllowPeers: loopbackPeers, Clipboard: &fakeClipboard{}, HomeDir: t.TempDir()}).Serve(l)
	c, err := net.Dial("tcp", l.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(10 * time.Second))
	(&authConn{r: proto.NewReader(c)}).expectRefusedAndClosed(t, errNoHostKey)
}

func TestNoTokenIsNeverSigned(t *testing.T) {
	nonce := bytes.Repeat([]byte{1}, NonceSize)
	sig := hex.EncodeToString(ed25519.Sign(hostPrivate, append([]byte(authContext), nonce...)))
	if hostSigned(testKey, "", nonce, sig) {
		t.Fatal("a signature without a token verified for an empty token")
	}
}

func TestARequestBeforeAuthIsAnsweredWithTheSentenceAndNotRun(t *testing.T) {
	a := startAuthServer(t, Options{AllowExec: true})
	ran := make(chan struct{}, 1)
	a.s.register("t.run", false, func(context.Context, proto.Message) (proto.Message, error) {
		ran <- struct{}{}
		return proto.Message{}, nil
	})
	c := a.dial()
	c.send(t, proto.Message{"t": "welcome", "v": 1})
	c.send(t, proto.Message{"t": "req", "id": 7, "op": "t.run"})
	res := c.next(t)
	if res.Type() != "res" || res.Int("id") != 7 || res["ok"] != false || res.String("error") != errUnauthenticated {
		t.Fatalf("req answered %v", res)
	}
	c.expectRefusedAndClosed(t, errUnauthenticated)
	select {
	case <-ran:
		t.Fatal("the request ran")
	default:
	}
}

func TestAnExecBeforeAuthIsAnsweredWithTheSentence(t *testing.T) {
	a := startAuthServer(t, Options{AllowExec: true})
	c := a.dial()
	c.send(t, proto.Message{"t": "exec", "cmd": "echo hi"})
	m := c.next(t)
	if m.Type() != "exec.result" || m.Int("code") != -1 || m.String("out") != errUnauthenticated {
		t.Fatalf("exec answered %v", m)
	}
	c.expectRefusedAndClosed(t, errUnauthenticated)
}

func TestAClipboardSetBeforeAuthIsRefusedAndNotApplied(t *testing.T) {
	cb := &fakeClipboard{}
	a := startAuthServer(t, Options{Clipboard: cb})
	c := a.dial()
	c.send(t, proto.Message{"t": "clipboard.set", "text": "from a guest program"})
	c.expectRefusedAndClosed(t, errUnauthenticated)
	if text, _ := cb.Text(); text != "" {
		t.Fatalf("clipboard %q", text)
	}
}

func TestAConnectionWithoutAuthGetsNothingButTheRefusalAfterTheTimeout(t *testing.T) {
	cb := &fakeClipboard{}
	a := startAuthServer(t, Options{Clipboard: cb, AuthTimeout: 300 * time.Millisecond})
	c := a.dial()
	cb.external("changed in the guest")
	a.s.emit("window.opened", proto.Message{"window": "0x1"})
	c.expectRefusedAndClosed(t, errAuthTimeout)
}

func TestALineLongerThan64KiBBeforeAuthIsRefused(t *testing.T) {
	a := startAuthServer(t, Options{})
	c := a.dial()
	if _, err := c.c.Write([]byte(`{"t":"ping","pad":"` + strings.Repeat("x", preAuthLineMax) + "\"}\n")); err != nil {
		t.Fatal(err)
	}
	c.expectRefusedAndClosed(t, errPreAuthLine)
}

func TestALineOf64KiBBeforeAuthAndALongerOneAfterAuthAreRead(t *testing.T) {
	cb := &fakeClipboard{}
	a := startAuthServer(t, Options{Clipboard: cb})
	c := a.dial()
	pad := `{"t":"ping","pad":"`
	line := pad + strings.Repeat("x", preAuthLineMax-len(pad)-2) + "\"}"
	if _, err := c.c.Write([]byte(line + "\n")); err != nil {
		t.Fatal(err)
	}
	c.authenticate(t)
	text := strings.Repeat("y", 4*preAuthLineMax)
	c.send(t, proto.Message{"t": "clipboard.set", "text": text})
	c.ping(t)
	if got, _ := cb.Text(); got != text {
		t.Fatalf("clipboard holds %d bytes", len(got))
	}
}

func TestAHostThatSignsAtOnceIsAuthedWhile16IdleHandshakesAreOpen(t *testing.T) {
	a := startAuthServer(t, Options{})
	idle := make([]*authConn, 0, maxHandshakes)
	for i := 0; i < maxHandshakes; i++ {
		idle = append(idle, a.dial())
	}
	for round := 0; round < 3; round++ {
		c := a.dial()
		c.authenticate(t)
		c.ping(t)
		idle[round].expectRefusedAndClosed(t, errHandshakeReplaced)
		idle = append(idle, a.dial())
	}
	for _, c := range idle[3 : maxHandshakes-1] {
		c.authenticate(t)
	}
}

func TestAHandshakeReplacedWhileItsHelloIsWrittenIsRefusedWithoutWaitingForAuth(t *testing.T) {
	a := startAuthServer(t, Options{AuthTimeout: 5 * time.Second})
	server, client := net.Pipe()
	defer client.Close()
	served := make(chan bool, 1)
	go func() {
		defer server.Close()
		limit := &lineLimit{r: server, max: preAuthLineMax}
		served <- a.s.handshake(server, proto.NewReader(limit), limit)
	}()
	for deadline := time.Now().Add(5 * time.Second); ; time.Sleep(10 * time.Millisecond) {
		a.s.handshakes.mu.Lock()
		n := len(a.s.handshakes.entries)
		a.s.handshakes.mu.Unlock()
		if n == 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the handshake did not join the queue")
		}
	}
	for i := 0; i < maxHandshakes; i++ {
		a.dial()
	}
	client.SetDeadline(time.Now().Add(2 * time.Second))
	c := &authConn{c: client, r: proto.NewReader(client)}
	if hello := c.next(t); hello.Type() != "hello" {
		t.Fatalf("first message %v", hello)
	}
	c.expectRefusedAndClosed(t, errHandshakeReplaced)
	if <-served {
		t.Fatal("the replaced handshake was served")
	}
}

func TestAServedConnectionIsNotClosedForANewerHandshake(t *testing.T) {
	a := startAuthServer(t, Options{})
	served := a.dial()
	served.authenticate(t)
	for i := 0; i < maxHandshakes+2; i++ {
		a.dial()
	}
	served.ping(t)
}

func TestAnUnauthenticatedServerSendsAHelloWithoutAuth(t *testing.T) {
	_, r, _, _ := startServerS(t, Options{Token: "tok", Clipboard: &fakeClipboard{}, HomeDir: t.TempDir()})
	hello := expect(t, r, "hello")
	for _, k := range []string{"auth", "nonce", "paired"} {
		if hello.Has(k) {
			t.Fatalf("hello %v has %s", hello, k)
		}
	}
}

// The vector that AgentAuthTests.swift checks too: seed 0xA5 x 32, token
// vectorToken, nonce 0x0F x 32.
const (
	vectorToken     = "6f1c2d3e-4a5b-4c6d-8e7f-0123456789ab"
	vectorPublicKey = "29e5833a915a6429a4e3a7948475c338ef436eb82be89c92f059704403db9d55"
	// vectorCryptoKitSignature was produced by CryptoKit's Curve25519.Signing for the vector.
	vectorCryptoKitSignature = "0037298425146c70bd7cd31220376c19c0ce2168d7be15b7fea0625a60f3bfd7f58a4a6fbdb3b7b8771165ff5935d143d795c269049001dcdd4a8da57500ae02"
	// vectorGoSignature is ed25519.Sign's signature for the vector.
	vectorGoSignature = "9f85de9d08926c99e4e61d5005737259169e804fd6e6da71a875682255b1d7fbcaca02d777c3d091b800b781fa396bb9b66984a1bb0cd167dd900d2c8a670d03"
)

func TestTheSignaturesOfTheVectorVerify(t *testing.T) {
	private := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{0xA5}, 32))
	public := private.Public().(ed25519.PublicKey)
	if got := hex.EncodeToString(public); got != vectorPublicKey {
		t.Fatalf("public key %s, expected %s", got, vectorPublicKey)
	}
	nonce := bytes.Repeat([]byte{0x0F}, NonceSize)
	if got := hex.EncodeToString(ed25519.Sign(private, authMessage(vectorToken, nonce))); got != vectorGoSignature {
		t.Fatalf("ed25519.Sign = %s, expected %s", got, vectorGoSignature)
	}
	for _, sig := range []string{vectorCryptoKitSignature, vectorGoSignature} {
		if !hostSigned(public, vectorToken, nonce, sig) {
			t.Fatalf("%s does not verify", sig)
		}
	}
	if hostSigned(public, vectorToken, bytes.Repeat([]byte{0x0E}, NonceSize), vectorCryptoKitSignature) {
		t.Fatal("the signature verifies for another nonce")
	}
	if hostSigned(public, vectorToken+"0", nonce, vectorCryptoKitSignature) {
		t.Fatal("the signature verifies for another token")
	}
}
