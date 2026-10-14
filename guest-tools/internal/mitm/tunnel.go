package mitm

import (
	"io"
	"net"
	"sync/atomic"
	"time"
)

// tunnel connects to the upstream authority and copies bytes both ways. When
// one direction reaches EOF the peer connection is half-closed and the other
// direction continues until it ends or stays idle for tunnelIdleAfterHalfClose;
// a read or write error closes both connections. A tunnel row with the byte
// counts is recorded when both directions have finished. With replied the
// client has already been told the connection is established, and a failed
// dial closes it without an answer.
func (p *Proxy) tunnel(client *bufConn, authority string, replied bool) {
	start := time.Now()
	ex := &Exchange{
		Time:   start,
		Kind:   "tunnel",
		Method: "CONNECT",
		URL:    authority,
		Host:   authority,
		Path:   "/",
	}
	up, err := net.DialTimeout("tcp", dialAddress(authority), dialTimeout)
	if err != nil {
		if !replied {
			_, _ = io.WriteString(client, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
			ex.Status = 502
		}
		ex.Error = "cannot reach " + authority + ": " + err.Error() + "; check the address and that the Mac can reach it"
		p.record(ex)
		return
	}
	if !p.trackAux(up) {
		up.Close()
		return
	}
	defer p.untrackAux(up)
	if !replied {
		if _, err := io.WriteString(client, "HTTP/1.1 200 Connection Established\r\n\r\n"); err != nil {
			return
		}
	}
	ex.Status = 200
	var up2down, down2up atomic.Int64
	endPending := p.beginPending(&pendingEntry{time: start, kind: "tunnel", method: "CONNECT", url: authority, req: down2up.Load, res: up2down.Load})
	defer endPending()

	var ended atomic.Bool
	done := make(chan struct{}, 2)
	// pipe copies src to dst. At EOF it half-closes dst and bounds the idle
	// time of the other direction (otherSrc); any other error closes both.
	pipe := func(dst net.Conn, src io.Reader, otherSrc net.Conn, n *atomic.Int64) {
		_, err := io.Copy(dst, &countingReader{r: src, n: n, ended: &ended, conn: srcConn(src, client, up)})
		if err != nil {
			up.Close()
			client.Close()
		} else {
			if hc, ok := dst.(interface{ CloseWrite() error }); ok {
				_ = hc.CloseWrite()
			} else {
				dst.Close()
			}
			ended.Store(true)
			_ = otherSrc.SetReadDeadline(time.Now().Add(tunnelIdleAfterHalfClose))
		}
		done <- struct{}{}
	}
	go pipe(up, client, up, &down2up)
	go pipe(client.Conn, up, client.Conn, &up2down)
	<-done
	<-done
	up.Close()
	client.Close()
	ex.ReqBytes = down2up.Load()
	ex.ResBytes = up2down.Load()
	ex.Ms = time.Since(start).Milliseconds()
	p.record(ex)
}

// countingReader counts bytes read from a tunnel side. Once one direction of
// the tunnel has ended it refreshes the idle read deadline on every read.
type countingReader struct {
	r     io.Reader
	n     *atomic.Int64
	ended *atomic.Bool
	conn  net.Conn
}

func (c *countingReader) Read(b []byte) (int, error) {
	n, err := c.r.Read(b)
	c.n.Add(int64(n))
	if n > 0 && c.ended.Load() {
		_ = c.conn.SetReadDeadline(time.Now().Add(tunnelIdleAfterHalfClose))
	}
	return n, err
}

// srcConn returns the connection that src reads from.
func srcConn(src io.Reader, client *bufConn, up net.Conn) net.Conn {
	if src == io.Reader(client) {
		return client.Conn
	}
	return up
}

// tunnelIdleAfterHalfClose bounds the idle time of the remaining direction of a
// tunnel once the other direction has ended.
var tunnelIdleAfterHalfClose = 30 * time.Second
