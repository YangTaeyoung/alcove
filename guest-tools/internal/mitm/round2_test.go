package mitm

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"strings"
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
