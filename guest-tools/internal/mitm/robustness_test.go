package mitm

import (
	"bufio"
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/http/httptrace"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func newEventUpstream(t *testing.T, gate <-chan struct{}) *httptest.Server {
	up := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, "data: event-1\n\n")
		w.(http.Flusher).Flush()
		select {
		case <-gate:
		case <-time.After(10 * time.Second):
			return
		}
		fmt.Fprint(w, "data: event-2\n\n")
		w.(http.Flusher).Flush()
		fmt.Fprint(w, "data: event-3\n\n")
	}))
	up.EnableHTTP2 = true
	up.StartTLS()
	t.Cleanup(up.Close)
	return up
}

func TestStreamingIsForwardedIncrementally(t *testing.T) {
	for _, h2 := range []bool{false, true} {
		t.Run(protoName(h2), func(t *testing.T) {
			gate := make(chan struct{})
			up := newEventUpstream(t, gate)
			env := newEnv(t, up)
			client := env.newProtoClient(h2)
			resp, err := client.Get(up.URL + "/stream")
			if err != nil {
				t.Fatal(err)
			}
			defer resp.Body.Close()
			if (resp.ProtoMajor == 2) != h2 {
				t.Fatalf("client protocol HTTP/%d", resp.ProtoMajor)
			}
			br := bufio.NewReader(resp.Body)
			first := make(chan string, 1)
			go func() {
				line, _ := br.ReadString('\n')
				first <- line
			}()
			select {
			case line := <-first:
				if line != "data: event-1\n" {
					t.Fatalf("first line %q", line)
				}
			case <-time.After(5 * time.Second):
				close(gate)
				t.Fatal("the first event did not arrive while the upstream was still holding the rest")
			}
			close(gate)
			rest, _ := io.ReadAll(br)
			if !strings.Contains(string(rest), "event-3") {
				t.Fatalf("rest %q", rest)
			}
			x := env.waitExchange(func(x map[string]any) bool { return x["kind"] == "http" })
			body := env.get(idOf(x), "response", nil)["body"].(string)
			for _, want := range []string{"event-1", "event-2", "event-3"} {
				if !strings.Contains(body, want) {
					t.Fatalf("capture %q lacks %s", body, want)
				}
			}
		})
	}
}

func TestClientDisconnectIsNotAnUpstreamFailure(t *testing.T) {
	for _, h2 := range []bool{false, true} {
		t.Run(protoName(h2), func(t *testing.T) {
			upstreamDone := make(chan struct{})
			up := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				defer close(upstreamDone)
				fmt.Fprint(w, "data: event-1\n\n")
				w.(http.Flusher).Flush()
				select {
				case <-r.Context().Done():
				case <-time.After(10 * time.Second):
				}
			}))
			up.EnableHTTP2 = true
			up.StartTLS()
			defer up.Close()
			env := newEnv(t, up)
			client := env.newProtoClient(h2)
			ctx, cancel := context.WithCancel(context.Background())
			req, _ := http.NewRequestWithContext(ctx, "GET", up.URL+"/stream", nil)
			resp, err := client.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			line, err := bufio.NewReader(resp.Body).ReadString('\n')
			if err != nil || line != "data: event-1\n" {
				t.Fatalf("first line %q %v", line, err)
			}
			cancel()
			resp.Body.Close()
			x := env.waitExchange(func(x map[string]any) bool { return x["kind"] == "http" })
			if x["error"] != "the client closed the connection" || x["status"].(float64) != 200 {
				t.Fatalf("row %v", x)
			}
			if got := env.get(idOf(x), "response", nil)["body"]; got != "data: event-1\n\n" {
				t.Fatalf("captured body %q", got)
			}
			select {
			case <-upstreamDone:
			case <-time.After(5 * time.Second):
				t.Fatal("the upstream request was not cancelled")
			}
		})
	}
}

func TestTrailersAreForwardedAndCaptured(t *testing.T) {
	for _, h2 := range []bool{false, true} {
		t.Run(protoName(h2), func(t *testing.T) {
			var gotReqTrailer atomic.Value
			up := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				io.Copy(io.Discard, r.Body)
				gotReqTrailer.Store(r.Trailer.Get("X-Req-Sum"))
				w.Header().Set("Trailer", "X-Res-Sum")
				io.WriteString(w, "payload")
				w.Header().Set("X-Res-Sum", "res-42")
				w.Header().Set(http.TrailerPrefix+"X-Late", "late-1")
			}))
			up.EnableHTTP2 = true
			up.StartTLS()
			defer up.Close()
			env := newEnv(t, up)
			client := env.newProtoClient(h2)
			req, _ := http.NewRequest("POST", up.URL+"/t", io.NopCloser(strings.NewReader("body")))
			req.ContentLength = -1
			req.Trailer = http.Header{"X-Req-Sum": {"req-7"}}
			req.Header.Set("Te", "trailers")
			resp, err := client.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			body, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			if string(body) != "payload" || resp.Trailer.Get("X-Res-Sum") != "res-42" || resp.Trailer.Get("X-Late") != "late-1" {
				t.Fatalf("body %q trailers %v", body, resp.Trailer)
			}
			if gotReqTrailer.Load() != "req-7" {
				t.Fatalf("upstream saw request trailer %v", gotReqTrailer.Load())
			}
			x := env.waitExchange(func(x map[string]any) bool { return x["kind"] == "http" })
			res := env.get(idOf(x), "response", nil)
			tr := res["trailers"].([]any)
			if len(tr) != 2 || tr[0].([]any)[0] != "X-Late" || tr[1].([]any)[1] != "res-42" {
				t.Fatalf("stored response trailers %v", tr)
			}
			if rq := env.get(idOf(x), "request", nil)["trailers"]; rq == nil || rq.([]any)[0].([]any)[1] != "req-7" {
				t.Fatalf("stored request trailers %v", rq)
			}
		})
	}
}

