package mitm

import (
	"bufio"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// portOf returns the port of a test server URL or of a host:port address.
func portOf(t *testing.T, addr string) string {
	t.Helper()
	_, port, err := net.SplitHostPort(strings.TrimPrefix(strings.TrimPrefix(addr, "https://"), "http://"))
	if err != nil {
		t.Fatal(err)
	}
	return port
}

func TestDialAddressMapsTheGuestNameOfTheHostToLoopback(t *testing.T) {
	for in, want := range map[string]string{
		"10.0.2.2:3000":     "127.0.0.1:3000",
		"10.0.2.2:443":      "127.0.0.1:443",
		"10.0.2.20:3000":    "10.0.2.20:3000",
		"110.0.2.2:3000":    "110.0.2.2:3000",
		"example.com:443":   "example.com:443",
		"127.0.0.1:8080":    "127.0.0.1:8080",
		"[::1]:8080":        "[::1]:8080",
		"10.0.2.2":          "10.0.2.2",
		"10.0.2.2.nip.io:1": "10.0.2.2.nip.io:1",
	} {
		if got := dialAddress(in); got != want {
			t.Errorf("dialAddress(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestPlainHTTPToTheGuestNameOfTheHostReachesLoopback(t *testing.T) {
	var seenHost string
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenHost = r.Host
		io.WriteString(w, "from the host")
	}))
	defer up.Close()
	env := newEnv(t)
	target := "http://10.0.2.2:" + portOf(t, up.URL) + "/dev/api"
	resp, err := env.client.Get(target)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 || string(body) != "from the host" {
		t.Fatalf("got %d %q", resp.StatusCode, body)
	}
	if seenHost != "10.0.2.2:"+portOf(t, up.URL) {
		t.Fatalf("the upstream saw Host %q", seenHost)
	}
	x := env.waitExchange(func(x map[string]any) bool { return x["kind"] == "http" })
	if x["url"] != target || x["status"] != float64(200) {
		t.Fatalf("exchange %v", x)
	}
	if env.get(idOf(x), "response", nil)["body"] != "from the host" {
		t.Fatal("response body not captured")
	}
}

func TestInterceptedHTTPSToTheGuestNameOfTheHostReachesLoopback(t *testing.T) {
	env := newEnv(t)
	leaf, err := env.ca.Leaf("10.0.2.2")
	if err != nil {
		t.Fatal(err)
	}
	up := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "secure from the host") }))
	up.TLS = &tls.Config{Certificates: []tls.Certificate{*leaf}}
	up.StartTLS()
	defer up.Close()
	env.proxy.UpstreamRoots.AddCert(env.ca.Certificate())

	target := "https://10.0.2.2:" + portOf(t, up.URL) + "/dev/api"
	resp, err := env.client.Get(target)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 || string(body) != "secure from the host" {
		t.Fatalf("got %d %q", resp.StatusCode, body)
	}
	seen := resp.TLS.PeerCertificates[0]
	if len(seen.IPAddresses) != 1 || !seen.IPAddresses[0].Equal(net.IPv4(10, 0, 2, 2)) {
		t.Fatalf("the client got a certificate for %v %v", seen.IPAddresses, seen.DNSNames)
	}
	x := env.waitExchange(func(x map[string]any) bool { return x["kind"] == "http" })
	if x["url"] != target {
		t.Fatalf("exchange %v", x)
	}
}

func TestTunnelToTheGuestNameOfTheHostReachesLoopback(t *testing.T) {
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
		line, _ := bufio.NewReader(c).ReadString('\n')
		fmt.Fprintf(c, "echo %s", line)
	}()
	env := newEnv(t)
	env.call("config", map[string]any{"hosts": []any{"nomatch.test"}})
	target := "10.0.2.2:" + portOf(t, l.Addr().String())
	c := openTunnel(t, env, target)
	fmt.Fprintf(c, "ping\n")
	reply, err := bufio.NewReader(c).ReadString('\n')
	if err != nil || reply != "echo ping\n" {
		t.Fatalf("reply %q %v", reply, err)
	}
	c.Close()
	x := env.waitExchange(func(x map[string]any) bool { return x["kind"] == "tunnel" })
	if x["url"] != target || x["status"] != float64(200) {
		t.Fatalf("tunnel row %v", x)
	}
}
