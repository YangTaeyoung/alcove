package mitm

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"fmt"
	"io"
	"math/rand"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

func (e *testEnv) get(id int, part string, extra map[string]any) map[string]any {
	e.t.Helper()
	p := map[string]any{"exchange": id, "part": part}
	for k, v := range extra {
		p[k] = v
	}
	return e.call("get", p)
}

func TestHTTPSExchangeIsCaptured(t *testing.T) {
	up := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		w.Header().Set("X-Seen", "yes")
		w.WriteHeader(201)
		fmt.Fprintf(w, "echo:%s", b)
	}))
	defer up.Close()
	env := newEnv(t, up)
	resp, err := env.client.Post(up.URL+"/items?q=1", "text/plain", strings.NewReader("ping"))
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 201 || string(body) != "echo:ping" || resp.Header.Get("X-Seen") != "yes" {
		t.Fatalf("got %d %q %v", resp.StatusCode, body, resp.Header)
	}
	x := env.waitExchange(func(x map[string]any) bool { return x["kind"] == "http" })
	if x["method"] != "POST" || x["url"] != up.URL+"/items?q=1" || int(x["status"].(float64)) != 201 {
		t.Fatalf("exchange %v", x)
	}
	if int(x["reqBytes"].(float64)) != 4 || int(x["resBytes"].(float64)) != 9 {
		t.Fatalf("byte counts %v", x)
	}
	id := idOf(x)
	if got := env.get(id, "request", nil)["body"]; got != "ping" {
		t.Fatalf("request body %v", got)
	}
	res := env.get(id, "response", nil)
	if res["body"] != "echo:ping" || res["total"].(float64) != 9 {
		t.Fatalf("response %v", res)
	}
}

func TestPlainHTTPIsCaptured(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "plain") }))
	defer up.Close()
	env := newEnv(t)
	resp, err := env.client.Get(up.URL + "/a/b")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if string(body) != "plain" {
		t.Fatalf("body %q", body)
	}
	x := env.waitExchange(func(x map[string]any) bool { return x["kind"] == "http" })
	if x["url"] != up.URL+"/a/b" || x["method"] != "GET" {
		t.Fatalf("exchange %v", x)
	}
	if env.get(idOf(x), "response", nil)["body"] != "plain" {
		t.Fatal("response body not captured")
	}
}

func TestHTTP2ClientWorks(t *testing.T) {
	up := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "upstream-proto-%d", r.ProtoMajor)
	}))
	up.EnableHTTP2 = true
	up.StartTLS()
	defer up.Close()
	env := newEnv(t, up)
	resp, err := env.client.Get(up.URL + "/")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.ProtoMajor != 2 {
		t.Fatalf("client protocol HTTP/%d, want 2", resp.ProtoMajor)
	}
	if string(body) != "upstream-proto-2" {
		t.Fatalf("body %q", body)
	}
	env.waitExchange(func(x map[string]any) bool { return x["kind"] == "http" && x["status"].(float64) == 200 })
}

func TestSecretsAreRedactedByDefault(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.SetCookie(w, &http.Cookie{Name: "s", Value: "abc"})
		if r.Header.Get("Authorization") != "Bearer abc123" {
			t.Errorf("upstream got Authorization %q", r.Header.Get("Authorization"))
		}
	}))
	defer up.Close()
	env := newEnv(t)
	req, _ := http.NewRequest("GET", up.URL, nil)
	req.Header.Set("Authorization", "Bearer abc123")
	req.Header.Set("X-Api-Key", "k")
	req.Header.Set("X-Other", "visible")
	resp, err := env.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	x := env.waitExchange(func(x map[string]any) bool { return x["kind"] == "http" })
	headers := headerMap(env.get(idOf(x), "request", nil))
	if headers["Authorization"] != "<redacted 13 chars>" || headers["X-Api-Key"] != "<redacted 1 chars>" || headers["X-Other"] != "visible" {
		t.Fatalf("request headers %v", headers)
	}
	if !strings.HasPrefix(headerMap(env.get(idOf(x), "response", nil))["Set-Cookie"], "<redacted ") {
		t.Fatal("Set-Cookie was stored in clear")
	}
}