func TestMockedAndRefusedRequestsKeepTheirRequestBody(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer up.Close()
	env := newEnv(t)
	env.call("rule.add", map[string]any{"match": map[string]any{"path": "/mock"}, "action": map[string]any{"status": 200, "body": "{}"}})
	env.call("rule.add", map[string]any{"match": map[string]any{"path": "/drop"}, "action": map[string]any{"drop": true}})
	payload := `{"model":"x","prompt":"hello"}`
	if resp, err := env.client.Post(up.URL+"/mock", "application/json", strings.NewReader(payload)); err != nil {
		t.Fatal(err)
	} else {
		resp.Body.Close()
	}
	if resp, err := env.client.Post(up.URL+"/drop", "application/json", strings.NewReader(payload)); err == nil {
		resp.Body.Close()
		t.Fatal("expected the dropped request to fail")
	}
	req, _ := http.NewRequest("POST", up.URL+"/ws", strings.NewReader(payload))
	req.Header.Set("Connection", "Upgrade")
	req.Header.Set("Upgrade", "websocket")
	if resp, err := env.client.Do(req); err != nil {
		t.Fatal(err)
	} else {
		resp.Body.Close()
	}
	for _, path := range []string{"/mock", "/drop", "/ws"} {
		x := env.waitExchange(func(x map[string]any) bool { return strings.HasSuffix(x["url"].(string), path) })
		if int(x["reqBytes"].(float64)) != len(payload) {
			t.Errorf("%s: reqBytes %v", path, x["reqBytes"])
		}
		if got := env.get(idOf(x), "request", nil)["body"]; got != payload {
			t.Errorf("%s: request body %v", path, got)
		}
	}
}

func TestNonOriginFormTargetInsideTunnelIsRefused(t *testing.T) {
	up := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("the upstream was reached with %q", r.RequestURI)
	}))
	defer up.Close()
	env := newEnv(t, up)
	for _, target := range []string{"mailto:@evil.example/x", "http://evil.example/x"} {
		raw := openTunnel(t, env, up.Listener.Addr().String())
		pool := x509.NewCertPool()
		pool.AddCert(env.ca.Certificate())
		tc := tls.Client(raw, &tls.Config{RootCAs: pool, ServerName: "127.0.0.1"})
		fmt.Fprintf(tc, "GET %s HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", target)
		resp, err := http.ReadResponse(bufio.NewReader(tc), nil)
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != 400 || string(body) != "request target must start with '/'" {
			t.Fatalf("%s: got %d %q", target, resp.StatusCode, body)
		}
	}
	x := env.waitExchange(func(x map[string]any) bool { return x["status"] == float64(400) })
	if x["error"] != "request target must start with '/'" {
		t.Fatalf("row %v", x)
	}
}

func TestDropResetsOnlyTheHTTP2Stream(t *testing.T) {
	up := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "ok") }))
	up.EnableHTTP2 = true
	up.StartTLS()
	defer up.Close()
	env := newEnv(t, up)
	env.call("rule.add", map[string]any{"match": map[string]any{"path": "/drop"}, "action": map[string]any{"drop": true}})
	client := env.newProtoClient(true)
	if resp, err := client.Get(up.URL + "/warm"); err != nil {
		t.Fatal(err)
	} else {
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
	}
	if resp, err := client.Get(up.URL + "/drop"); err == nil {
		resp.Body.Close()
		t.Fatal("expected the dropped stream to fail")
	}
	var reused bool
	trace := &httptrace.ClientTrace{GotConn: func(i httptrace.GotConnInfo) { reused = i.Reused }}
	req, _ := http.NewRequestWithContext(httptrace.WithClientTrace(context.Background(), trace), "GET", up.URL+"/after", nil)
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("the connection was not usable after the drop: %v", err)
	}
	resp.Body.Close()
	if !reused || resp.ProtoMajor != 2 {
		t.Fatalf("reused=%v proto=HTTP/%d", reused, resp.ProtoMajor)
	}
}
