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
}

func (e *Exchange) bodyBytes() int64 { return int64(len(e.ReqBody) + len(e.ResBody)) }

// capBuf keeps the first max bytes written to it and counts the rest.
type capBuf struct {
	mu  sync.Mutex
	max int
	off bool
	buf []byte
	n   int64
}

func newCapBuf(keep bool) *capBuf { return &capBuf{max: maxBodyBytes, off: !keep} }

func (c *capBuf) Write(p []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.n += int64(len(p))
	if !c.off {
		if room := c.max - len(c.buf); room > 0 {
			if room > len(p) {
				room = len(p)
			}
			c.buf = append(c.buf, p[:room]...)
		}
	}
	return len(p), nil
}

func (c *capBuf) count() int64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.n
}

func (c *capBuf) snapshot() (data []byte, total int64, truncated bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]byte(nil), c.buf...), c.n, !c.off && c.n > int64(len(c.buf))
}

// Store keeps the newest exchanges.
type Store struct {
	mu    sync.Mutex
	max   int
	items []*Exchange
	next  int64

	// budget caps the body bytes held by all rows; used is what they hold now.
	budget int64
	used   int64
}

func newStore(max int) *Store { return &Store{max: max, next: 1, budget: defaultBodyBudget} }

func (s *Store) add(e *Exchange) int64 {
	if u, err := url.Parse(e.URL); err == nil && e.Host == "" {
		e.Host = u.Host
		e.Path = u.RequestURI()
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	e.ID = s.next
	s.next++
	s.items = append(s.items, e)
	s.used += e.bodyBytes()
	if len(s.items) > s.max {
		cut := len(s.items) - s.max
		for _, old := range s.items[:cut] {
			s.used -= old.bodyBytes()
		}
		s.items = append([]*Exchange(nil), s.items[cut:]...)
	}
	for _, old := range s.items {
		if s.used <= s.budget {
			break
		}
		if size := old.bodyBytes(); size > 0 {
			s.used -= size
			old.ReqBody, old.ResBody = nil, nil
			old.BodyDropped = true
		}
	}
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
