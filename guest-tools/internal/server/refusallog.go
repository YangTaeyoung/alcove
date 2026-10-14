package server

import (
	"fmt"
	"log"
	"net"
	"sync"
	"time"
)

// refusalLogInterval is the least time between two log lines of one refusal
// reason.
const refusalLogInterval = time.Minute

// refusalLog writes refused connections to a log, each reason at most once
// per refusalLogInterval, with the count of the refusals it left out. It
// keeps one entry per reason.
type refusalLog struct {
	mu      sync.Mutex
	now     func() time.Time
	entries map[refusalReason]*refusalEntry
}

type refusalEntry struct {
	written time.Time
	skipped int
}

// setClock makes the log read the time from now.
func (r *refusalLog) setClock(now func() time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.now = now
}

// write logs the refusal of the connection from remote with sentence, unless
// a refusal for the same reason was written less than refusalLogInterval ago.
func (r *refusalLog) write(lg *log.Logger, reason refusalReason, remote net.Addr, sentence string) {
	r.mu.Lock()
	now := time.Now
	if r.now != nil {
		now = r.now
	}
	t := now()
	if r.entries == nil {
		r.entries = map[refusalReason]*refusalEntry{}
	}
	e := r.entries[reason]
	if e != nil && t.Sub(e.written) < refusalLogInterval {
		e.skipped++
		r.mu.Unlock()
		return
	}
	skipped := 0
	if e != nil {
		skipped = e.skipped
	} else {
		e = &refusalEntry{}
		r.entries[reason] = e
	}
	e.written, e.skipped = t, 0
	r.mu.Unlock()
	line := fmt.Sprintf("refused the connection from %s: %s", remote, sentence)
	if skipped > 0 {
		line += fmt.Sprintf(" (%d more refused for this reason since the last line)", skipped)
	}
	lg.Print(line)
}