func TestSecretsKeptWhenAsked(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer up.Close()
	env := newEnv(t)
	env.call("config", map[string]any{"secrets": true})
	req, _ := http.NewRequest("GET", up.URL, nil)
	req.Header.Set("Authorization", "Bearer abc123")
	resp, err := env.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	x := env.waitExchange(func(x map[string]any) bool { return x["kind"] == "http" })
	if got := headerMap(env.get(idOf(x), "request", nil))["Authorization"]; got != "Bearer abc123" {
		t.Fatalf("Authorization %q", got)
	}
}

func headerMap(res map[string]any) map[string]string {
	out := map[string]string{}
	for _, h := range res["headers"].([]any) {
		pair := h.([]any)
		out[pair[0].(string)] = pair[1].(string)
	}
	return out
}

func fillDeterministic(seed int64, n int) io.Reader {
	return io.LimitReader(rand.New(rand.NewSource(seed)), int64(n))
}

func TestLargeBodiesAreForwardedWholeAndCappedInCapture(t *testing.T) {
	const size = 8 << 20
	wantReq := sha256.New()
	io.Copy(wantReq, fillDeterministic(1, size))
	wantRes := sha256.New()
	io.Copy(wantRes, fillDeterministic(2, size))
	up := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := sha256.New()
		n, _ := io.Copy(h, r.Body)
		w.Header().Set("X-Req-Sha", fmt.Sprintf("%x", h.Sum(nil)))
		w.Header().Set("X-Req-Len", fmt.Sprint(n))
		io.Copy(w, fillDeterministic(2, size))
	}))
	defer up.Close()
	env := newEnv(t, up)
	resp, err := env.client.Post(up.URL+"/big", "application/octet-stream", fillDeterministic(1, size))
	if err != nil {
		t.Fatal(err)
	}
	h := sha256.New()
	n, _ := io.Copy(h, resp.Body)
	resp.Body.Close()
	if n != size || fmt.Sprintf("%x", h.Sum(nil)) != fmt.Sprintf("%x", wantRes.Sum(nil)) {
		t.Fatalf("response of %d bytes differs", n)
	}
	if resp.Header.Get("X-Req-Sha") != fmt.Sprintf("%x", wantReq.Sum(nil)) || resp.Header.Get("X-Req-Len") != fmt.Sprint(size) {
		t.Fatalf("upstream saw a different request: %v", resp.Header)
	}
	x := env.waitExchange(func(x map[string]any) bool { return x["kind"] == "http" })
	if int(x["reqBytes"].(float64)) != size || int(x["resBytes"].(float64)) != size {
		t.Fatalf("byte counts %v", x)
	}
	for _, part := range []string{"request", "response"} {
		res := env.get(idOf(x), part, map[string]any{"length": 10})
		if res["bodyTruncated"] != true || int(res["total"].(float64)) != maxBodyBytes {
			t.Fatalf("%s: %v", part, res)
		}
	}
}

func TestBodiesOffKeepsNoBody(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "secret-ish") }))
	defer up.Close()
	env := newEnv(t)
	env.call("config", map[string]any{"bodies": false})
	resp, err := env.client.Post(up.URL, "text/plain", strings.NewReader("abc"))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	x := env.waitExchange(func(x map[string]any) bool { return x["kind"] == "http" })
	res := env.get(idOf(x), "response", nil)
	if res["body"] != "" || res["total"].(float64) != 0 || int(x["resBytes"].(float64)) != 10 {
		t.Fatalf("%v %v", x, res)
	}
}

