package mitm

import (
	"bufio"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// newEchoSocketUpstream starts a server that switches a WebSocket upgrade
// request to a line echo ("echo:" + line) and answers other requests and
// requests for /refuse 403. It sends the request headers it saw on seen.
func newEchoSocketUpstream(t *testing.T, tlsOn bool, seen chan<- http.Header) *httptest.Server {
	h := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case seen <- r.Header.Clone():
		default:
		}
		if !strings.EqualFold(r.Header.Get("Upgrade"), "websocket") || r.URL.Path == "/refuse" {
			http.Error(w, "upgrade required", http.StatusForbidden)
			return
		}
		conn, brw, err := http.NewResponseController(w).Hijack()
		if err != nil {
			t.Error(err)
			return
		}
		defer conn.Close()
		fmt.Fprint(brw, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: accept-1\r\n\r\n")
		brw.Flush()
		for {
			line, err := brw.ReadString('\n')
			if err != nil {
				return
			}
			fmt.Fprintf(brw, "echo:%s", line)
			brw.Flush()
		}
	})
	up := httptest.NewUnstartedServer(h)
	if tlsOn {
		up.StartTLS()
	} else {
		up.Start()
	}
	t.Cleanup(up.Close)
	return up
}

const upgradeHeaders = "Connection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: key-1\r\nSec-WebSocket-Version: 13\r\n"

// openSocket sends a WebSocket upgrade for target over conn and returns the
// handshake response and a reader positioned after it.
func openSocket(t *testing.T, conn net.Conn, target, host string) (*http.Response, *bufio.Reader) {
	t.Helper()
	fmt.Fprintf(conn, "GET %s HTTP/1.1\r\nHost: %s\r\n%s\r\n", target, host, upgradeHeaders)
	br := bufio.NewReader(conn)
	conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	resp, err := http.ReadResponse(br, nil)
	if err != nil {
		t.Fatal(err)
	}
	return resp, br
}

func TestWebSocketIsPassedThrough(t *testing.T) {
	cases := []struct {
		name    string
		tls     bool
		hosts   []any
		kept    bool
		connect func(t *testing.T, env *testEnv, up *httptest.Server) (conn net.Conn, target, host string)
	}{
		{"intercepted https", true, nil, true, func(t *testing.T, env *testEnv, up *httptest.Server) (net.Conn, string, string) {
			raw := openTunnel(t, env, up.Listener.Addr().String())
			pool := x509.NewCertPool()
			pool.AddCert(env.ca.Certificate())
			return tls.Client(raw, &tls.Config{RootCAs: pool, ServerName: "127.0.0.1"}), "/chat", up.Listener.Addr().String()
		}},
		{"plain http", false, nil, true, plainSocketConn},
		{"plain http outside hosts", false, []any{"nomatch.test"}, false, plainSocketConn},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			seen := make(chan http.Header, 1)
			up := newEchoSocketUpstream(t, c.tls, seen)
			env := newEnv(t, up)
			if c.hosts != nil {
				env.call("config", map[string]any{"hosts": c.hosts})
			}
			conn, target, host := c.connect(t, env, up)
			resp, br := openSocket(t, conn, target, host)
			if resp.StatusCode != 101 || resp.Header.Get("Sec-WebSocket-Accept") != "accept-1" ||
				!strings.EqualFold(resp.Header.Get("Upgrade"), "websocket") || !strings.EqualFold(resp.Header.Get("Connection"), "upgrade") {
				t.Fatalf("handshake %d %v", resp.StatusCode, resp.Header)
			}
			if h := <-seen; h.Get("Sec-WebSocket-Key") != "key-1" || !strings.EqualFold(h.Get("Upgrade"), "websocket") {
				t.Fatalf("the upstream saw %v", h)
			}
			pending := env.call("list", nil)["pending"].([]any)
			if len(pending) != 1 || pending[0].(map[string]any)["kind"] != "tunnel" {
				t.Fatalf("pending while open: %v", pending)
			}
			for _, msg := range []string{"ping\n", "second\n"} {
				io.WriteString(conn, msg)
				if line, err := br.ReadString('\n'); err != nil || line != "echo:"+msg {
					t.Fatalf("read %q %v", line, err)
				}
			}
			conn.Close()
			x := env.waitExchange(func(x map[string]any) bool { return x["kind"] == "tunnel" })
			if x["status"] != float64(101) || x["method"] != "GET" || !strings.HasSuffix(x["url"].(string), "/chat") ||
				x["reqBytes"] != float64(12) || x["resBytes"] != float64(22) {
				t.Fatalf("row %v", x)
			}
			headers := headerMap(env.get(idOf(x), "request", nil))
			if c.kept != (headers["Sec-Websocket-Key"] == "key-1") {
				t.Fatalf("stored handshake headers %v", headers)
			}
			if body := env.get(idOf(x), "response", nil)["body"]; body != "" {
				t.Fatalf("frames were stored: %q", body)
			}
		})
	}
}

func plainSocketConn(t *testing.T, env *testEnv, up *httptest.Server) (net.Conn, string, string) {
	c, err := net.Dial("tcp", env.addr)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return c, up.URL + "/chat", up.Listener.Addr().String()
}

func TestRefusedWebSocketUpgradeIsAnHTTPExchange(t *testing.T) {
	up := newEchoSocketUpstream(t, false, nil)
	env := newEnv(t, up)
	conn, _, host := plainSocketConn(t, env, up)
	resp, br := openSocket(t, conn, up.URL+"/refuse", host)
	body, _ := io.ReadAll(io.LimitReader(br, resp.ContentLength))
	if resp.StatusCode != 403 || string(body) != "upgrade required\n" {
		t.Fatalf("status %d", resp.StatusCode)
	}
	x := env.waitExchange(func(x map[string]any) bool { return x["status"] == float64(403) })
	if x["kind"] != "http" {
		t.Fatalf("row %v", x)
	}
}

func TestRuleAnswersAWebSocketUpgrade(t *testing.T) {
	up := newEchoSocketUpstream(t, false, nil)
	env := newEnv(t, up)
	env.call("rule.add", map[string]any{"match": map[string]any{"path": "/chat"}, "action": map[string]any{"status": 503}})
	conn, target, host := plainSocketConn(t, env, up)
	resp, _ := openSocket(t, conn, target, host)
	if resp.StatusCode != 503 {
		t.Fatalf("status %d", resp.StatusCode)
	}
	x := env.waitExchange(func(x map[string]any) bool { return x["status"] == float64(503) })
	if x["kind"] != "http" || x["rule"] != float64(1) {
		t.Fatalf("row %v", x)
	}
}

func TestCloseEndsAnOpenWebSocket(t *testing.T) {
	up := newEchoSocketUpstream(t, false, nil)
	env := newEnv(t, up)
	conn, target, host := plainSocketConn(t, env, up)
	if resp, _ := openSocket(t, conn, target, host); resp.StatusCode != 101 {
		t.Fatalf("status %d", resp.StatusCode)
	}
	done := make(chan struct{})
	go func() {
		env.proxy.Close()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Close did not return within 5 s while a WebSocket was open")
	}
	env.waitExchange(func(x map[string]any) bool { return x["kind"] == "tunnel" && x["status"] == float64(101) })
}
