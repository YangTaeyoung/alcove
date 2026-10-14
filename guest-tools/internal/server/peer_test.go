package server

import (
	"io"
	"net"
	"net/netip"
	"strings"
	"testing"
	"time"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

func TestADefaultServerRefusesALoopbackPeerWithOneSentence(t *testing.T) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go New(Options{Token: "tok", Clipboard: &fakeClipboard{}, HomeDir: t.TempDir()}).Serve(l)
	c, err := net.Dial("tcp", l.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(10 * time.Second))
	r := proto.NewReader(c)
	m, err := r.Next()
	if err != nil {
		t.Fatal(err)
	}
	want := "alcove-agent serves only connections from 10.0.2.2/32 and this one comes from 127.0.0.1; start alcove-agent with --allow-peer 127.0.0.1/32 to serve it"
	if m.Type() != "refused" || m.String("error") != want || m.Has("token") {
		t.Fatalf("first message %v", m)
	}
	if m, err := r.Next(); err != io.EOF {
		t.Fatalf("after the refusal came %v, %v", m, err)
	}
}

func TestAServerWithAnAllowedPeerSendsTheHello(t *testing.T) {
	_, r, w, _ := startServerS(t, Options{Token: "tok", Clipboard: &fakeClipboard{}, HomeDir: t.TempDir()})
	if hello := expect(t, r, "hello"); hello.String("token") != "tok" {
		t.Fatalf("hello %v", hello)
	}
	w.Send(proto.Message{"t": "req", "id": 1, "op": "ping"})
	if res := expect(t, r, "res"); res["ok"] != true {
		t.Fatalf("res %v", res)
	}
}

func TestPeerAllowed(t *testing.T) {
	tcp := func(s string) net.Addr { return net.TCPAddrFromAddrPort(netip.MustParseAddrPort(s)) }
	def := New(Options{Clipboard: &fakeClipboard{}, HomeDir: t.TempDir()})
	wide := New(Options{Clipboard: &fakeClipboard{}, HomeDir: t.TempDir(),
		AllowPeers: []netip.Prefix{netip.MustParsePrefix("192.168.0.0/16"), netip.MustParsePrefix("fd00::/8")}})
	cases := []struct {
		s    *Server
		addr net.Addr
		want bool
	}{
		{def, tcp("10.0.2.2:50000"), true},
		{def, tcp("[::ffff:10.0.2.2]:50000"), true},
		{def, tcp("10.0.2.15:50000"), false},
		{def, tcp("127.0.0.1:50000"), false},
		{def, tcp("[::1]:50000"), false},
		{def, &net.UnixAddr{Name: "x", Net: "unix"}, false},
		{wide, tcp("192.168.4.7:1"), true},
		{wide, tcp("[fd12::1]:1"), true},
		{wide, tcp("10.0.2.2:1"), false},
	}
	for _, c := range cases {
		if _, got := c.s.peerAllowed(c.addr); got != c.want {
			t.Errorf("peerAllowed(%v) with %v = %v, expected %v", c.addr, c.s.allowPeers(), got, c.want)
		}
	}
}

func TestRefusalNamesAnIPv6PeerAsA128Prefix(t *testing.T) {
	s := New(Options{Clipboard: &fakeClipboard{}, HomeDir: t.TempDir()})
	addr, ok := s.peerAllowed(net.TCPAddrFromAddrPort(netip.MustParseAddrPort("[fe80::1]:5")))
	if ok || !strings.Contains(refusal(s.allowPeers(), addr), "--allow-peer fe80::1/128 ") {
		t.Fatalf("refusal %q", refusal(s.allowPeers(), addr))
	}
}

func TestRefusalOfAPeerWithoutAnAddress(t *testing.T) {
	want := "alcove-agent serves only connections from 10.0.2.2/32 and this one has no IP address; connect over TCP"
	if got := refusal(DefaultPeers, netip.Addr{}); got != want {
		t.Fatalf("refusal %q", got)
	}
}