func TestGzipBodyIsDecodedForGet(t *testing.T) {
	var gz bytes.Buffer
	zw := gzip.NewWriter(&gz)
	zw.Write([]byte(`{"hello":"world"}`))
	zw.Close()
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Encoding", "gzip")
		w.Write(gz.Bytes())
	}))
	defer up.Close()
	env := newEnv(t)
	req, _ := http.NewRequest("GET", up.URL, nil)
	req.Header.Set("Accept-Encoding", "gzip")
	resp, err := env.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if !bytes.Equal(raw, gz.Bytes()) {
		t.Fatal("the proxy altered the compressed bytes")
	}
	x := env.waitExchange(func(x map[string]any) bool { return x["kind"] == "http" })
	res := env.get(idOf(x), "response", nil)
	if res["body"] != `{"hello":"world"}` || res["encoding"] != "gzip" || int(res["total"].(float64)) != 17 {
		t.Fatalf("response %v", res)
	}
	page := env.get(idOf(x), "response", map[string]any{"offset": 2, "length": 5})
	if page["body"] != "hello" {
		t.Fatalf("page %v", page)
	}
}

func TestUnsupportedEncodingIsReturnedAsBase64(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Encoding", "br")
		w.Write([]byte("brotli-bytes"))
	}))
	defer up.Close()
	env := newEnv(t)
	req, _ := http.NewRequest("GET", up.URL, nil)
	req.Header.Set("Accept-Encoding", "br")
	resp, err := env.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	x := env.waitExchange(func(x map[string]any) bool { return x["kind"] == "http" })
	res := env.get(idOf(x), "response", nil)
	dec, _ := base64.StdEncoding.DecodeString(res["body"].(string))
	if res["base64"] != true || res["encoding"] != "br" || string(dec) != "brotli-bytes" {
		t.Fatalf("response %v", res)
	}
}

func TestBinaryBodyIsBase64(t *testing.T) {
	payload := []byte{0xff, 0xfe, 0x00, 0x01}
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write(payload) }))
	defer up.Close()
	env := newEnv(t)
	resp, err := env.client.Get(up.URL)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	x := env.waitExchange(func(x map[string]any) bool { return x["kind"] == "http" })
	res := env.get(idOf(x), "response", nil)
	dec, _ := base64.StdEncoding.DecodeString(res["body"].(string))
	if res["base64"] != true || !bytes.Equal(dec, payload) || res["total"].(float64) != 4 {
		t.Fatalf("response %v", res)
	}
}

func TestHostsFilterTunnelsOthers(t *testing.T) {
	up := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "direct") }))
	defer up.Close()
	env := newEnv(t, up)
	env.call("config", map[string]any{"hosts": []any{"*.example.test"}})
	upRoots := x509.NewCertPool()
	upRoots.AddCert(up.Certificate())
	direct := &http.Client{Transport: &http.Transport{
		Proxy:           http.ProxyURL(mustURL("http://" + env.addr)),
		TLSClientConfig: &tls.Config{RootCAs: upRoots},
	}}
	t.Cleanup(direct.CloseIdleConnections)
	resp, err := direct.Get(up.URL + "/")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if string(body) != "direct" {
		t.Fatalf("body %q", body)
	}
	if !resp.TLS.PeerCertificates[0].Equal(up.Certificate()) {
		t.Fatal("the client did not see the upstream's own certificate")
	}
	direct.CloseIdleConnections()
	x := env.waitExchange(func(x map[string]any) bool { return x["kind"] == "tunnel" })
	if x["resBytes"].(float64) == 0 || x["reqBytes"].(float64) == 0 {
		t.Fatalf("tunnel byte counts %v", x)
	}
	for _, e := range env.exchanges(nil) {
		if e["kind"] == "http" {
			t.Fatalf("a tunnelled host produced an http row: %v", e)
		}
	}
}

func TestClientRejectingCAIsRecorded(t *testing.T) {
	up := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer up.Close()
	env := newEnv(t, up)
	distrustful := env.newClient(false)
	if resp, err := distrustful.Get(up.URL + "/"); err == nil {
		resp.Body.Close()
		t.Fatal("expected a certificate error")
	}
	x := env.waitExchange(func(x map[string]any) bool { return x["kind"] == "tlsError" })
	if !strings.HasSuffix(x["error"].(string), "; the program does not trust the Alcove CA: install the CA where it looks for trusted certificates, or exclude this host with hosts") || !strings.Contains(x["url"].(string), "127.0.0.1") {
		t.Fatalf("exchange %v", x)
	}
}

