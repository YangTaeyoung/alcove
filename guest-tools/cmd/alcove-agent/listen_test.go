package main

import (
	"errors"
	"fmt"
	"net"
	"strings"
	"testing"
	"time"
)

func TestListenTriesAgainWithAPauseThatDoublesUpTo5Seconds(t *testing.T) {
	failures := 8
	var pauses []time.Duration
	var lines []string
	want, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer want.Close()
	got := listenUntilBound("0.0.0.0:7645",
		func(string) (net.Listener, error) {
			if failures > 0 {
				failures--
				return nil, errors.New("Only one usage of each socket address is normally permitted.")
			}
			return want, nil
		},
		func(format string, args ...any) { lines = append(lines, fmt.Sprintf(format, args...)) },
		func(d time.Duration) { pauses = append(pauses, d) })
	if got != want {
		t.Fatalf("listener %v", got)
	}
	s := time.Second
	if fmt.Sprint(pauses) != fmt.Sprint([]time.Duration{s, 2 * s, 4 * s, 5 * s, 5 * s, 5 * s, 5 * s, 5 * s}) {
		t.Fatalf("pauses %v", pauses)
	}
	if len(lines) != 8 || lines[0] != "listen on 0.0.0.0:7645 failed (Only one usage of each socket address is normally permitted.); trying again in 1 s" ||
		!strings.HasSuffix(lines[7], "; trying again in 5 s") {
		t.Fatalf("lines %q", lines)
	}
}

func TestListenBindsAPortThatIsFree(t *testing.T) {
	l := listenUntilBound("127.0.0.1:0", listenExclusive, t.Logf, func(time.Duration) { t.Fatal("paused") })
	l.Close()
}
