//go:build windows

package main

import (
	"context"
	"fmt"
	"net"
	"syscall"
	"testing"
)

func TestNoSocketWithSOReuseAddrBindsThePortOfTheExclusiveListener(t *testing.T) {
	l, err := listenExclusive("0.0.0.0:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	port := l.Addr().(*net.TCPAddr).Port
	reuse := net.ListenConfig{Control: func(_, _ string, c syscall.RawConn) error {
		var serr error
		c.Control(func(fd uintptr) {
			serr = syscall.SetsockoptInt(syscall.Handle(fd), syscall.SOL_SOCKET, syscall.SO_REUSEADDR, 1)
		})
		return serr
	}}
	for _, address := range []string{"127.0.0.1", "0.0.0.0"} {
		if other, err := reuse.Listen(context.Background(), "tcp", fmt.Sprintf("%s:%d", address, port)); err == nil {
			other.Close()
			t.Fatalf("a socket with SO_REUSEADDR bound %s:%d", address, port)
		}
	}
}
