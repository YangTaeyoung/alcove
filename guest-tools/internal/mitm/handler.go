package mitm

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"net/http/httptrace"
	"net/textproto"
	"net/url"
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	badTargetRefusal = "request target must start with '/'"
	clientClosed     = "the client closed the connection"
	incompleteBody   = "the request body was not received completely"
	maxDrainBytes    = 64 << 20
)

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

// wantsTrailers reports whether the Te header lists "trailers".
func wantsTrailers(h http.Header) bool {
	for _, v := range h.Values("Te") {
		for _, tok := range strings.Split(v, ",") {
			if strings.EqualFold(strings.TrimSpace(tok), "trailers") {
				return true
			}
		}
	}
	return false
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
	if pairs == nil {
		return nil
	}
	out := make([][2]string, len(pairs))
	for i, kv := range pairs {
		out[i] = kv
		if redactedHeaders[strings.ToLower(kv[0])] {
			out[i][1] = fmt.Sprintf("<redacted %d chars>", utf8.RuneCountInString(kv[1]))
		}
	}
	return out
}

// record stores ex, redacting secret headers unless the capture keeps them
// and keeping at most maxHeaderBytes of headers.
func (p *Proxy) record(ex *Exchange) {
	if !p.config().secrets {
		ex.ReqHeaders = redactPairs(ex.ReqHeaders)
		ex.ResHeaders = redactPairs(ex.ResHeaders)
		ex.ReqTrailers = redactPairs(ex.ReqTrailers)
		ex.ResTrailers = redactPairs(ex.ResTrailers)
	}
	capHeaders(ex)
	p.store.add(ex)
}

// handler serves requests for one client connection. With a scheme and
// authority the request path is resolved against them (intercepted TLS);
// with neither the request must carry an absolute URL (plain proxying).
// release ends the serving of the connection after a handler took it over.
func (p *Proxy) handler(scheme, authority string, release func()) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p.serveRequest(w, r, scheme, authority, release)
	})
}

// isWebSocketUpgrade reports whether h asks to upgrade to a WebSocket.
func isWebSocketUpgrade(h http.Header) bool {
	if !strings.EqualFold(h.Get("Upgrade"), "websocket") {
		return false
	}
	for _, v := range h.Values("Connection") {
		for _, tok := range strings.Split(v, ",") {
			if strings.EqualFold(strings.TrimSpace(tok), "upgrade") {
				return true
			}
		}
	}
	return false
}

// switchScope carries what a switch to the WebSocket protocol changes.
type switchScope struct {
	reqCap  *capBuf
	pe      *pendingEntry
	release func()
	// taken is set once the client connection was hijacked.
	taken bool
}

// drainBody reads the rest of the request body through the capture tee, for at
// most drainTimeout. When the body does not arrive completely the exchange
// records an incomplete body, the read deadline stays expired and an HTTP/1
// connection closes after the answer.
func drainBody(w http.ResponseWriter, r *http.Request, ex *Exchange) {
	rc := http.NewResponseController(w)
	_ = rc.SetReadDeadline(time.Now().Add(drainTimeout))
	_, err := io.Copy(io.Discard, io.LimitReader(r.Body, maxDrainBytes))
	if err == nil {
		_ = rc.SetReadDeadline(time.Time{})
		return
	}
	if ex.Error == "" {
		ex.Error = incompleteBody
	}
	if r.ProtoMajor == 1 {
		w.Header().Set("Connection", "close")
	}
}

// readAhead reads up to maxBodyBytes of an HTTP/1 request body through the
// capture tee, for at most drainTimeout, and replaces r.Body with one that
// returns those bytes before the rest. It reports false after answering 408
// when the body did not arrive in time.
func readAhead(w http.ResponseWriter, r *http.Request, ex *Exchange, resCap *capBuf) bool {
	if r.ProtoMajor != 1 || r.ContentLength == 0 {
		return true
	}
	rc := http.NewResponseController(w)
	_ = rc.SetReadDeadline(time.Now().Add(drainTimeout))
	head, err := io.ReadAll(io.LimitReader(r.Body, maxBodyBytes))
	if err != nil {
		ex.Error = incompleteBody
		w.Header().Set("Connection", "close")
		respondText(w, ex, resCap, http.StatusRequestTimeout,
			fmt.Sprintf("alcove-proxy did not receive the whole request body within %s; send it again", drainTimeout))
		return false
	}
	_ = rc.SetReadDeadline(time.Time{})
	body := r.Body
	r.Body = struct {
		io.Reader
		io.Closer
	}{io.MultiReader(bytes.NewReader(head), body), body}
	return true
}

