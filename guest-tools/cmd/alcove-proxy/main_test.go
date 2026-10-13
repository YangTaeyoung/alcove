package main

import (
	"net"
	"testing"
)

func TestLoopbackOnlyAcceptsTheIPv4Literal(t *testing.T) {
	for addr, want := range map[string]bool{
		"127.0.0.1:0":    true,
		"127.0.0.1:8080": true,
		"localhost:0":    false,
		"[::1]:0":        false,
		"0.0.0.0:0":      false,
		":0":             false,
		"192.168.1.5:0":  false,
		"127.0.0.1":      false,
	} {
		if got := loopbackHost(addr); got != want {
			t.Errorf("loopbackHost(%q) = %v, want %v", addr, got, want)
		}
	}
	if loopbackAddr(&net.TCPAddr{IP: net.ParseIP("0.0.0.0")}) || !loopbackAddr(&net.TCPAddr{IP: net.ParseIP("127.0.0.1")}) {
		t.Error("loopbackAddr misjudged the listener address")
	}
}
