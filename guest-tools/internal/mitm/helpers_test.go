package mitm

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"
)

type testEnv struct {
	t      *testing.T
	ca     *CA
	proxy  *Proxy
	addr   string
	client *http.Client
}

// newEnv starts a proxy on loopback whose upstream trust includes the given
// test servers, and a client that trusts the proxy CA.
func newEnv(t *testing.T, upstreams ...*httptest.Server) *testEnv {
	t.Helper()
	ca, err := LoadOrCreateCA(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	p := NewProxy(ca)
	pool := x509.NewCertPool()
	for _, s := range upstreams {
		if s.TLS != nil {
			pool.AddCert(s.Certificate())
		}
	}
	p.UpstreamRoots = pool
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		_ = p.Serve(l)
	}()
	t.Cleanup(func() {
		p.Close()
		<-done
	})
	env := &testEnv{t: t, ca: ca, proxy: p, addr: l.Addr().String()}
	env.client = env.newClient(true)
	return env
}

func (e *testEnv) newClient(trustCA bool) *http.Client {
	proxyURL, _ := url.Parse("http://" + e.addr)
	tr := &http.Transport{Proxy: http.ProxyURL(proxyURL), ForceAttemptHTTP2: true}
	if trustCA {
		pool := x509.NewCertPool()
		pool.AddCert(e.ca.Certificate())
		tr.TLSClientConfig = &tls.Config{RootCAs: pool}
	}
	e.t.Cleanup(tr.CloseIdleConnections)
	return &http.Client{Transport: tr, Timeout: 30 * time.Second}
}

func (e *testEnv) call(op string, params map[string]any) map[string]any {
	e.t.Helper()
	res, err := e.proxy.Handle(op, params)
	if err != nil {
		e.t.Fatalf("%s: %v", op, err)
	}
	raw, _ := json.Marshal(res)
	out := map[string]any{}
	_ = json.Unmarshal(raw, &out)
	return out
}

func (e *testEnv) exchanges(params map[string]any) []map[string]any {
	e.t.Helper()
	res := e.call("list", params)
	var out []map[string]any
	for _, x := range res["exchanges"].([]any) {
		out = append(out, x.(map[string]any))
	}
	return out
}

// waitExchange polls list until an exchange satisfying pred appears.
func (e *testEnv) waitExchange(pred func(map[string]any) bool) map[string]any {
	e.t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		for _, x := range e.exchanges(nil) {
			if pred(x) {
				return x
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	e.t.Fatalf("no matching exchange; have %v", e.exchanges(nil))
	return nil
}

func idOf(x map[string]any) int { return int(x["id"].(float64)) }
