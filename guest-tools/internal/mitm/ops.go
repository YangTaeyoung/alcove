package mitm

import (
	"bytes"
	"compress/flate"
	"compress/gzip"
	"compress/zlib"
	"encoding/base64"
	"fmt"
	"io"
	"math"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	defaultListLimit = 50
	maxListLimit     = 500
	maxGetLength     = 200000
	maxDecodedBytes  = 64 << 20
	maxDelayMs       = 600000
)

// Handle runs one control operation.
func (p *Proxy) Handle(op string, params map[string]any) (map[string]any, error) {
	if params == nil {
		params = map[string]any{}
	}
	switch op {
	case "config":
		return p.opConfig(params)
	case "list":
		return p.opList(params)
	case "get":
		return p.opGet(params)
	case "clear":
		p.store.clear()
		return map[string]any{}, nil
	case "rule.add":
		return p.opRuleAdd(params)
	case "rule.list":
		return map[string]any{"rules": p.rules.list()}, nil
	case "rule.remove":
		id, ok, err := intParam(params, "rule")
		if err != nil {
			return nil, err
		}
		if !ok {
			return nil, fmt.Errorf("parameter 'rule' is required")
		}
		if !p.rules.remove(id) {
			return nil, fmt.Errorf("no rule with id %d; run rule.list to see the ids", id)
		}
		return map[string]any{}, nil
	case "rule.clear":
		p.rules.clear()
		return map[string]any{}, nil
	}
	return nil, fmt.Errorf("unknown op '%s'", op)
}

func intParam(params map[string]any, name string) (int, bool, error) {
	v, present := params[name]
	if !present || v == nil {
		return 0, false, nil
	}
	var f float64
	switch n := v.(type) {
	case float64:
		f = n
	case int:
		f = float64(n)
	case int64:
		f = float64(n)
	default:
		return 0, false, fmt.Errorf("parameter '%s' must be a number", name)
	}
	if f != math.Trunc(f) || math.Abs(f) > 1<<53 {
		return 0, false, fmt.Errorf("parameter '%s' must be a whole number", name)
	}
	return int(f), true, nil
}

func boolParam(params map[string]any, name string) (bool, bool, error) {
	v, present := params[name]
	if !present || v == nil {
		return false, false, nil
	}
	b, ok := v.(bool)
	if !ok {
		return false, false, fmt.Errorf("parameter '%s' must be true or false", name)
	}
	return b, true, nil
}

func stringParam(params map[string]any, name string) (string, bool, error) {
	v, present := params[name]
	if !present || v == nil {
		return "", false, nil
	}
	s, ok := v.(string)
	if !ok {
		return "", false, fmt.Errorf("parameter '%s' must be a string", name)
	}
	return s, true, nil
}

func stringsParam(params map[string]any, name string) ([]string, bool, error) {
	v, present := params[name]
	if !present || v == nil {
		return nil, false, nil
	}
	switch list := v.(type) {
	case []string:
		return list, true, nil
	case []any:
		out := make([]string, 0, len(list))
		for _, item := range list {
			s, ok := item.(string)
			if !ok {
				return nil, false, fmt.Errorf("parameter '%s' must be a list of strings", name)
			}
			out = append(out, s)
		}
		return out, true, nil
	}
	return nil, false, fmt.Errorf("parameter '%s' must be a list of strings", name)
}

func objectParam(params map[string]any, name string) (map[string]any, bool, error) {
	v, present := params[name]
	if !present || v == nil {
		return nil, false, nil
	}
	m, ok := v.(map[string]any)
	if !ok {
		return nil, false, fmt.Errorf("parameter '%s' must be an object", name)
	}
	return m, true, nil
}

func (p *Proxy) opConfig(params map[string]any) (map[string]any, error) {
	hosts, hasHosts, err := stringsParam(params, "hosts")
	if err != nil {
		return nil, err
	}
	secrets, hasSecrets, err := boolParam(params, "secrets")
	if err != nil {
		return nil, err
	}
	bodies, hasBodies, err := boolParam(params, "bodies")
	if err != nil {
		return nil, err
	}
	p.cfgMu.Lock()
	defer p.cfgMu.Unlock()
	if hasHosts {
		p.cfg.hosts = hosts
	}
	if hasSecrets {
		p.cfg.secrets = secrets
	}
	if hasBodies {
		p.cfg.bodies = bodies
	}
	return map[string]any{}, nil
}

