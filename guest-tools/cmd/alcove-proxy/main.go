// Command alcove-proxy is the host-side intercepting HTTP(S) proxy. It prints
// a ready line, then answers JSON-line control requests on stdin until stdin
// closes.
package main

import (
	"flag"
	"fmt"
	"net"
	"os"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/mitm"
)

func main() {
	caDir := flag.String("ca-dir", "", "directory holding ca.pem and ca.key (created when missing)")
	listen := flag.String("listen", "127.0.0.1:0", "loopback address to listen on")
	flag.Parse()
	if *caDir == "" {
		fail("--ca-dir is required; pass the directory that holds (or will hold) the proxy CA")
	}
	if !loopbackHost(*listen) {
		fail(loopbackOnly)
	}
	ca, err := mitm.LoadOrCreateCA(*caDir)
	if err != nil {
		fail(err.Error())
	}
	l, err := net.Listen("tcp", *listen)
	if err != nil {
		fail("cannot listen on " + *listen + ": " + err.Error())
	}
	if !loopbackAddr(l.Addr()) {
		l.Close()
		fail(loopbackOnly)
	}
	if err := mitm.RunControl(mitm.NewProxy(ca), l, os.Stdin, os.Stdout); err != nil {
		fail(err.Error())
	}
}

const loopbackOnly = "alcove-proxy listens on loopback only; use an address such as 127.0.0.1:0"

// loopbackHost accepts an address whose host is the literal 127.0.0.1.
func loopbackHost(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return false
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.Equal(net.IPv4(127, 0, 0, 1))
}

func loopbackAddr(a net.Addr) bool {
	t, ok := a.(*net.TCPAddr)
	return ok && t.IP.Equal(net.IPv4(127, 0, 0, 1))
}

func fail(msg string) {
	fmt.Fprintln(os.Stderr, "alcove-proxy:", msg)
	os.Exit(2)
}