func TestUpstreamFailureAnswersBadGateway(t *testing.T) {
	up := httptest.NewServer(http.NotFoundHandler())
	addr := up.URL
	up.Close()
	env := newEnv(t)
	resp, err := env.client.Get(addr + "/")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 502 || !strings.Contains(string(body), "upstream") {
		t.Fatalf("got %d %q", resp.StatusCode, body)
	}
	x := env.waitExchange(func(x map[string]any) bool { return x["status"] == float64(502) })
	if x["error"] == nil {
		t.Fatalf("exchange %v", x)
	}
}

func TestHopByHopHeadersAreNotForwarded(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Hop") != "" || r.Header.Get("Proxy-Authorization") != "" || r.Header.Get("X-Keep") != "k" {
			t.Errorf("upstream headers %v", r.Header)
		}
		w.Header().Set("Connection", "X-Resp-Hop")
		w.Header().Set("X-Resp-Hop", "v")
		w.Header().Set("X-Resp-Keep", "v")
	}))
	defer up.Close()
	env := newEnv(t)
	req, _ := http.NewRequest("GET", up.URL, nil)
	req.Header.Set("Connection", "X-Hop")
	req.Header.Set("X-Hop", "1")
	req.Header.Set("X-Keep", "k")
	resp, err := env.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.Header.Get("X-Resp-Hop") != "" || resp.Header.Get("X-Resp-Keep") != "v" {
		t.Fatalf("response headers %v", resp.Header)
	}
}

func TestListFilters(t *testing.T) {
	env := newEnv(t)
	add := func(url string, status int) {
		env.proxy.store.add(&Exchange{Kind: "http", Method: "GET", URL: url, Status: status})
	}
	add("https://api.one.com/v1/chat", 200)
	add("https://api.one.com/v1/models", 404)
	add("https://other.org/health", 503)
	add("https://api.one.com/v2/chat", 500)
	count := func(p map[string]any) int { return len(env.exchanges(p)) }
	if n := count(nil); n != 4 {
		t.Fatalf("all: %d", n)
	}
	if n := count(map[string]any{"host": "one.com"}); n != 3 {
		t.Fatalf("host: %d", n)
	}
	if n := count(map[string]any{"path": "chat"}); n != 2 {
		t.Fatalf("path: %d", n)
	}
	if n := count(map[string]any{"status": 404}); n != 1 {
		t.Fatalf("status number: %d", n)
	}
	if n := count(map[string]any{"status": "5xx"}); n != 2 {
		t.Fatalf("status class: %d", n)
	}
	if n := count(map[string]any{"since": 2}); n != 2 {
		t.Fatalf("since: %d", n)
	}
	res := env.call("list", map[string]any{"limit": 2})
	newest := res["exchanges"].([]any)
	if len(newest) != 2 || idOf(newest[0].(map[string]any)) != 3 || idOf(newest[1].(map[string]any)) != 4 || res["next"].(float64) != 4 {
		t.Fatalf("without since the newest rows are returned in ascending order: %v", res)
	}
	res = env.call("list", map[string]any{"since": 0.0 + 1, "limit": 2})
	oldest := res["exchanges"].([]any)
	if len(oldest) != 2 || idOf(oldest[0].(map[string]any)) != 2 || res["next"].(float64) != 3 {
		t.Fatalf("with since the first rows after it are returned: %v", res)
	}
	res = env.call("list", map[string]any{"since": res["next"]})
	if len(res["exchanges"].([]any)) != 1 || res["next"].(float64) != 4 {
		t.Fatalf("page two: %v", res)
	}
	env.call("clear", nil)
	if n := count(nil); n != 0 {
		t.Fatalf("after clear: %d", n)
	}
}

