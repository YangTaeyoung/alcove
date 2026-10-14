package main

import (
	"context"
	"net"
	"time"
)

// listenFirstPause and listenMaxPause bound the pause between two attempts of
// listenUntilBound.
const (
	listenFirstPause = time.Second
	listenMaxPause   = 30 * time.Second
)

// listenUntilBound calls listen for address until it succeeds. After a
// failure it logs the error and pauses, first for listenFirstPause, then for
// twice the previous pause, at most listenMaxPause.
func listenUntilBound(address string, listen func(string) (net.Listener, error), logf func(string, ...any), pause func(time.Duration)) net.Listener {
	wait := listenFirstPause
	for {
		l, err := listen(address)
		if err == nil {
			return l
		}
		logf("listen on %s failed (%v); trying again in %d s", address, err, int(wait/time.Second))
		pause(wait)
		wait *= 2
		if wait > listenMaxPause {
			wait = listenMaxPause
		}
	}
}

// listenExclusive listens on TCP address with exclusiveControl applied to the
// socket before it is bound.
func listenExclusive(address string) (net.Listener, error) {
	lc := net.ListenConfig{Control: exclusiveControl}
	return lc.Listen(context.Background(), "tcp", address)
}
