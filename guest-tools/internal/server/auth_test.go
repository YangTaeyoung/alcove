package server

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

// memoryKeyStore keeps a host key in memory.
type memoryKeyStore struct {
	mu  sync.Mutex
	key []byte
	err error
}

func (m *memoryKeyStore) Load() ([]byte, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.err != nil {
		return nil, m.err
	}
	return m.key, nil
}

func (m *memoryKeyStore) Save(key []byte) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.err != nil {
		return m.err
	}
	if m.key != nil {
		return errors.New("a key is stored")
	}
	m.key = append([]byte(nil), key...)
	return nil
}

func (m *memoryKeyStore) stored() []byte {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.key
}

var (
	testKey  = bytes.Repeat([]byte{0xA5}, KeySize)
	otherKey = bytes.Repeat([]byte{0x5A}, KeySize)
)

// authServer is a listening server with a host key store; dial opens a
// connection and returns its hello.
type authServer struct {
	t     *testing.T
	s     *Server
	l     net.Listener
	store *memoryKeyStore
}

func startAuthServer(t *testing.T, store *memoryKeyStore, opt Options) *authServer {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	opt.AllowPeers = loopbackPeers
	opt.HostKey = store
	if opt.Clipboard == nil {
		opt.Clipboard = &fakeClipboard{}
	}
	if opt.HomeDir == "" {
		opt.HomeDir = t.TempDir()
	}
	s := New(opt)
	go s.Serve(l)
	t.Cleanup(func() { l.Close() })
	return &authServer{t: t, s: s, l: l, store: store}
}

type authConn struct {
	c     net.Conn
	r     *proto.Reader
	w     *proto.Writer
	hello proto.Message
}