func TestStoreDropsOldest(t *testing.T) {
	s := newStore(3)
	for i := 0; i < 5; i++ {
		s.add(&Exchange{URL: "http://h/"})
	}
	got := s.list(listFilter{})
	if len(got) != 3 || got[0].ID != 3 || got[2].ID != 5 {
		t.Fatalf("kept ids: %v", ids(got))
	}
	if _, ok := s.get(1); ok {
		t.Fatal("oldest exchange is still readable")
	}
}

func ids(es []*Exchange) []int64 {
	var out []int64
	for _, e := range es {
		out = append(out, e.ID)
	}
	return out
}

func TestParameterTypeErrorsNameTheParameter(t *testing.T) {
	env := newEnv(t)
	cases := []struct {
		op     string
		params map[string]any
		want   string
	}{
		{"config", map[string]any{"secrets": "yes"}, "secrets"},
		{"config", map[string]any{"hosts": "a"}, "hosts"},
		{"list", map[string]any{"limit": "ten"}, "limit"},
		{"list", map[string]any{"status": true}, "status"},
		{"get", map[string]any{"exchange": "1", "part": "request"}, "exchange"},
		{"get", map[string]any{"exchange": 1, "part": "both"}, "part"},
		{"get", map[string]any{"exchange": 99, "part": "request"}, "99"},
		{"rule.remove", map[string]any{"rule": "x"}, "rule"},
	}
	for _, c := range cases {
		_, err := env.proxy.Handle(c.op, c.params)
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s %v: error %v should mention %q", c.op, c.params, err, c.want)
		}
	}
	if _, err := env.proxy.Handle("nope", nil); err == nil || err.Error() != unknownOpText("nope") {
		t.Errorf("unknown op error %v", err)
	}
}

func unknownOpText(op string) string {
	return "unknown op '" + op + "'; use config, list, get, clear, rule.add, rule.list, rule.remove or rule.clear"
}

func mustURL(s string) *url.URL {
	u, err := url.Parse(s)
	if err != nil {
		panic(err)
	}
	return u
}

func TestNoGoroutinesRemainAfterClose(t *testing.T) {
	time.Sleep(100 * time.Millisecond)
	before := runtime.NumGoroutine()
	func() {
		up := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "x") }))
		defer up.Close()
		ca, _ := LoadOrCreateCA(t.TempDir())
		p := NewProxy(ca)
		pool := x509.NewCertPool()
		pool.AddCert(up.Certificate())
		p.UpstreamRoots = pool
		l, _ := net.Listen("tcp", "127.0.0.1:0")
		done := make(chan struct{})
		go func() { defer close(done); _ = p.Serve(l) }()
		pc := x509.NewCertPool()
		pc.AddCert(ca.Certificate())
		tr := &http.Transport{Proxy: http.ProxyURL(mustURL("http://" + l.Addr().String())), TLSClientConfig: &tls.Config{RootCAs: pc}}
		resp, err := (&http.Client{Transport: tr}).Get(up.URL)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		p.Close()
		<-done
		tr.CloseIdleConnections()
	}()
	deadline := time.Now().Add(5 * time.Second)
	for runtime.NumGoroutine() > before && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if after := runtime.NumGoroutine(); after > before {
		t.Fatalf("goroutines: %d before, %d after Close", before, after)
	}
}

