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
	serveDone := make(chan struct{})
	go func() {
		defer close(serveDone)
		_ = p.Serve(l)
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

	sc := bufio.NewScanner(in)
	sc.Buffer(make([]byte, 0, 64*1024), maxControlLine)
	for sc.Scan() {
		line := bytes.TrimSpace(sc.Bytes())
		if len(line) == 0 {
			continue
		}
		if err := enc.Encode(dispatch(p, line)); err != nil {
			return err
		}
	}
	if err := sc.Err(); err != nil {
		_ = enc.Encode(map[string]any{"ok": false, "error": fmt.Sprintf("the request line is unreadable (%v); keep requests under 16 MiB", err)})
		return err
	}
	return nil
}

func dispatch(p *Proxy, line []byte) map[string]any {
	var req map[string]any
	if err := json.Unmarshal(line, &req); err != nil {
		return map[string]any{"ok": false, "error": "the request is not a JSON object: " + err.Error()}
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