// waitDelay waits for a rule delay. It reports false, with the reason in ex,
// when the client gives up or the proxy closes first.
func (p *Proxy) waitDelay(r *http.Request, delayMs int, ex *Exchange) bool {
	t := time.NewTimer(time.Duration(delayMs) * time.Millisecond)
	defer t.Stop()
	select {
	case <-t.C:
		return true
	case <-r.Context().Done():
		ex.Error = "the client gave up during the rule delay"
	case <-p.done:
		ex.Error = "the proxy stopped during the rule delay"
	}
	return false
}

func (p *Proxy) serveRequest(w http.ResponseWriter, r *http.Request, scheme, authority string, release func()) {
	start := time.Now()
	u := &url.URL{Scheme: scheme, Host: authority, Path: r.URL.Path, RawPath: r.URL.RawPath, RawQuery: r.URL.RawQuery}
	if authority == "" {
		if !r.URL.IsAbs() || r.URL.Host == "" {
			http.Error(w, "alcove-proxy is an HTTP proxy; send the request with an absolute URL", http.StatusBadRequest)
			return
		}
		if r.URL.Scheme != "http" {
			http.Error(w, "alcove-proxy forwards http:// URLs here and https:// through CONNECT", http.StatusBadRequest)
			return
		}
		u.Scheme, u.Host = "http", r.URL.Host
	}
	target := u.String()
	host := u.Hostname()

	untouched := authority == "" && !p.intercepts(host)
	cfg := p.config()
	reqCap := p.store.newCapBuf(cfg.bodies && !untouched)
	resCap := p.store.newCapBuf(cfg.bodies && !untouched)
	ex := &Exchange{
		Time:       start,
		Kind:       "http",
		Method:     r.Method,
		URL:        target,
		ReqHeaders: headerPairs(r.Header),
	}
	if untouched {
		ex.Kind, ex.ReqHeaders = "tunnel", nil
	}
	pe := &pendingEntry{time: start, kind: ex.Kind, method: r.Method, url: target, req: reqCap.count, res: resCap.count}
	endPending := p.beginPending(pe)
	sw := &switchScope{reqCap: reqCap, pe: pe, release: release}
	defer func() {
		defer endPending()
		ex.Ms = time.Since(start).Milliseconds()
		ex.ReqBody, ex.ReqBytes, ex.ReqTruncated = reqCap.snapshot()
		ex.ResBody, ex.ResBytes, ex.ResTruncated = resCap.snapshot()
		ex.held = ex.bodyBytes()
		if !untouched {
			ex.ReqTrailers = headerPairs(r.Trailer)
		}
		p.record(ex)
		if sw.taken {
			sw.release()
		}
	}()

	reqBody := r.Body
	r.Body = struct {
		io.Reader
		io.Closer
	}{io.TeeReader(reqBody, reqCap), reqBody}

	if untouched {
		p.forward(w, r, u, ex, resCap, sw)
		ex.ResHeaders, ex.ResTrailers = nil, nil
		return
	}

	if authority != "" && !strings.HasPrefix(r.RequestURI, "/") {
		drainBody(w, r, ex)
		ex.Error = badTargetRefusal
		respondText(w, ex, resCap, http.StatusBadRequest, badTargetRefusal)
		return
	}

	if act, id, ok := p.rules.pick(host, r.URL.Path, r.Method); ok {
		ex.Rule = id
		pe.rule.Store(int64(id))
		answers := act.Drop || act.synthesizes()
		if answers {
			drainBody(w, r, ex)
		} else if act.DelayMs > 0 && !readAhead(w, r, ex, resCap) {
			return
		}
		if act.DelayMs > 0 && !p.waitDelay(r, act.DelayMs, ex) {
			panic(http.ErrAbortHandler)
		}
		if act.Drop {
			panic(http.ErrAbortHandler)
		}
		if act.synthesizes() {
			p.synthesize(w, ex, resCap, act)
			return
		}
	}

	p.forward(w, r, u, ex, resCap, sw)
}

