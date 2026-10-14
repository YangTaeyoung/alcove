package mitm

import (
	"sort"
	"sync/atomic"
	"time"
)

const maxPending = 200

// pendingEntry is a request in flight or an open tunnel.
type pendingEntry struct {
	time   time.Time
	kind   string
	method string
	url    string
	rule   atomic.Int64
	req    func() int64
	res    func() int64
	// switched is set when the request became a WebSocket; the entry then
	// reads as a tunnel.
	switched atomic.Bool
}

// beginPending lists e until the returned function is called.
func (p *Proxy) beginPending(e *pendingEntry) func() {
	p.pmu.Lock()
	p.pend[e] = struct{}{}
	p.pmu.Unlock()
	return func() {
		p.pmu.Lock()
		delete(p.pend, e)
		p.pmu.Unlock()
	}
}

// pendingRows describes the unfinished entries, oldest first.
func (p *Proxy) pendingRows() []map[string]any {
	p.pmu.Lock()
	entries := make([]*pendingEntry, 0, len(p.pend))
	for e := range p.pend {
		entries = append(entries, e)
	}
	p.pmu.Unlock()
	sort.Slice(entries, func(i, j int) bool { return entries[i].time.Before(entries[j].time) })
	if len(entries) > maxPending {
		entries = entries[:maxPending]
	}
	rows := make([]map[string]any, 0, len(entries))
	for _, e := range entries {
		kind := e.kind
		if e.switched.Load() {
			kind = "tunnel"
		}
		row := map[string]any{
			"time": e.time.UTC().Format(time.RFC3339Nano), "kind": kind, "method": e.method, "url": e.url,
			"ms": time.Since(e.time).Milliseconds(), "reqBytes": e.req(), "resBytes": e.res(),
		}
		if r := e.rule.Load(); r != 0 {
			row["rule"] = r
		}
		rows = append(rows, row)
	}
	return rows
}