func (p *Proxy) opList(params map[string]any) (map[string]any, error) {
	var f listFilter
	since, _, err := intParam(params, "since")
	if err != nil {
		return nil, err
	}
	f.since = int64(since)
	if f.host, _, err = stringParam(params, "host"); err != nil {
		return nil, err
	}
	if f.path, _, err = stringParam(params, "path"); err != nil {
		return nil, err
	}
	switch st := params["status"].(type) {
	case nil:
	case string:
		if len(st) == 3 && st[0] >= '1' && st[0] <= '5' && strings.EqualFold(st[1:], "xx") {
			f.class = int(st[0] - '0')
		} else {
			return nil, fmt.Errorf("parameter 'status' must be a number or a class like '4xx'")
		}
	default:
		n, _, err := intParam(params, "status")
		if err != nil {
			return nil, fmt.Errorf("parameter 'status' must be a number or a class like '4xx'")
		}
		f.status = n
	}
	limit, has, err := intParam(params, "limit")
	if err != nil {
		return nil, err
	}
	f.limit = defaultListLimit
	if has {
		f.limit = limit
	}
	if f.limit < 1 {
		f.limit = 1
	}
	if f.limit > maxListLimit {
		f.limit = maxListLimit
	}
	rows := p.store.list(f)
	out := make([]map[string]any, 0, len(rows))
	next := f.since
	for _, e := range rows {
		row := map[string]any{
			"id": e.ID, "time": e.Time.UTC().Format(time.RFC3339Nano), "kind": e.Kind,
			"method": e.Method, "url": e.URL, "status": e.Status, "ms": e.Ms,
			"reqBytes": e.ReqBytes, "resBytes": e.ResBytes,
		}
		if e.Rule != 0 {
			row["rule"] = e.Rule
		}
		if e.Error != "" {
			row["error"] = e.Error
		}
		if e.BodyDropped {
			row["bodyDropped"] = true
		}
		out = append(out, row)
		next = e.ID
	}
	return map[string]any{"exchanges": out, "next": next, "pending": p.pendingRows()}, nil
}

func (p *Proxy) opGet(params map[string]any) (map[string]any, error) {
	id, has, err := intParam(params, "exchange")
	if err != nil {
		return nil, err
	}
	if !has {
		return nil, fmt.Errorf("parameter 'exchange' is required")
	}
	part, _, err := stringParam(params, "part")
	if err != nil {
		return nil, err
	}
	if part != "request" && part != "response" {
		return nil, fmt.Errorf("parameter 'part' must be 'request' or 'response'")
	}
	offset, _, err := intParam(params, "offset")
	if err != nil {
		return nil, err
	}
	length, hasLen, err := intParam(params, "length")
	if err != nil {
		return nil, err
	}
	if !hasLen || length > maxGetLength {
		length = maxGetLength
	}
	if offset < 0 || length < 0 {
		return nil, fmt.Errorf("parameters 'offset' and 'length' must not be negative")
	}
	e, ok := p.store.get(int64(id))
	if !ok {
		return nil, fmt.Errorf("no exchange with id %d; the store keeps the newest %d exchanges and 'clear' removes them all", id, maxExchanges)
	}
	headers, body, truncated := e.ReqHeaders, e.ReqBody, e.ReqTruncated
	if part == "response" {
		headers, body, truncated = e.ResHeaders, e.ResBody, e.ResTruncated
	}
	decoded, encoding, undecodable := decodeBody(headers, body, truncated)
	if headers == nil {
		headers = [][2]string{}
	}
	res := map[string]any{"headers": headers, "total": len(decoded), "bodyTruncated": truncated}
	if encoding != "" {
		res["encoding"] = encoding
	}
	if e.BodyDropped {
		res["bodyDropped"] = true
	}
	view := decoded
	if truncated && !undecodable {
		view = trimPartialRune(decoded)
	}
	if offset > len(decoded) {
		offset = len(decoded)
	}
	end := offset + length
	if end > len(decoded) {
		end = len(decoded)
	}
	if !undecodable && utf8.Valid(view) {
		if end > len(view) {
			end = len(view)
		}
		start := offset
		for start < end && !utf8.RuneStart(view[start]) {
			start++
		}
		for end < len(view) && end > start && !utf8.RuneStart(view[end]) {
			end--
		}
		if start > end {
			start = end
		}
		if start == end && start < len(view) {
			_, size := utf8.DecodeRune(view[start:])
			end = start + size
		}
		res["body"] = string(view[start:end])
	} else {
		res["body"] = base64.StdEncoding.EncodeToString(decoded[offset:end])
		res["base64"] = true
	}
	return res, nil
}