func TestPendingRequestIsListedUntilItFinishes(t *testing.T) {
	release := make(chan struct{})
	reached := make(chan struct{})
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(reached)
		<-release
		io.WriteString(w, "late")
	}))
	defer up.Close()
	env := newEnv(t)
	env.call("rule.add", map[string]any{"match": map[string]any{"path": "/held"}, "action": map[string]any{"delayMs": 1}})
	errc := make(chan error, 1)
	go func() {
		resp, err := env.client.Post(up.URL+"/held", "text/plain", strings.NewReader("abcd"))
		if err == nil {
			io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
		}
		errc <- err
	}()
	<-reached
	res := env.call("list", nil)
	pending := res["pending"].([]any)
	if len(pending) != 1 || len(res["exchanges"].([]any)) != 0 {
		t.Fatalf("while held: %v", res)
	}
	row := pending[0].(map[string]any)
	if row["method"] != "POST" || row["url"] != up.URL+"/held" || row["kind"] != "http" || row["reqBytes"].(float64) != 4 || row["rule"].(float64) != 1 {
		t.Fatalf("pending row %v", row)
	}
	close(release)
	if err := <-errc; err != nil {
		t.Fatal(err)
	}
	env.waitExchange(func(x map[string]any) bool { return x["status"] == float64(200) })
	deadline := time.Now().Add(5 * time.Second)
	for len(env.call("list", nil)["pending"].([]any)) != 0 {
		if time.Now().After(deadline) {
			t.Fatal("pending row never cleared")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestGetPagesOnCharacterBoundaries(t *testing.T) {
	env := newEnv(t)
	text := "aé€😀z"
	env.proxy.store.add(&Exchange{Kind: "http", URL: "http://h/", ResBody: []byte(text)})
	var got strings.Builder
	offset := 0
	for offset < len(text) {
		res := env.call("get", map[string]any{"exchange": 1, "part": "response", "offset": offset, "length": 3})
		if res["base64"] == true {
			t.Fatalf("page at %d is base64: %v", offset, res)
		}
		page := res["body"].(string)
		if page == "" {
			t.Fatalf("empty page at %d", offset)
		}
		got.WriteString(page)
		offset += len(page)
	}
	if got.String() != text {
		t.Fatalf("pages joined to %q", got.String())
	}
}

func TestTruncatedCaptureEndingMidCharacterIsShownAsText(t *testing.T) {
	env := newEnv(t)
	cut := []byte("ab€")[:4]
	env.proxy.store.add(&Exchange{Kind: "http", URL: "http://h/", ResBody: cut, ResTruncated: true})
	res := env.call("get", map[string]any{"exchange": 1, "part": "response"})
	if res["body"] != "ab" || res["base64"] != nil {
		t.Fatalf("got %v", res)
	}
}

// holdingUpstream accepts connections and keeps its side open.
func holdingUpstream(t *testing.T) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var held []net.Conn
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			mu.Lock()
			held = append(held, c)
			mu.Unlock()
		}
	}()
	t.Cleanup(func() {
		l.Close()
		mu.Lock()
		for _, c := range held {
			c.Close()
		}
		mu.Unlock()
	})
	return l.Addr().String()
}

func openTunnel(t *testing.T, env *testEnv, target string) net.Conn {
	t.Helper()
	c, err := net.Dial("tcp", env.addr)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	fmt.Fprintf(c, "CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", target, target)
	line, err := bufio.NewReader(c).ReadString('\n')
	if err != nil || !strings.Contains(line, "200") {
		t.Fatalf("CONNECT reply %q %v", line, err)
	}
	return c
}

func TestCloseReturnsWhileATunnelIsOpen(t *testing.T) {
	addr := holdingUpstream(t)
	env := newEnv(t)
	env.call("config", map[string]any{"hosts": []any{"nomatch.test"}})
	openTunnel(t, env, addr)
	deadline := time.Now().Add(5 * time.Second)
	for len(env.call("list", nil)["pending"].([]any)) == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	done := make(chan struct{})
	go func() { env.proxy.Close(); close(done) }()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("Close did not return within 1s while a tunnel was open")
	}
}

func TestTunnelEndsWhenTheClientHangsUp(t *testing.T) {
	old := tunnelIdleAfterHalfClose
	tunnelIdleAfterHalfClose = 200 * time.Millisecond
	t.Cleanup(func() { tunnelIdleAfterHalfClose = old })
	addr := holdingUpstream(t)
	env := newEnv(t)
	env.call("config", map[string]any{"hosts": []any{"nomatch.test"}})
	c := openTunnel(t, env, addr)
	c.Close()
	x := env.waitExchange(func(x map[string]any) bool { return x["kind"] == "tunnel" })
	if x["url"] != addr {
		t.Fatalf("tunnel row %v", x)
	}
}

