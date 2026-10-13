package mitm

import (
	"io"
	"net"
	"sync/atomic"
	"time"
)

// tunnel connects to the upstream authority and copies bytes both ways. When
// either direction ends, both connections are closed. A tunnel row with the
// byte counts is recorded when the copy has finished.
func (p *Proxy) tunnel(client *bufConn, host, authority string) {
	start := time.Now()
	ex := &Exchange{
		Time:   start,
		Kind:   "tunnel",
		Method: "CONNECT",
		URL:    authority,
		Host:   authority,
		Path:   "/",
	}
	up, err := net.DialTimeout("tcp", authority, dialTimeout)
	if err != nil {
		_, _ = io.WriteString(client, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
		ex.Status = 502
		ex.Error = "cannot reach " + authority + ": " + err.Error() + "; check the address and that the Mac can reach it"
		p.record(ex)
		return
	}
	if !p.trackAux(up) {
		up.Close()
		return
	}
	defer p.untrackAux(up)
	if _, err := io.WriteString(client, "HTTP/1.1 200 Connection Established\r\n\r\n"); err != nil {
		return
	}
	ex.Status = 200
	var up2down, down2up atomic.Int64
	endPending := p.beginPending(&pendingEntry{time: start, kind: "tunnel", method: "CONNECT", url: authority, req: down2up.Load, res: up2down.Load})
	defer endPending()

	done := make(chan struct{}, 2)
	pipe := func(dst io.Writer, src io.Reader, n *atomic.Int64) {
		_, _ = io.Copy(dst, &countingReader{r: src, n: n})
		done <- struct{}{}
	}
	go pipe(up, client, &down2up)
	go pipe(client.Conn, up, &up2down)
	<-done
	up.Close()
	client.Close()
	<-done
	ex.ReqBytes = down2up.Load()
	ex.ResBytes = up2down.Load()
	ex.Ms = time.Since(start).Milliseconds()
	p.record(ex)
}

type countingReader struct {
	r io.Reader
	n *atomic.Int64
}

func (c *countingReader) Read(b []byte) (int, error) {
	n, err := c.r.Read(b)
	c.n.Add(int64(n))
	return n, err
}
