package mitm

import (
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

const websocketRefusal = "websocket interception is not supported; exclude this host with the hosts filter"

var hopByHop = []string{
	"Connection", "Proxy-Connection", "Keep-Alive", "Proxy-Authenticate",
	"Proxy-Authorization", "Te", "Trailer", "Transfer-Encoding", "Upgrade",
}

func removeHopByHop(h http.Header) {
	for _, v := range h.Values("Connection") {
		for _, name := range strings.Split(v, ",") {
			if name = strings.TrimSpace(name); name != "" {
				h.Del(name)
			}
		}
	}
	for _, name := range hopByHop {
		h.Del(name)
	}
}

func headerPairs(h http.Header) [][2]string {
	names := make([]string, 0, len(h))
	for name := range h {
		names = append(names, name)
	}
	sort.Strings(names)
	var out [][2]string
	for _, name := range names {
		for _, v := range h[name] {
			out = append(out, [2]string{name, v})
		}
	}
	return out
}

func redactPairs(pairs [][2]string) [][2]string {
	out := make([][2]string, len(pairs))
	for i, kv := range pairs {
		out[i] = kv
		if redactedHeaders[strings.ToLower(kv[0])] {
			out[i][1] = fmt.Sprintf("<redacted %d chars>", utf8.RuneCountInString(kv[1]))
		}
	}
	return out
}

// record stores ex, redacting secret headers unless the capture keeps them.
func (p *Proxy) record(ex *Exchange) {
	if !p.config().secrets {
		ex.ReqHeaders = redactPairs(ex.ReqHeaders)
		ex.ResHeaders = redactPairs(ex.ResHeaders)
	}
	p.store.add(ex)
}

// handler serves requests for one client connection. With a scheme and
// authority the request path is resolved against them (intercepted TLS);
// with neither the request must carry an absolute URL (plain proxying).
func (p *Proxy) handler(scheme, authority string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p.serveRequest(w, r, scheme, authority)
	})
}

func (p *Proxy) serveRequest(w http.ResponseWriter, r *http.Request, scheme, authority string) {
	start := time.Now()
	var target string
	if authority != "" {
		target = scheme + "://" + authority + r.URL.RequestURI()
	} else {
		if !r.URL.IsAbs() || r.URL.Host == "" {
			http.Error(w, "alcove-proxy is an HTTP proxy; send the request with an absolute URL", http.StatusBadRequest)
			return
		}
		if r.URL.Scheme != "http" {
			http.Error(w, "alcove-proxy forwards http:// URLs here and https:// through CONNECT", http.StatusBadRequest)
			return
		}
		target = r.URL.String()
	}
	host := r.URL.Hostname()
	if authority != "" {
		host, _ = splitAuthority(authority, "")
	}

	cfg := p.config()
	reqCap := newCapBuf(cfg.bodies)
	resCap := newCapBuf(cfg.bodies)
	ex := &Exchange{
		Time:       start,
		Kind:       "http",
		Method:     r.Method,
		URL:        target,
		ReqHeaders: headerPairs(r.Header),
	}
	pe := &pendingEntry{time: start, kind: "http", method: r.Method, url: target, req: reqCap.count, res: resCap.count}
	endPending := p.beginPending(pe)
	defer func() {
		defer endPending()
		ex.Ms = time.Since(start).Milliseconds()
		ex.ReqBody, ex.ReqBytes, ex.ReqTruncated = reqCap.snapshot()
		ex.ResBody, ex.ResBytes, ex.ResTruncated = resCap.snapshot()
		p.record(ex)
	}()

	reqBody := r.Body
	r.Body = struct {
		io.Reader
		io.Closer
	}{io.TeeReader(reqBody, reqCap), reqBody}

	var act ruleAction
	if a, id, ok := p.rules.pick(host, r.URL.Path, r.Method); ok {
		act, ex.Rule = a, id
		pe.rule.Store(int64(id))
		if act.DelayMs > 0 {
			t := time.NewTimer(time.Duration(act.DelayMs) * time.Millisecond)
			select {
			case <-t.C:
			case <-r.Context().Done():
				t.Stop()
				ex.Error = "the client gave up during the rule delay"
				return
			}
		}
		if act.Drop {
			panic(http.ErrAbortHandler)
		}
		if act.synthesizes() {
			p.synthesize(w, ex, resCap, act)
			return
		}
	}

	if strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
		respondText(w, ex, resCap, http.StatusNotImplemented, websocketRefusal)
		return
	}
	p.forward(w, r, target, ex, resCap)
}

func respondText(w http.ResponseWriter, ex *Exchange, resCap *capBuf, status int, text string) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	ex.Status = status
	ex.ResHeaders = headerPairs(w.Header())
	w.WriteHeader(status)
	_, _ = io.WriteString(io.MultiWriter(w, resCap), text)
}

func (p *Proxy) synthesize(w http.ResponseWriter, ex *Exchange, resCap *capBuf, act ruleAction) {
	status := http.StatusOK
	if act.HasStatus {
		status = act.Status
	}
	h := w.Header()
	for k, v := range act.Headers {
		h.Set(k, v)
	}
	if h.Get("Content-Type") == "" && act.Body != "" {
		h.Set("Content-Type", defaultContentType(act.Body))
	}
	h.Set("Content-Length", fmt.Sprint(len(act.Body)))
	ex.Status = status
	ex.ResHeaders = headerPairs(h)
	w.WriteHeader(status)
	_, _ = io.WriteString(io.MultiWriter(w, resCap), act.Body)
}

func (p *Proxy) forward(w http.ResponseWriter, r *http.Request, target string, ex *Exchange, resCap *capBuf) {
	var body io.Reader = r.Body
	if r.ContentLength == 0 {
		body = nil
	}
	out, err := http.NewRequestWithContext(r.Context(), r.Method, target, body)
	if err != nil {
		ex.Error = "the request cannot be forwarded: " + err.Error()
		respondText(w, ex, resCap, http.StatusBadRequest, ex.Error)
		return
	}
	out.ContentLength = r.ContentLength
	out.Header = r.Header.Clone()
	removeHopByHop(out.Header)
	out.Host = r.Host

	resp, err := p.upstream().RoundTrip(out)
	if err != nil {
		ex.Error = "the upstream request failed: " + err.Error()
		respondText(w, ex, resCap, http.StatusBadGateway,
			"alcove-proxy could not complete the upstream request ("+err.Error()+"); check the address and that the Mac can reach it")
		return
	}
	defer resp.Body.Close()
	removeHopByHop(resp.Header)
	h := w.Header()
	for k, vs := range resp.Header {
		h[k] = vs
	}
	ex.Status = resp.StatusCode
	ex.ResHeaders = headerPairs(resp.Header)
	w.WriteHeader(resp.StatusCode)
	rc := http.NewResponseController(w)
	_ = rc.Flush()

	buf := make([]byte, 32*1024)
	for {
		n, rerr := resp.Body.Read(buf)
		if n > 0 {
			if _, werr := w.Write(buf[:n]); werr != nil {
				ex.Error = "the client closed the connection before the response ended"
				return
			}
			resCap.Write(buf[:n])
			_ = rc.Flush()
		}
		if rerr != nil {
			if rerr != io.EOF {
				ex.Error = "the upstream response ended early: " + rerr.Error()
				panic(http.ErrAbortHandler)
			}
			return
		}
	}
}
