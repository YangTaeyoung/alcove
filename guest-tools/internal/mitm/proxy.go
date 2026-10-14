package mitm

import (
	"bufio"
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

const (
	handshakeTimeout = 30 * time.Second
	dialTimeout      = 15 * time.Second
	responseTimeout  = 120 * time.Second
)

// guestHostAlias is the address a guest on the user-mode network reaches the
// host's loopback interface at.
const guestHostAlias = "10.0.2.2"

// dialAddress returns the address the proxy connects to for the upstream
// address addr: the host's loopback with the same port when addr names the
// host as guestHostAlias, addr itself otherwise.
func dialAddress(addr string) string {
	host, port, err := net.SplitHostPort(addr)
	if err != nil || host != guestHostAlias {
		return addr
	}
	return net.JoinHostPort("127.0.0.1", port)
}

// firstBytesTimeout bounds how long a new client connection may take to send
// its first bytes and its CONNECT or request header.
var firstBytesTimeout = 30 * time.Second

type config struct {
	hosts   []string
	secrets bool
	bodies  bool
}

// Proxy is an intercepting HTTP(S) proxy with capture and request rules.
type Proxy struct {
	// UpstreamRoots, when set before the first request, replaces the system
	// roots used to verify upstream servers.
	UpstreamRoots *x509.CertPool

	ca    *CA
	store *Store
	rules *ruleSet

	cfgMu sync.RWMutex
	cfg   config

	tOnce     sync.Once
	transport *http.Transport

	pmu  sync.Mutex
	pend map[*pendingEntry]struct{}

	mu       sync.Mutex
	listener net.Listener
	conns    map[net.Conn]struct{}
	closed   bool
	wg       sync.WaitGroup
}

// NewProxy returns a proxy that signs intercepted hosts with ca.
func NewProxy(ca *CA) *Proxy {
	return &Proxy{
		ca:    ca,
		store: newStore(maxExchanges),
		rules: newRuleSet(),
		cfg:   config{bodies: true},
		conns: map[net.Conn]struct{}{},
		pend:  map[*pendingEntry]struct{}{},
	}
}

func (p *Proxy) config() config {
	p.cfgMu.RLock()
	defer p.cfgMu.RUnlock()
	return p.cfg
}

func (p *Proxy) upstream() *http.Transport {
	p.tOnce.Do(func() {
		dialer := &net.Dialer{Timeout: dialTimeout}
		p.transport = &http.Transport{
			Proxy:                 nil,
			ForceAttemptHTTP2:     true,
			DisableCompression:    true,
			ResponseHeaderTimeout: responseTimeout,
			TLSHandshakeTimeout:   dialTimeout,
			MaxIdleConnsPerHost:   32,
			IdleConnTimeout:       90 * time.Second,
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				return dialer.DialContext(ctx, network, dialAddress(addr))
			},
			TLSClientConfig: &tls.Config{RootCAs: p.UpstreamRoots},
		}
	})
	return p.transport
}

// Serve accepts proxy connections on l until l is closed or Close is called.
func (p *Proxy) Serve(l net.Listener) error {
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		return nil
	}
	p.listener = l
	p.mu.Unlock()
	for {
		conn, err := l.Accept()
		if err != nil {
			p.mu.Lock()
			closed := p.closed
			p.mu.Unlock()
			if closed || errors.Is(err, net.ErrClosed) {
				return nil
			}
			return err
		}
		if !p.track(conn) {
			conn.Close()
			return nil
		}
		go func() {
			defer p.untrack(conn)
			p.handleConn(conn)
		}()
	}
}

// Close stops the listener, closes every open connection and waits for the
// connection handlers to finish.
func (p *Proxy) Close() {
	p.mu.Lock()
	p.closed = true
	if p.listener != nil {
		p.listener.Close()
	}
	for c := range p.conns {
		c.Close()
	}
	p.mu.Unlock()
	p.wg.Wait()
	if p.transport != nil {
		p.transport.CloseIdleConnections()
	}
}

// trackAux registers a connection owned by a tracked handler so that Close
// closes it too.
func (p *Proxy) trackAux(c net.Conn) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return false
	}
	p.conns[c] = struct{}{}
	return true
}

func (p *Proxy) untrackAux(c net.Conn) {
	c.Close()
	p.mu.Lock()
	delete(p.conns, c)
	p.mu.Unlock()
}

func (p *Proxy) track(c net.Conn) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return false
	}
	p.conns[c] = struct{}{}
	p.wg.Add(1)
	return true
}