func TestPlainHTTPToUnselectedHostIsForwardedUntouched(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		fmt.Fprintf(w, "real:%s", b)
	}))
	defer up.Close()
	env := newEnv(t)
	env.call("config", map[string]any{"hosts": []any{"nomatch.test"}})
	env.call("rule.add", map[string]any{"action": map[string]any{"status": 418}})
	resp, err := env.client.Post(up.URL+"/p", "text/plain", strings.NewReader("abc"))
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 || string(body) != "real:abc" {
		t.Fatalf("got %d %q: the rule must not apply", resp.StatusCode, body)
	}
	x := env.waitExchange(func(x map[string]any) bool { return x["kind"] == "tunnel" })
	if x["url"] != up.URL+"/p" || x["reqBytes"].(float64) != 3 || x["resBytes"].(float64) != 8 || x["rule"] != nil {
		t.Fatalf("row %v", x)
	}
	res := env.get(idOf(x), "response", nil)
	if res["body"] != "" || res["total"].(float64) != 0 || len(res["headers"].([]any)) != 0 {
		t.Fatalf("an untouched request kept capture data: %v", res)
	}
}

func TestBodyBudgetReleasesOldestBodies(t *testing.T) {
	env := newEnv(t)
	env.proxy.store.budget = 10
	for i := 0; i < 3; i++ {
		env.proxy.store.add(&Exchange{Kind: "http", URL: "http://h/", ReqBody: []byte("abc"), ResBody: []byte("def")})
	}
	rows := env.exchanges(nil)
	if rows[0]["bodyDropped"] != true || rows[1]["bodyDropped"] != true || rows[2]["bodyDropped"] != nil {
		t.Fatalf("rows %v", rows)
	}
	dropped := env.get(1, "response", nil)
	if dropped["bodyDropped"] != true || dropped["body"] != "" || dropped["total"].(float64) != 0 {
		t.Fatalf("dropped get %v", dropped)
	}
	if kept := env.get(3, "response", nil); kept["body"] != "def" || kept["bodyDropped"] != nil {
		t.Fatalf("kept get %v", kept)
	}
	if env.proxy.store.used > 10 {
		t.Fatalf("used %d over budget", env.proxy.store.used)
	}
}

func TestSilentClientConnectionIsClosed(t *testing.T) {
	old := firstBytesTimeout
	firstBytesTimeout = 200 * time.Millisecond
	t.Cleanup(func() { firstBytesTimeout = old })
	env := newEnv(t)
	c, err := net.Dial("tcp", env.addr)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, err := c.Read(make([]byte, 1)); err != io.EOF {
		t.Fatalf("expected the proxy to close a silent connection, got %v", err)
	}
}

func TestCloseDuringFirstUpstreamRequestsIsRaceFree(t *testing.T) {
	reached := make(chan struct{}, 1)
	release := make(chan struct{})
	up := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case reached <- struct{}{}:
		default:
		}
		select {
		case <-release:
		case <-r.Context().Done():
		}
	}))
	up.EnableHTTP2 = true
	up.StartTLS()
	defer up.Close()
	defer close(release)
	env := newEnv(t, up)
	const clients = 16
	var wg sync.WaitGroup
	for i := range clients {
		c := env.newProtoClient(i%2 == 0)
		wg.Add(1)
		go func() {
			defer wg.Done()
			if resp, err := c.Get(fmt.Sprintf("%s/first-%d", up.URL, i)); err == nil {
				io.Copy(io.Discard, resp.Body)
				resp.Body.Close()
			}
		}()
	}
	select {
	case <-reached:
	case <-time.After(10 * time.Second):
		t.Fatal("no request reached the upstream")
	}
	env.proxy.Close()
	wg.Wait()
}
