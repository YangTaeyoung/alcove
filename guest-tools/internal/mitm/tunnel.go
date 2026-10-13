package mitm

import (
	"io"
	"net"
	"sync/atomic"
	"time"
)

// tunnel connects to the upstream authority and copies bytes both ways until
// either side ends, then records a tunnel row with the byte counts.
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
	defer up.Close()
	if _, err := io.WriteString(client, "HTTP/1.1 200 Connection Established\r\n\r\n"); err != nil {
		return
	}
	ex.Status = 200
	var up2down, down2up atomic.Int64
	done := make(chan struct{}, 2)
	pipe := func(dst net.Conn, src io.Reader, n *atomic.Int64) {
		c, _ := io.Copy(dst, src)
		n.Store(c)
		if tc, ok := dst.(*net.TCPConn); ok {
			_ = tc.CloseWrite()
		}
		done <- struct{}{}
	}
	go pipe(up, client, &down2up)
	go pipe(client.Conn, up, &up2down)
	<-done
	<-done
	ex.ReqBytes = down2up.Load()
	ex.ResBytes = up2down.Load()
	ex.Ms = time.Since(start).Milliseconds()
	p.record(ex)
}
