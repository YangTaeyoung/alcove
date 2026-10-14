package mitm

import (
	"io"
	"net/http"
	"time"
)

// switchProtocols completes a WebSocket upgrade the upstream accepted with
// resp: it takes over the client connection, sends it the 101 answer and
// copies bytes both ways until either side ends, then closes both. The row
// becomes a tunnel row with status 101; its byte counts are the bytes after
// the handshake, and the frames are not kept.
func (p *Proxy) switchProtocols(w http.ResponseWriter, resp *http.Response, ex *Exchange, resCap *capBuf, sw *switchScope) {
	up, ok := resp.Body.(io.ReadWriteCloser)
	if !ok {
		ex.Error = "the upstream switched protocols without a usable connection"
		respondText(w, ex, resCap, http.StatusBadGateway, "alcove-proxy could not join the WebSocket to the upstream; exclude this host with hosts")
		return
	}
	conn, brw, err := http.NewResponseController(w).Hijack()
	if err != nil {
		ex.Error = "the client connection cannot carry a WebSocket: " + err.Error()
		respondText(w, ex, resCap, http.StatusBadGateway, "alcove-proxy cannot pass a WebSocket over this connection; connect with HTTP/1.1 or exclude this host with hosts")
		return
	}
	sw.taken = true
	defer conn.Close()
	_ = conn.SetDeadline(time.Time{})

	h := resp.Header.Clone()
	removeHopByHop(h)
	h.Set("Connection", "Upgrade")
	h["Upgrade"] = resp.Header.Values("Upgrade")
	ex.Kind = "tunnel"
	ex.Status = resp.StatusCode
	ex.ResHeaders = headerPairs(h)
	sw.pe.switched.Store(true)
	sw.reqCap.stopKeeping()
	resCap.stopKeeping()

	_, _ = io.WriteString(brw, "HTTP/1.1 "+resp.Status+"\r\n")
	_ = h.Write(brw)
	_, _ = io.WriteString(brw, "\r\n")
	if err := brw.Flush(); err != nil {
		ex.Error = clientClosed
		return
	}

	done := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(up, io.TeeReader(brw.Reader, sw.reqCap))
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(conn, io.TeeReader(up, resCap))
		done <- struct{}{}
	}()
	<-done
	conn.Close()
	up.Close()
	<-done
}
