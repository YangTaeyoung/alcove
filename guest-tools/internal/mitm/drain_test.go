package mitm

import (
	"bufio"
	"fmt"
	"net"
	"strings"
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
