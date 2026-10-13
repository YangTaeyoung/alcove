package mitm

import (
	"encoding/json"
	"strings"
	"sync"
)

type ruleMatch struct {
	Host   string
	Path   string
	Method string
}

type ruleAction struct {
	Status    int
	HasStatus bool
	Headers   map[string]string
	Body      string
	HasBody   bool
	DelayMs   int
	Drop      bool
}

func (a ruleAction) synthesizes() bool { return a.HasStatus || a.HasBody }

type rule struct {
	id        int
	match     ruleMatch
	action    ruleAction
	hasTimes  bool
	hits      int
	remaining int
}

type ruleSet struct {
	mu     sync.Mutex
	nextID int
	rules  []*rule
}

func newRuleSet() *ruleSet { return &ruleSet{nextID: 1} }

func (s *ruleSet) add(m ruleMatch, a ruleAction, times int, hasTimes bool) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	r := &rule{id: s.nextID, match: m, action: a, hasTimes: hasTimes, remaining: times}
	s.nextID++
	s.rules = append(s.rules, r)
	return r.id
}

// pick returns the first rule that fits and still has uses left, and counts the
// use.
func (s *ruleSet) pick(host, path, method string) (ruleAction, int, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, r := range s.rules {
		if r.hasTimes && r.remaining <= 0 {
			continue
		}
		if !r.match.fits(host, path, method) {
			continue
		}
		if r.hasTimes {
			r.remaining--
		}
		r.hits++
		return r.action, r.id, true
	}
	return ruleAction{}, 0, false
}

func (s *ruleSet) remove(id int) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i, r := range s.rules {
		if r.id == id {
			s.rules = append(s.rules[:i:i], s.rules[i+1:]...)
			return true
		}
	}
	return false
}

func (s *ruleSet) clear() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.rules = nil
}

func (s *ruleSet) list() []map[string]any {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]map[string]any, 0, len(s.rules))
	for _, r := range s.rules {
		match := map[string]any{}
		if r.match.Host != "" {
			match["host"] = r.match.Host
		}
		if r.match.Path != "" {
			match["path"] = r.match.Path
		}
		if r.match.Method != "" {
			match["method"] = r.match.Method
		}
		action := map[string]any{}
		if r.action.HasStatus {
			action["status"] = r.action.Status
		}
		if len(r.action.Headers) > 0 {
			action["headers"] = r.action.Headers
		}
		if r.action.HasBody {
			action["body"] = r.action.Body
		}
		if r.action.DelayMs > 0 {
			action["delayMs"] = r.action.DelayMs
		}
		if r.action.Drop {
			action["drop"] = true
		}
		row := map[string]any{"id": r.id, "match": match, "action": action, "hits": r.hits}
		if r.hasTimes {
			row["remaining"] = r.remaining
		}
		out = append(out, row)
	}
	return out
}

func (m ruleMatch) fits(host, path, method string) bool {
	if m.Host != "" && !globMatch(strings.ToLower(m.Host), strings.ToLower(host)) {
		return false
	}
	if m.Path != "" && !globMatch(m.Path, path) {
		return false
	}
	if m.Method != "" && !strings.EqualFold(m.Method, method) {
		return false
	}
	return true
}

// globMatch reports whether s matches pattern, where '*' matches any run of
// characters including '/'.
func globMatch(pattern, s string) bool {
	p, i := 0, 0
	star, mark := -1, 0
	for i < len(s) {
		switch {
		case p < len(pattern) && pattern[p] == '*':
			star, mark = p, i
			p++
		case p < len(pattern) && pattern[p] == s[i]:
			p++
			i++
		case star >= 0:
			p = star + 1
			mark++
			i = mark
		default:
			return false
		}
	}
	for p < len(pattern) && pattern[p] == '*' {
		p++
	}
	return p == len(pattern)
}

func defaultContentType(body string) string {
	if json.Valid([]byte(body)) {
		return "application/json"
	}
	return "text/plain; charset=utf-8"
}