func (p *Proxy) untrack(c net.Conn) {
	c.Close()
	p.mu.Lock()
	delete(p.conns, c)
	p.mu.Unlock()
	p.wg.Done()
}

// bufConn reads through a bufio.Reader that may hold bytes already read from
// the connection.
type bufConn struct {
	net.Conn
	r *bufio.Reader
}

func (c *bufConn) Read(b []byte) (int, error) { return c.r.Read(b) }

func (p *Proxy) handleConn(conn net.Conn) {
	br := bufio.NewReader(conn)
	_ = conn.SetReadDeadline(time.Now().Add(firstBytesTimeout))
	head, err := br.Peek(8)
	if err != nil {
		return
	}
	bc := &bufConn{Conn: conn, r: br}
	if string(head) != "CONNECT " {
		_ = conn.SetReadDeadline(time.Time{})
		p.serveHTTP(bc, p.handler("", ""))
		return
	}
	req, err := http.ReadRequest(br)
	_ = conn.SetReadDeadline(time.Time{})
	if err != nil {
		return
	}
	host, port := splitAuthority(req.Host, "443")
	authority := net.JoinHostPort(host, port)
	if !p.intercepts(host) {
		p.tunnel(bc, host, authority)
		return
	}
	if _, err := io.WriteString(conn, "HTTP/1.1 200 Connection Established\r\n\r\n"); err != nil {
		return
	}
	p.interceptTLS(bc, host, port)
}

func splitAuthority(authority, defaultPort string) (host, port string) {
	if h, pt, err := net.SplitHostPort(authority); err == nil {
		return h, pt
	}
	return strings.Trim(authority, "[]"), defaultPort
}

func (p *Proxy) intercepts(host string) bool {
	hosts := p.config().hosts
	if len(hosts) == 0 {
		return true
	}
	host = strings.ToLower(host)
	for _, g := range hosts {
		if globMatch(strings.ToLower(g), host) {
			return true
		}
	}
	return false
}

func (p *Proxy) interceptTLS(conn *bufConn, host, port string) {
	tlsConf := &tls.Config{
		NextProtos: []string{"h2", "http/1.1"},
		GetCertificate: func(hello *tls.ClientHelloInfo) (*tls.Certificate, error) {
			name := hello.ServerName
			if name == "" {
				name = host
			}
			return p.ca.Leaf(name)
		},
	}
	tc := tls.Server(conn, tlsConf)
	_ = conn.SetDeadline(time.Now().Add(handshakeTimeout))
	if err := tc.Handshake(); err != nil {
		p.record(&Exchange{
			Time:   time.Now(),
			Kind:   "tlsError",
			URL:    "https://" + hostPort(host, port, "443"),
			Host:   hostPort(host, port, "443"),
			Path:   "/",
			Error:  err.Error(),
			Method: "CONNECT",
		})
		return
	}
	_ = conn.SetDeadline(time.Time{})
	p.serveHTTP(tc, p.handler("https", hostPort(host, port, "443")))
}

func hostPort(host, port, defaultPort string) string {
	if port == defaultPort {
		if strings.Contains(host, ":") {
			return "[" + host + "]"
		}
		return host
	}
	return net.JoinHostPort(host, port)
}

// oneConnListener hands out a single connection and then blocks until closed.
type oneConnListener struct {
	conn net.Conn
	once sync.Once
	done chan struct{}
	used bool
	mu   sync.Mutex
}

func (l *oneConnListener) Accept() (net.Conn, error) {
	l.mu.Lock()
	if !l.used {
		l.used = true
		l.mu.Unlock()
		return l.conn, nil
	}
	l.mu.Unlock()
	<-l.done
	return nil, net.ErrClosed
}

func (l *oneConnListener) Close() error {
	l.once.Do(func() { close(l.done) })
	return nil
}

func (l *oneConnListener) Addr() net.Addr { return l.conn.LocalAddr() }

// serveHTTP serves HTTP/1.1 (and HTTP/2 on a negotiated TLS connection) on
// conn and returns when the connection is finished.
func (p *Proxy) serveHTTP(conn net.Conn, h http.Handler) {
	ln := &oneConnListener{conn: conn, done: make(chan struct{})}
	srv := &http.Server{
		Handler:           h,
		ErrorLog:          log.New(io.Discard, "", 0),
		IdleTimeout:       2 * time.Minute,
		ReadHeaderTimeout: firstBytesTimeout,
		ConnState: func(_ net.Conn, s http.ConnState) {
			if s == http.StateClosed {
				ln.Close()
			}
		},
	}
	_ = srv.Serve(ln)
}
