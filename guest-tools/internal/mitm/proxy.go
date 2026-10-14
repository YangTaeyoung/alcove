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
	"regexp"
	"strings"
	"sync"
	"syscall"
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

// clientFirstWait bounds how long an intercepted CONNECT connection waits for
// the client's first byte before it is tunnelled unchanged.
var clientFirstWait = 5 * time.Second

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

	tmu       sync.Mutex
	transport *http.Transport

	pmu  sync.Mutex
	pend map[*pendingEntry]struct{}

	mu       sync.Mutex
	listener net.Listener
	conns    map[net.Conn]struct{}
	closed   bool
	// done is closed by Close.
	done chan struct{}
	wg   sync.WaitGroup
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
		done:  make(chan struct{}),
	}
}

func (p *Proxy) config() config {
	p.cfgMu.RLock()
	defer p.cfgMu.RUnlock()
	return p.cfg
}

func (p *Proxy) upstream() *http.Transport {
	p.tmu.Lock()
	defer p.tmu.Unlock()
	if p.transport == nil {
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
	}
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
	var backoff time.Duration
	for {
		conn, err := l.Accept()
		if err != nil {
			p.mu.Lock()
			closed := p.closed
			p.mu.Unlock()
			if closed || errors.Is(err, net.ErrClosed) {
				return nil
			}
			if !transientAcceptError(err) {
				return err
			}
			backoff = min(max(2*backoff, 5*time.Millisecond), time.Second)
			select {
			case <-time.After(backoff):
			case <-p.done:
				return nil
			}
			continue
		}
		backoff = 0
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

// transientAcceptError reports whether Accept failed for a reason that passes:
// a timeout or running out of file descriptors. Serve retries those with a
// backoff from 5 ms to 1 s.
func transientAcceptError(err error) bool {
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		return true
	}
	return errors.Is(err, syscall.EMFILE) || errors.Is(err, syscall.ENFILE)
}

// Close stops the listener, ends rule delays, closes every open connection and
// waits for the connection handlers to finish.
func (p *Proxy) Close() {
	p.mu.Lock()
	if !p.closed {
		p.closed = true
		close(p.done)
	}
	if p.listener != nil {
		p.listener.Close()
	}
	for c := range p.conns {
		c.Close()
	}
	p.mu.Unlock()
	p.wg.Wait()
	p.tmu.Lock()
	t := p.transport
	p.tmu.Unlock()
	if t != nil {
		t.CloseIdleConnections()
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
		p.serveHTTP(bc, "", "")
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
		p.tunnel(bc, authority, false)
		return
	}
	if _, err := io.WriteString(conn, "HTTP/1.1 200 Connection Established\r\n\r\n"); err != nil {
		return
	}
	_ = conn.SetReadDeadline(time.Now().Add(clientFirstWait))
	first, err := br.Peek(1)
	var ne net.Error
	switch {
	case err == nil && first[0] == tlsHandshakeRecord:
		_ = conn.SetReadDeadline(time.Time{})
		p.interceptTLS(bc, host, port)
	case err == nil && startsWithRequestLine(br):
		_ = conn.SetReadDeadline(time.Time{})
		p.serveHTTP(bc, "http", hostPort(host, port, "80"))
	case err == nil || errors.As(err, &ne) && ne.Timeout():
		_ = conn.SetReadDeadline(time.Time{})
		p.tunnel(bc, authority, true)
	}
}

// tlsHandshakeRecord is the first byte of a TLS handshake record.
const tlsHandshakeRecord = 0x16

var requestLine = regexp.MustCompile(`^[A-Z]+ [^ ]+ HTTP/1\.[01]\r?\n$`)

// startsWithRequestLine reports whether the client's first line, read ahead
// into br until the connection's read deadline, is an HTTP/1 request line.
func startsWithRequestLine(br *bufio.Reader) bool {
	for n := 1; n <= br.Size(); n++ {
		b, err := br.Peek(n)
		if err != nil {
			return false
		}
		if b[n-1] == '\n' {
			return requestLine.Match(b)
		}
	}
	return false
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
			Error:  handshakeError(err),
			Method: "CONNECT",
		})
		return
	}
	_ = conn.SetDeadline(time.Time{})
	p.serveHTTP(tc, "https", hostPort(host, port, "443"))
}

// handshakeError describes a failed TLS handshake with the client and names
// the next step.
func handshakeError(err error) string {
	msg := err.Error()
	var ne net.Error
	switch {
	case strings.Contains(msg, "certificate"):
		return msg + "; the program does not trust the Alcove CA: install the CA where it looks for trusted certificates, or exclude this host with hosts"
	case errors.As(err, &ne) && ne.Timeout():
		return msg + "; the program sent no TLS handshake in time: exclude this host with hosts if it does not speak TLS to it"
	}
	return msg + "; if the program pins certificates or does not speak TLS to this host, exclude the host with hosts"
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
// conn with p.handler(scheme, authority) and returns when the connection is
// finished or, after a handler took the connection over, when that handler
// has released it.
func (p *Proxy) serveHTTP(conn net.Conn, scheme, authority string) {
	ln := &oneConnListener{conn: conn, done: make(chan struct{})}
	srv := &http.Server{
		Handler:           p.handler(scheme, authority, func() { ln.Close() }),
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
