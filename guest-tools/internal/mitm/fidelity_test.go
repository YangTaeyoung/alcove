package mitm

import (
	"bufio"
	"context"
	"crypto/tls"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httptrace"
	"net/textproto"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// watchedBody records whether it was read.
type watchedBody struct {
	r    io.Reader
	read *atomic.Bool
}

func (b watchedBody) Read(p []byte) (int, error) {
	b.read.Store(true)
	return b.r.Read(p)
}

func TestExpectContinueWaitsForTheUpstream(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer up.Close()
	env := newEnv(t)
	tr := env.newClient(false).Transport.(*http.Transport)
	tr.ExpectContinueTimeout = 5 * time.Second
	var read atomic.Bool
	req, _ := http.NewRequest("POST", up.URL+"/upload", watchedBody{strings.NewReader("hello"), &read})
	req.ContentLength = 5
	req.Header.Set("Expect", "100-continue")
	req.Close = true
	resp, err := (&http.Client{Transport: tr}).Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 401 || read.Load() {
		t.Fatalf("status %d, body read %v", resp.StatusCode, read.Load())
	}
}

func TestInformationalResponsesAreRelayed(t *testing.T) {
	for _, h2 := range []bool{false, true} {
		t.Run(protoName(h2), func(t *testing.T) {
			up := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Link", "</a.css>; rel=preload")
				w.WriteHeader(http.StatusEarlyHints)
				w.Header().Del("Link")
				io.WriteString(w, "ok")
			}))
			up.EnableHTTP2 = true
			up.StartTLS()
			defer up.Close()
			env := newEnv(t, up)
			var hints []string
			trace := &httptrace.ClientTrace{Got1xxResponse: func(code int, h textproto.MIMEHeader) error {
				hints = append(hints, http.StatusText(code)+" "+h.Get("Link"))
				return nil
			}}
			req, _ := http.NewRequestWithContext(httptrace.WithClientTrace(context.Background(), trace), "GET", up.URL+"/page", nil)
			resp, err := env.newProtoClient(h2).Do(req)
			if err != nil {
				t.Fatal(err)
			}
			body, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			if string(body) != "ok" || len(hints) != 1 || hints[0] != "Early Hints </a.css>; rel=preload" || resp.Header.Get("Link") != "" {
				t.Fatalf("body %q hints %q final Link %q", body, hints, resp.Header.Get("Link"))
			}
		})
	}
}

// bareUpstream answers every request on l with a 200 that has only a
// Content-Length header and the body "hello", and sends the request headers
// it read on seen.
func bareUpstream(t *testing.T, l net.Listener, seen chan<- http.Header) {
	t.Cleanup(func() { l.Close() })
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				req, err := http.ReadRequest(bufio.NewReader(c))
				if err != nil {
					return
				}
				select {
				case seen <- req.Header:
				default:
				}
				io.WriteString(c, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello")
			}()
		}
	}()
}

func TestProxyAddsNoHeadersOfItsOwn(t *testing.T) {
	check := func(t *testing.T, client *http.Client, target string, seen <-chan http.Header) {
		t.Helper()
		req, _ := http.NewRequest("GET", target, nil)
		req.Header["User-Agent"] = []string{""}
		resp, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if string(body) != "hello" {
			t.Fatalf("body %q", body)
		}
		if h := <-seen; h.Get("User-Agent") != "" {
			t.Fatalf("the upstream saw User-Agent %q", h.Get("User-Agent"))
		}
		for _, name := range []string{"Date", "Content-Type"} {
			if _, ok := resp.Header[name]; ok {
				t.Fatalf("the client got %s %q", name, resp.Header.Get(name))
			}
		}
	}
	t.Run("plain", func(t *testing.T) {
		l, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		seen := make(chan http.Header, 1)
		bareUpstream(t, l, seen)
		env := newEnv(t)
		check(t, env.client, "http://"+l.Addr().String()+"/", seen)
	})
	for _, h2 := range []bool{false, true} {
		t.Run("https "+protoName(h2), func(t *testing.T) {
			env := newEnv(t)
			leaf, err := env.ca.Leaf("127.0.0.1")
			if err != nil {
				t.Fatal(err)
			}
			env.proxy.UpstreamRoots.AddCert(env.ca.Certificate())
			inner, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			seen := make(chan http.Header, 1)
			bareUpstream(t, tls.NewListener(inner, &tls.Config{Certificates: []tls.Certificate{*leaf}}), seen)
			check(t, env.newProtoClient(h2), "https://"+inner.Addr().String()+"/", seen)
		})
	}
}

func TestUntouchedRowKeepsNoTrailers(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.Copy(io.Discard, r.Body)
		w.Header().Set("Trailer", "X-Res-Sum")
		io.WriteString(w, "payload")
		w.Header().Set("X-Res-Sum", "res-42")
	}))
	defer up.Close()
	env := newEnv(t)
	env.call("config", map[string]any{"hosts": []any{"nomatch.test"}})
	req, _ := http.NewRequest("POST", up.URL+"/t", io.NopCloser(strings.NewReader("body")))
	req.ContentLength = -1
	req.Trailer = http.Header{"X-Req-Sum": {"req-7"}}
	req.Header.Set("Te", "trailers")
	resp, err := env.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.Trailer.Get("X-Res-Sum") != "res-42" {
		t.Fatalf("trailers %v", resp.Trailer)
	}
	x := env.waitExchange(func(x map[string]any) bool { return x["kind"] == "tunnel" })
	for _, part := range []string{"request", "response"} {
		if tr := env.get(idOf(x), part, nil)["trailers"]; tr != nil {
			t.Fatalf("%s trailers kept: %v", part, tr)
		}
	}
}