func (a *authServer) dial() *authConn {
	a.t.Helper()
	c, err := net.Dial("tcp", a.l.Addr().String())
	if err != nil {
		a.t.Fatal(err)
	}
	c.SetDeadline(time.Now().Add(10 * time.Second))
	a.t.Cleanup(func() { c.Close() })
	r := proto.NewReader(c)
	hello, err := r.Next()
	if err != nil || hello.Type() != "hello" {
		a.t.Fatalf("first message %v, %v", hello, err)
	}
	return &authConn{c: c, r: r, w: proto.NewWriter(c), hello: hello}
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

func (c *authConn) mac(t *testing.T, key []byte) string {
	t.Helper()
	nonce, err := hex.DecodeString(c.hello.String("nonce"))
	if err != nil || len(nonce) != KeySize {
		t.Fatalf("nonce %q", c.hello.String("nonce"))
	}
	m := hmac.New(sha256.New, key)
	m.Write(nonce)
	return hex.EncodeToString(m.Sum(nil))
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

func TestAnUnpairedAgentPairsOnceAndThenServesAHostThatProvesTheKey(t *testing.T) {
	a := startAuthServer(t, &memoryKeyStore{}, Options{Token: "tok"})
	first := a.dial()
	if first.hello.String("auth") != "key" || first.hello["paired"] != false || len(first.hello.String("nonce")) != 2*KeySize {
		t.Fatalf("hello %v", first.hello)
	}
	first.send(t, proto.Message{"t": "pair", "key": hex.EncodeToString(testKey)})
	if m := first.next(t); m.Type() != "authed" {
		t.Fatalf("pair answered %v", m)
	}
	first.ping(t)
	if !bytes.Equal(a.store.stored(), testKey) {
		t.Fatalf("stored %x", a.store.stored())
	}

	second := a.dial()
	if second.hello["paired"] != true {
		t.Fatalf("hello after pairing %v", second.hello)
	}
	if second.hello.String("nonce") == first.hello.String("nonce") {
		t.Fatal("two connections got the same nonce")
	}
	second.send(t, proto.Message{"t": "auth", "mac": second.mac(t, testKey)})
	if m := second.next(t); m.Type() != "authed" {
		t.Fatalf("auth answered %v", m)
	}
	second.ping(t)
}

func TestASecondPairWithAnotherKeyIsRefusedAndKeepsTheStoredKey(t *testing.T) {
	a := startAuthServer(t, &memoryKeyStore{key: testKey}, Options{})
	c := a.dial()
	c.send(t, proto.Message{"t": "pair", "key": hex.EncodeToString(otherKey)})
	c.expectRefusedAndClosed(t, errPairedOther)
	if !bytes.Equal(a.store.stored(), testKey) {
		t.Fatalf("stored %x", a.store.stored())
	}
}

func TestAPairWithTheStoredKeyIsServed(t *testing.T) {
	a := startAuthServer(t, &memoryKeyStore{key: testKey}, Options{})
	c := a.dial()
	c.send(t, proto.Message{"t": "pair", "key": hex.EncodeToString(testKey)})
	if m := c.next(t); m.Type() != "authed" {
		t.Fatalf("pair answered %v", m)
	}
	c.ping(t)
}

func TestAMACOfAnotherKeyIsRefused(t *testing.T) {
	a := startAuthServer(t, &memoryKeyStore{key: testKey}, Options{})
	c := a.dial()
	c.send(t, proto.Message{"t": "auth", "mac": c.mac(t, otherKey)})
	c.expectRefusedAndClosed(t, errAuthMismatch)
}

func TestAMalformedMACIsRefused(t *testing.T) {
	a := startAuthServer(t, &memoryKeyStore{key: testKey}, Options{})
	for _, mac := range []string{"", "zz", strings.Repeat("0", 63)} {
		c := a.dial()
		c.send(t, proto.Message{"t": "auth", "mac": mac})
		c.expectRefusedAndClosed(t, errAuthMismatch)
	}
}

func TestAMACOfAnEarlierConnectionIsRefusedBecauseTheNonceChanged(t *testing.T) {
	a := startAuthServer(t, &memoryKeyStore{key: testKey}, Options{})
	first := a.dial()
	mac := first.mac(t, testKey)
	first.send(t, proto.Message{"t": "auth", "mac": mac})
	if m := first.next(t); m.Type() != "authed" {
		t.Fatalf("auth answered %v", m)
	}
	replay := a.dial()
	replay.send(t, proto.Message{"t": "auth", "mac": mac})
	replay.expectRefusedAndClosed(t, errAuthMismatch)
}

func TestAuthWhileNoKeyIsStoredIsRefused(t *testing.T) {
	a := startAuthServer(t, &memoryKeyStore{}, Options{})
	c := a.dial()
	c.send(t, proto.Message{"t": "auth", "mac": c.mac(t, testKey)})
	c.expectRefusedAndClosed(t, errNotPaired)
	if a.store.stored() != nil {
		t.Fatal("a key was stored")
	}
}

func TestAPairKeyThatIsNot64HexDigitsIsRefused(t *testing.T) {
	a := startAuthServer(t, &memoryKeyStore{}, Options{})
	for _, key := range []string{"", "abc", strings.Repeat("g", 64), strings.Repeat("a", 66)} {
		c := a.dial()
		c.send(t, proto.Message{"t": "pair", "key": key})
		c.expectRefusedAndClosed(t, errBadPairKey)
	}
	if a.store.stored() != nil {
		t.Fatal("a key was stored")
	}
}

func TestAKeyStoreErrorRefusesWithItsReason(t *testing.T) {
	a := startAuthServer(t, &memoryKeyStore{err: errors.New("the data folder is not locked")}, Options{})
	c := a.dial()
	c.send(t, proto.Message{"t": "pair", "key": hex.EncodeToString(testKey)})
	c.expectRefusedAndClosed(t, "this alcove-agent cannot use its host key: the data folder is not locked")
}

func TestARequestBeforeAuthIsAnsweredWithTheSentenceAndNotRun(t *testing.T) {
	a := startAuthServer(t, &memoryKeyStore{key: testKey}, Options{AllowExec: true})
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
	a := startAuthServer(t, &memoryKeyStore{key: testKey}, Options{AllowExec: true})
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
	a := startAuthServer(t, &memoryKeyStore{key: testKey}, Options{Clipboard: cb})
	c := a.dial()
	c.send(t, proto.Message{"t": "clipboard.set", "text": "from a guest program"})
	c.expectRefusedAndClosed(t, errUnauthenticated)
	if text, _ := cb.Text(); text != "" {
		t.Fatalf("clipboard %q", text)
	}
}

func TestAConnectionWithoutPairOrAuthGetsNothingButTheRefusalAfterTheTimeout(t *testing.T) {
	cb := &fakeClipboard{}
	a := startAuthServer(t, &memoryKeyStore{key: testKey}, Options{Clipboard: cb, AuthTimeout: 300 * time.Millisecond})
	c := a.dial()
	cb.external("changed in the guest")
	a.s.emit("window.opened", proto.Message{"window": "0x1"})
	c.expectRefusedAndClosed(t, errAuthTimeout)
}

func TestAServerWithoutAKeyStoreSendsAHelloWithoutAuth(t *testing.T) {
	_, r, _, _ := startServerS(t, Options{Token: "tok", Clipboard: &fakeClipboard{}, HomeDir: t.TempDir()})
	hello := expect(t, r, "hello")
	for _, k := range []string{"auth", "nonce", "paired"} {
		if hello.Has(k) {
			t.Fatalf("hello %v has %s", hello, k)
		}
	}
}

func TestSecretsAreComparedInConstantTime(t *testing.T) {
	if !sameSecret(testKey, append([]byte(nil), testKey...)) {
		t.Fatal("equal keys differ")
	}
	last := append([]byte(nil), testKey...)
	last[KeySize-1] ^= 1
	for _, b := range [][]byte{last, testKey[:KeySize-1], nil} {
		if sameSecret(testKey, b) {
			t.Fatalf("%x matched", b)
		}
	}

	file, err := parser.ParseFile(token.NewFileSet(), "auth.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	calls := map[string]int{}
	var body *ast.BlockStmt
	ast.Inspect(file, func(n ast.Node) bool {
		switch n := n.(type) {
		case *ast.FuncDecl:
			if n.Name.Name == "sameSecret" {
				body = n.Body
			}
		case *ast.CallExpr:
			switch f := n.Fun.(type) {
			case *ast.SelectorExpr:
				if x, ok := f.X.(*ast.Ident); ok {
					calls[x.Name+"."+f.Sel.Name]++
				}
			case *ast.Ident:
				calls[f.Name]++
			}
		}
		return true
	})
	if body == nil {
		t.Fatal("auth.go has no sameSecret")
	}
	usesSubtle := false
	ast.Inspect(body, func(n ast.Node) bool {
		if sel, ok := n.(*ast.SelectorExpr); ok {
			if x, ok := sel.X.(*ast.Ident); ok && x.Name == "subtle" && sel.Sel.Name == "ConstantTimeCompare" {
				usesSubtle = true
			}
		}
		return true
	})
	if !usesSubtle {
		t.Fatal("sameSecret does not call subtle.ConstantTimeCompare")
	}
	if calls["sameSecret"] < 2 {
		t.Fatalf("auth.go calls sameSecret %d times; the pair key and the MAC both go through it", calls["sameSecret"])
	}
	for _, f := range []string{"bytes.Equal", "hmac.Equal", "reflect.DeepEqual", "bytes.Compare"} {
		if calls[f] > 0 {
			t.Fatalf("auth.go calls %s", f)
		}
	}
}