// trimPartialRune drops an incomplete UTF-8 character at the end of b.
func trimPartialRune(b []byte) []byte {
	if utf8.Valid(b) {
		return b
	}
	for k := 1; k <= 3 && k <= len(b); k++ {
		if utf8.Valid(b[:len(b)-k]) {
			return b[:len(b)-k]
		}
	}
	return b
}

// decodeBody removes a gzip or deflate content encoding. For an encoding it
// cannot remove it returns the raw bytes, the encoding name and true.
func decodeBody(headers [][2]string, body []byte, truncated bool) ([]byte, string, bool) {
	var enc string
	for _, kv := range headers {
		if strings.EqualFold(kv[0], "Content-Encoding") {
			enc = strings.ToLower(strings.TrimSpace(kv[1]))
		}
	}
	if enc == "" || enc == "identity" || len(body) == 0 {
		return body, "", false
	}
	var r io.Reader
	switch enc {
	case "gzip", "x-gzip":
		gz, err := gzip.NewReader(bytes.NewReader(body))
		if err != nil {
			return body, enc, true
		}
		r, enc = gz, "gzip"
	case "deflate":
		if zr, err := zlib.NewReader(bytes.NewReader(body)); err == nil {
			r = zr
		} else {
			r = flate.NewReader(bytes.NewReader(body))
		}
	default:
		return body, enc, true
	}
	out, err := io.ReadAll(io.LimitReader(r, maxDecodedBytes))
	if err != nil && !(truncated && len(out) > 0) {
		return body, enc, true
	}
	return out, enc, false
}

func (p *Proxy) opRuleAdd(params map[string]any) (map[string]any, error) {
	matchObj, _, err := objectParam(params, "match")
	if err != nil {
		return nil, err
	}
	actionObj, hasAction, err := objectParam(params, "action")
	if err != nil {
		return nil, err
	}
	if !hasAction {
		return nil, fmt.Errorf("parameter 'action' is required")
	}
	var m ruleMatch
	if m.Host, _, err = stringParam(matchObj, "host"); err != nil {
		return nil, fmt.Errorf("match: %w", err)
	}
	if m.Path, _, err = stringParam(matchObj, "path"); err != nil {
		return nil, fmt.Errorf("match: %w", err)
	}
	if m.Method, _, err = stringParam(matchObj, "method"); err != nil {
		return nil, fmt.Errorf("match: %w", err)
	}
	var a ruleAction
	if a.Status, a.HasStatus, err = intParam(actionObj, "status"); err != nil {
		return nil, fmt.Errorf("action: %w", err)
	}
	if a.HasStatus && (a.Status < 200 || a.Status > 599) {
		return nil, fmt.Errorf("action: 'status' must be between 200 and 599")
	}
	if a.Body, a.HasBody, err = stringParam(actionObj, "body"); err != nil {
		return nil, fmt.Errorf("action: %w", err)
	}
	if a.DelayMs, _, err = intParam(actionObj, "delayMs"); err != nil {
		return nil, fmt.Errorf("action: %w", err)
	}
	if a.DelayMs < 0 || a.DelayMs > maxDelayMs {
		return nil, fmt.Errorf("action: 'delayMs' must be between 0 and %d", maxDelayMs)
	}
	if a.Drop, _, err = boolParam(actionObj, "drop"); err != nil {
		return nil, fmt.Errorf("action: %w", err)
	}
	hdrs, hasHdrs, err := objectParam(actionObj, "headers")
	if err != nil {
		return nil, fmt.Errorf("action: %w", err)
	}
	if hasHdrs {
		a.Headers = map[string]string{}
		for k, v := range hdrs {
			s, ok := v.(string)
			if !ok {
				return nil, fmt.Errorf("action: header '%s' must be a string", k)
			}
			a.Headers[http.CanonicalHeaderKey(k)] = s
		}
	}
	times, hasTimes, err := intParam(actionObj, "times")
	if err != nil {
		return nil, fmt.Errorf("action: %w", err)
	}
	if hasTimes && times < 1 {
		return nil, fmt.Errorf("action: 'times' must be at least 1")
	}
	if !a.synthesizes() && a.DelayMs == 0 && !a.Drop {
		return nil, fmt.Errorf("the action needs at least one of status, body, delayMs or drop")
	}
	return map[string]any{"rule": p.rules.add(m, a, times, hasTimes)}, nil
}
