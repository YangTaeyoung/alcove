package mitm

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestTunnelHonoursAHalfClose(t *testing.T) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	go func() {
		c, err := l.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		req, _ := io.ReadAll(c)
		time.Sleep(200 * time.Millisecond)
		fmt.Fprintf(c, "response-to-%s", req)
	}()
	env := newEnv(t)
	env.call("config", map[string]any{"hosts": []any{"nomatch.test"}})
	c := openTunnel(t, env, l.Addr().String())
	if _, err := io.WriteString(c, "ping"); err != nil {
		t.Fatal(err)
	}
	if err := c.(*net.TCPConn).CloseWrite(); err != nil {
		t.Fatal(err)
	}
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	got, err := io.ReadAll(c)
	if err != nil || string(got) != "response-to-ping" {
		t.Fatalf("read %q %v", got, err)
	}
}

func TestPlainHTTPOverConnectIsServedAsHTTP(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "plain over connect") }))
	defer up.Close()
	env := newEnv(t)
	addr := up.Listener.Addr().String()
	c := openTunnel(t, env, addr)
	fmt.Fprintf(c, "GET /p HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n", addr)
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	resp, err := http.ReadResponse(bufio.NewReader(c), nil)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 || string(body) != "plain over connect" {
		t.Fatalf("got %d %q", resp.StatusCode, body)
	}
	x := env.waitExchange(func(x map[string]any) bool { return x["kind"] == "http" })
	if x["url"] != "http://"+addr+"/p" || env.get(idOf(x), "response", nil)["body"] != "plain over connect" {
		t.Fatalf("row %v", x)
	}
}

// echoUpstream accepts one connection, writes greeting, then echoes lines.
func echoUpstream(t *testing.T, greeting string) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		c, err := l.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		io.WriteString(c, greeting)
		br := bufio.NewReader(c)
		for {
			line, err := br.ReadString('\n')
			if err != nil {
				return
			}
			io.WriteString(c, "echo:"+line)
		}
	}()
	return l.Addr().String()
}

func TestOtherProtocolsOverConnectAreTunnelled(t *testing.T) {
	old := clientFirstWait
	clientFirstWait = 200 * time.Millisecond
	t.Cleanup(func() { clientFirstWait = old })
	for _, c := range []struct {
		name     string
		greeting string
		send     string
	}{
		{"client speaks first", "", "\x00binary\n"},
		{"client banner in capitals", "", "SSH-2.0-test\r\n"},
		{"server speaks first", "220 ready\n", "hello\n"},
	} {
		t.Run(c.name, func(t *testing.T) {
			addr := echoUpstream(t, c.greeting)
			env := newEnv(t)
			conn := openTunnel(t, env, addr)
			br := bufio.NewReader(conn)
			conn.SetReadDeadline(time.Now().Add(5 * time.Second))
			if c.greeting != "" {
				if line, err := br.ReadString('\n'); err != nil || line != c.greeting {
					t.Fatalf("greeting %q %v", line, err)
				}
			}
			io.WriteString(conn, c.send)
			if line, err := br.ReadString('\n'); err != nil || line != "echo:"+c.send {
				t.Fatalf("read %q %v", line, err)
			}
			conn.Close()
			x := env.waitExchange(func(x map[string]any) bool { return x["kind"] == "tunnel" })
			if x["url"] != addr || x["reqBytes"] != float64(len(c.send)) {
				t.Fatalf("row %v", x)
			}
		})
	}
}

func TestTunnelEndsAfterTheIdleTimeWhenTheUpstreamHoldsOn(t *testing.T) {
	old := tunnelIdleAfterHalfClose
	tunnelIdleAfterHalfClose = 300 * time.Millisecond
	t.Cleanup(func() { tunnelIdleAfterHalfClose = old })
	addr := holdingUpstream(t)
	env := newEnv(t)
	env.call("config", map[string]any{"hosts": []any{"nomatch.test"}})
	c := openTunnel(t, env, addr)
	start := time.Now()
	c.Close()
	x := env.waitExchange(func(x map[string]any) bool { return x["kind"] == "tunnel" })
	if d := time.Since(start); d > 3*time.Second || x["url"] != addr {
		t.Fatalf("row %v after %v", x, d)
	}
}