// relayInformational sends an upstream 1xx answer other than 100 Continue to
// the client. The server sends its own 100 Continue when the body is read.
func relayInformational(w http.ResponseWriter, code int, header http.Header) {
	if code == http.StatusContinue {
		return
	}
	header = header.Clone()
	removeHopByHop(header)
	h := w.Header()
	for k, vs := range header {
		h[k] = vs
	}
	w.WriteHeader(code)
	for k := range header {
		delete(h, k)
	}
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

// forward sends the request upstream and relays the answer. A WebSocket
// upgrade request keeps its Upgrade and Connection headers; when the upstream
// switches protocols, the connections are joined by switchProtocols.
func (p *Proxy) forward(w http.ResponseWriter, r *http.Request, u *url.URL, ex *Exchange, resCap *capBuf, sw *switchScope) {
	upgrade := r.ProtoMajor == 1 && isWebSocketUpgrade(r.Header)
	var body io.Reader = r.Body
	if r.ContentLength == 0 {
		body = nil
	}
	out, err := http.NewRequestWithContext(r.Context(), r.Method, "http://forward.invalid/", body)
	if err != nil {
		ex.Error = "the request cannot be forwarded: " + err.Error()
		respondText(w, ex, resCap, http.StatusBadRequest, ex.Error)
		return
	}
	out.URL = u
	out.ContentLength = r.ContentLength
	out.Header = r.Header.Clone()
	removeHopByHop(out.Header)
	if upgrade {
		out.Header.Set("Connection", "Upgrade")
		out.Header["Upgrade"] = r.Header.Values("Upgrade")
	}
	if wantsTrailers(r.Header) {
		out.Header.Set("Te", "trailers")
	}
	if len(r.Trailer) > 0 {
		out.Trailer = r.Trailer
		out.ContentLength = -1
	}
	out.Host = r.Host
	if _, ok := r.Header["User-Agent"]; !ok {
		out.Header["User-Agent"] = []string{""}
	}
	out = out.WithContext(httptrace.WithClientTrace(out.Context(), &httptrace.ClientTrace{
		Got1xxResponse: func(code int, header textproto.MIMEHeader) error {
			relayInformational(w, code, http.Header(header))
			return nil
		},
	}))

	resp, err := p.upstream().RoundTrip(out)
	if err != nil {
		if r.Context().Err() != nil {
			ex.Error = clientClosed
			return
		}
		ex.Error = "the upstream request failed: " + err.Error()
		respondText(w, ex, resCap, http.StatusBadGateway,
			"alcove-proxy could not complete the upstream request ("+err.Error()+"); check the address and that the Mac can reach it")
		return
	}
	defer resp.Body.Close()
	if upgrade && resp.StatusCode == http.StatusSwitchingProtocols {
		p.switchProtocols(w, resp, ex, resCap, sw)
		return
	}
	removeHopByHop(resp.Header)
	h := w.Header()
	for k, vs := range resp.Header {
		h[k] = vs
	}
	for _, name := range []string{"Date", "Content-Type"} {
		if _, ok := resp.Header[name]; !ok {
			h[name] = nil
		}
	}
	if len(resp.Trailer) > 0 {
		h.Del("Content-Length")
	}
	for k := range resp.Trailer {
		h.Add("Trailer", k)
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
				ex.Error = clientClosed
				return
			}
			resCap.Write(buf[:n])
			_ = rc.Flush()
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			if r.Context().Err() != nil {
				ex.Error = clientClosed
				return
			}
			ex.Error = "the upstream response ended early: " + rerr.Error()
			panic(http.ErrAbortHandler)
		}
	}
	if len(resp.Trailer) > 0 {
		for k, vs := range resp.Trailer {
			h[http.TrailerPrefix+k] = vs
		}
		ex.ResTrailers = headerPairs(resp.Trailer)
	}
}

// drainTimeout bounds how long the rest of a request body is awaited before a
// rule answer or refusal is sent.
var drainTimeout = 30 * time.Second
