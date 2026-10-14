package mitm

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
)

const maxControlLine = 16 << 20

// RunControl serves p on l and answers JSON-line requests from in on out. It
// prints a ready event first and returns after in ends, with the listener and
// all proxy connections closed.
func RunControl(p *Proxy, l net.Listener, in io.Reader, out io.Writer) error {
	serveErr := make(chan error, 1)
	serveDone := make(chan struct{})
	go func() {
		defer close(serveDone)
		if err := p.Serve(l); err != nil {
			serveErr <- err
		}
	}()
	defer func() {
		p.Close()
		l.Close()
		<-serveDone
	}()

	enc := json.NewEncoder(out)
	port := 0
	if a, ok := l.Addr().(*net.TCPAddr); ok {
		port = a.Port
	}
	if err := enc.Encode(map[string]any{"ev": "ready", "port": port, "ca": p.ca.PEMPath()}); err != nil {
		return err
	}

	lines := make(chan []byte)
	scanErr := make(chan error, 1)
	go func() {
		sc := bufio.NewScanner(in)
		sc.Buffer(make([]byte, 0, 64*1024), maxControlLine)
		for sc.Scan() {
			line := bytes.TrimSpace(sc.Bytes())
			if len(line) == 0 {
				continue
			}
			lines <- append([]byte(nil), line...)
		}
		scanErr <- sc.Err()
	}()
	for {
		select {
		case line := <-lines:
			if err := enc.Encode(dispatch(p, line)); err != nil {
				return err
			}
		case err := <-scanErr:
			if err != nil {
				_ = enc.Encode(map[string]any{"ok": false, "error": fmt.Sprintf("the request line is unreadable (%v); keep requests under 16 MiB", err)})
			}
			return err
		case err := <-serveErr:
			_ = enc.Encode(map[string]any{"ev": "fatal", "error": "the proxy stopped accepting connections (" + err.Error() + "); stop the capture and start a new one"})
			return err
		}
	}
}

func dispatch(p *Proxy, line []byte) map[string]any {
	var req map[string]any
	if err := json.Unmarshal(line, &req); err != nil {
		return map[string]any{"ok": false, "error": "the request is not a JSON object (" + err.Error() + "); send one JSON object per line"}
	}
	reply := map[string]any{}
	if id, ok := req["id"]; ok {
		reply["id"] = id
	}
	op, _ := req["op"].(string)
	delete(req, "id")
	delete(req, "op")
	res, err := p.Handle(op, req)
	if err != nil {
		reply["ok"] = false
		reply["error"] = err.Error()
		return reply
	}
	for k, v := range res {
		reply[k] = v
	}
	reply["ok"] = true
	return reply
}
