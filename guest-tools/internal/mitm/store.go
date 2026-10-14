package mitm

import (
	"net/url"
	"strings"
	"sync"
	"time"
)

const (
	maxBodyBytes = 2 << 20
	maxExchanges = 2000

	defaultBodyBudget = 256 << 20
	maxHeaderBytes    = 64 << 10
)

// Exchange is one captured request/response pair, tunnel or TLS failure.
type Exchange struct {
	ID       int64
	Time     time.Time
	Kind     string
	Method   string
	URL      string
	Host     string
	Path     string
	Status   int
	Ms       int64
	ReqBytes int64
	ResBytes int64
	Rule     int
	Error    string

	ReqHeaders   [][2]string
	ResHeaders   [][2]string
	ReqTrailers  [][2]string
	ResTrailers  [][2]string
	ReqBody      []byte
	ResBody      []byte
	ReqTruncated bool
	ResTruncated bool
	BodyDropped  bool
	// HeadersTruncated is set when header or trailer pairs beyond
	// maxHeaderBytes were left out.
	HeadersTruncated bool

	// held is the budget reserved for ReqBody and ResBody while in flight.
	held int64
}

func (e *Exchange) bodyBytes() int64 { return int64(len(e.ReqBody) + len(e.ResBody)) }

// headerBytes is the size of the names and values of all header and trailer
// lists of e.
func (e *Exchange) headerBytes() int64 {
	var n int64
	for _, list := range [][][2]string{e.ReqHeaders, e.ReqTrailers, e.ResHeaders, e.ResTrailers} {
		for _, kv := range list {
			n += int64(len(kv[0]) + len(kv[1]))
		}
	}
	return n
}

// capHeaders goes through the header and trailer pairs of e, in the order
// request headers, request trailers, response headers, response trailers,
// keeps each pair that still fits in maxHeaderBytes, and marks e when pairs
// were left out.
func capHeaders(e *Exchange) {
	if e.headerBytes() <= maxHeaderBytes {
		return
	}
	room := int64(maxHeaderBytes)
	keep := func(list [][2]string) [][2]string {
		var out [][2]string
		for _, kv := range list {
			size := int64(len(kv[0]) + len(kv[1]))
			if size > room {
				continue
			}
			room -= size
			out = append(out, kv)
		}
		return out
	}
	e.ReqHeaders, e.ReqTrailers = keep(e.ReqHeaders), keep(e.ReqTrailers)
	e.ResHeaders, e.ResTrailers = keep(e.ResHeaders), keep(e.ResTrailers)
	e.HeadersTruncated = true
}

// capBuf keeps the first max bytes written to it and counts the rest. The
// kept bytes are reserved in the store's budget while the exchange is in
// flight; when the budget grants less than asked, nothing more is kept.
type capBuf struct {
	store *Store
	mu    sync.Mutex
	max   int
	off   bool
	buf   []byte
	n     int64
}

func (s *Store) newCapBuf(keep bool) *capBuf { return &capBuf{store: s, max: maxBodyBytes, off: !keep} }

func (c *capBuf) Write(p []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.n += int64(len(p))
	if !c.off {
		if room := c.max - len(c.buf); room > 0 {
			if room > len(p) {
				room = len(p)
			}
			granted := int(c.store.reserve(int64(room)))
			c.buf = append(c.buf, p[:granted]...)
			if granted < room {
				c.max = len(c.buf)
			}
		}
	}
	return len(p), nil
}

// stopKeeping drops the kept bytes and their reservation; later writes are
// only counted.
func (c *capBuf) stopKeeping() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.off = true
	c.store.release(int64(len(c.buf)))
	c.buf = nil
}

func (c *capBuf) count() int64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.n
}

// snapshot hands over the kept bytes, whose reservation the store releases
// when the exchange is added.
func (c *capBuf) snapshot() (data []byte, total int64, truncated bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	data, c.buf = c.buf, nil
	return data, c.n, !c.off && c.n > int64(len(data))
}

// Store keeps the newest exchanges.
type Store struct {
	mu    sync.Mutex
	max   int
	items []*Exchange
	next  int64

	// budget caps the bytes held by the bodies and headers of all rows and by
	// the bodies of exchanges in flight; used is what the rows hold, inflight
	// what the exchanges in flight hold.
	budget   int64
	used     int64
	inflight int64
}

func newStore(max int) *Store { return &Store{max: max, next: 1, budget: defaultBodyBudget} }

// reserve grants up to n bytes of the budget to an exchange in flight,
// dropping the bodies of the oldest rows to make room, and returns the
// granted size.
func (s *Store) reserve(n int64) int64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.dropBodies(n)
	if free := s.budget - s.used - s.inflight; n > free {
		n = max(free, 0)
	}
	s.inflight += n
	return n
}

func (s *Store) release(n int64) {
	s.mu.Lock()
	s.inflight -= n
	s.mu.Unlock()
}

// dropBodies drops the bodies of the oldest rows until extra more bytes fit
// in the budget or no row has a body. Called with s.mu held.
func (s *Store) dropBodies(extra int64) {
	for _, old := range s.items {
		if s.used+s.inflight+extra <= s.budget {
			return
		}
		if size := old.bodyBytes(); size > 0 {
			s.used -= size
			old.ReqBody, old.ResBody = nil, nil
			old.BodyDropped = true
		}
	}
}

// add stores e and releases the reservation of its bodies.
func (s *Store) add(e *Exchange) int64 {
	if u, err := url.Parse(e.URL); err == nil && e.Host == "" {
		e.Host = u.Host
		e.Path = u.RequestURI()
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	e.ID = s.next
	s.next++
	s.inflight -= e.held
	e.held = 0
	s.items = append(s.items, e)
	s.used += e.bodyBytes() + e.headerBytes()
	if len(s.items) > s.max {
		cut := len(s.items) - s.max
		for _, old := range s.items[:cut] {
			s.used -= old.bodyBytes() + old.headerBytes()
		}
		s.items = append([]*Exchange(nil), s.items[cut:]...)
	}
	s.dropBodies(0)
	return e.ID
}

// get returns a copy of the stored exchange.
func (s *Store) get(id int64) (*Exchange, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, e := range s.items {
		if e.ID == id {
			c := *e
			return &c, true
		}
	}
	return nil, false
}

func (s *Store) clear() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.items = nil
	s.used = 0
}

type listFilter struct {
	since  int64
	host   string
	path   string
	status int
	class  int
	limit  int
}

func (f listFilter) matches(e *Exchange) bool {
	switch {
	case e.ID <= f.since:
		return false
	case f.host != "" && !strings.Contains(e.Host, f.host):
		return false
	case f.path != "" && !strings.Contains(e.Path, f.path):
		return false
	case f.status != 0 && e.Status != f.status:
		return false
	case f.class != 0 && e.Status/100 != f.class:
		return false
	}
	return true
}

// list returns copies of the matching exchanges in ascending id order. With
// since set it returns the first limit rows after it; without, the newest
// limit rows.
func (s *Store) list(f listFilter) []*Exchange {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []*Exchange
	for _, e := range s.items {
		if !f.matches(e) {
			continue
		}
		c := *e
		out = append(out, &c)
		if f.since > 0 && f.limit > 0 && len(out) >= f.limit {
			break
		}
	}
	if f.since == 0 && f.limit > 0 && len(out) > f.limit {
		out = out[len(out)-f.limit:]
	}
	return out
}

var redactedHeaders = map[string]bool{
	"authorization":       true,
	"proxy-authorization": true,
	"cookie":              true,
	"set-cookie":          true,
	"x-api-key":           true,
	"api-key":             true,
}
