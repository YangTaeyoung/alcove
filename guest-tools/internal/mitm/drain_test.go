package mitm

import (
	"bufio"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestStalledRequestBodyDoesNotHoldTheRuleAnswer(t *testing.T) {
	old := drainTimeout
	drainTimeout = 300 * time.Millisecond
	t.Cleanup(func() { drainTimeout = old })
	env := newEnv(t)
	env.call("rule.add", map[string]any{"action": map[string]any{"status": 200, "body": "mocked"}})
	c, err := net.Dial("tcp", env.addr)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	fmt.Fprint(c, "POST http://127.0.0.1:1/x HTTP/1.1\r\nHost: 127.0.0.1:1\r\nContent-Length: 100\r\n\r\nhalf")
	c.SetReadDeadline(time.Now().Add(3 * time.Second))
	line, err := bufio.NewReader(c).ReadString('\n')
	if err != nil || !strings.Contains(line, "200") {
		t.Fatalf("reply %q %v", line, err)
	}
	x := env.waitExchange(func(x map[string]any) bool { return x["kind"] == "http" })
	if x["error"] != "the request body was not received completely" || x["reqBytes"].(float64) != 4 {
		t.Fatalf("row %v", x)
	}
	if n := len(env.call("list", nil)["pending"].([]any)); n != 0 {
		t.Fatalf("%d pending entries remain", n)
	}
}

func TestConnectionWithAStalledBodyIsClosedAfterTheAnswer(t *testing.T) {
	old := drainTimeout
	drainTimeout = 300 * time.Millisecond
	t.Cleanup(func() { drainTimeout = old })
	env := newEnv(t)
	env.call("rule.add", map[string]any{"action": map[string]any{"status": 200, "body": "mocked"}})
	c, err := net.Dial("tcp", env.addr)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	fmt.Fprint(c, "POST http://127.0.0.1:1/x HTTP/1.1\r\nHost: 127.0.0.1:1\r\nContent-Length: 100\r\n\r\nhalf")
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	got, err := io.ReadAll(c)
	if err != nil {
		t.Fatalf("the proxy kept the connection open after %q: %v", got, err)
	}
	if !strings.HasSuffix(string(got), "mocked") {
		t.Fatalf("reply %q", got)
	}
}

func TestRefusalDrainsTheRequestBody(t *testing.T) {
	up := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("the upstream was reached with %q", r.RequestURI)
	}))
	defer up.Close()
	env := newEnv(t, up)
	raw := openTunnel(t, env, up.Listener.Addr().String())
	pool := x509.NewCertPool()
	pool.AddCert(env.ca.Certificate())
	tc := tls.Client(raw, &tls.Config{RootCAs: pool, ServerName: "127.0.0.1"})
	fmt.Fprint(tc, "POST http://evil.example/x HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 5\r\n\r\nhello")
	resp, err := http.ReadResponse(bufio.NewReader(tc), nil)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 400 {
		t.Fatalf("status %d", resp.StatusCode)
	}
	x := env.waitExchange(func(x map[string]any) bool { return x["status"] == float64(400) })
	if x["reqBytes"] != float64(5) || env.get(idOf(x), "request", nil)["body"] != "hello" {
		t.Fatalf("row %v", x)
	}
}

// sendRawPost writes a POST with body through the proxy as absolute-form
// HTTP/1.1 and returns the client connection.
func sendRawPost(t *testing.T, env *testEnv, target, body string) net.Conn {
	t.Helper()
	u, err := url.Parse(target)
	if err != nil {
		t.Fatal(err)
	}
	c, err := net.Dial("tcp", env.addr)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	fmt.Fprintf(c, "POST %s HTTP/1.1\r\nHost: %s\r\nContent-Length: %d\r\n\r\n%s", target, u.Host, len(body), body)
	return c
}

// waitRuleApplied waits until a pending row names a rule.
func waitRuleApplied(t *testing.T, env *testEnv) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		for _, row := range env.call("list", nil)["pending"].([]any) {
			if row.(map[string]any)["rule"] != nil {
				return
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("no pending request reached a rule")
}

func TestClientGivingUpDuringARuleDelayIsNoticedForARequestWithABody(t *testing.T) {
	for name, action := range map[string]map[string]any{
		"forward": {"delayMs": 20000},
		"answer":  {"delayMs": 20000, "status": 200},
		"drop":    {"delayMs": 20000, "drop": true},
	} {
		t.Run(name, func(t *testing.T) {
			var hits atomic.Int32
			up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { hits.Add(1) }))
			defer up.Close()
			env := newEnv(t)
			env.call("rule.add", map[string]any{"action": action})
			c := sendRawPost(t, env, up.URL+"/x", "abc")
			waitRuleApplied(t, env)
			c.Close()
			x := env.waitExchange(func(x map[string]any) bool { return x["error"] != nil })
			if x["error"] != "the client gave up during the rule delay" || x["reqBytes"] != float64(3) {
				t.Fatalf("row %v", x)
			}
			if n := hits.Load(); n != 0 {
				t.Fatalf("the upstream got %d requests", n)
			}
		})
	}
}

func TestCloseEndsARuleDelay(t *testing.T) {
	env := newEnv(t)
	env.call("rule.add", map[string]any{"action": map[string]any{"delayMs": 12000, "status": 200}})
	sendRawPost(t, env, "http://127.0.0.1:1/x", "abc")
	waitRuleApplied(t, env)
	done := make(chan struct{})
	go func() {
		env.proxy.Close()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Close did not return within 5 s while a rule delay was running")
	}
	x := env.waitExchange(func(x map[string]any) bool { return x["error"] != nil })
	if x["error"] != "the proxy stopped during the rule delay" {
		t.Fatalf("row %v", x)
	}
}

func TestDelayedRequestForwardsTheWholeBody(t *testing.T) {
	const size = 3 << 20
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := sha256.New()
		n, _ := io.Copy(h, r.Body)
		fmt.Fprintf(w, "%d %x", n, h.Sum(nil))
	}))
	defer up.Close()
	want := sha256.New()
	io.Copy(want, fillDeterministic(3, size))
	env := newEnv(t)
	env.call("rule.add", map[string]any{"action": map[string]any{"delayMs": 1}})
	for _, n := range []int{5, size} {
		resp, err := env.client.Post(up.URL+"/up", "application/octet-stream", fillDeterministic(3, n))
		if err != nil {
			t.Fatal(err)
		}
		got, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		h := sha256.New()
		io.Copy(h, fillDeterministic(3, n))
		if string(got) != fmt.Sprintf("%d %x", n, h.Sum(nil)) {
			t.Fatalf("%d bytes: upstream read %q", n, got)
		}
	}
}
