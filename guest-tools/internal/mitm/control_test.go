package mitm

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"strings"
	"testing"
	"time"
)

func TestControlLoop(t *testing.T) {
	ca, err := LoadOrCreateCA(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	p := NewProxy(ca)
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	done := make(chan error, 1)
	go func() {
		err := RunControl(p, l, inR, outW)
		outW.Close()
		done <- err
	}()
	out := bufio.NewReader(outR)
	readLine := func() map[string]any {
		t.Helper()
		line, err := out.ReadBytes('\n')
		if err != nil {
			t.Fatalf("read: %v", err)
		}
		m := map[string]any{}
		if err := json.Unmarshal(line, &m); err != nil {
			t.Fatalf("bad line %q", line)
		}
		return m
	}
	send := func(s string) { fmt.Fprintln(inW, s) }

	ready := readLine()
	if ready["ev"] != "ready" || int(ready["port"].(float64)) != l.Addr().(*net.TCPAddr).Port || ready["ca"] != ca.PEMPath() {
		t.Fatalf("ready %v", ready)
	}
	send(`{"id":1,"op":"config","hosts":["*.x.test"],"secrets":false}`)
	if r := readLine(); r["id"].(float64) != 1 || r["ok"] != true {
		t.Fatalf("config reply %v", r)
	}
	send(`{"id":2,"op":"list"}`)
	if r := readLine(); r["ok"] != true || len(r["exchanges"].([]any)) != 0 {
		t.Fatalf("list reply %v", r)
	}
	send(`{"id":3,"op":"frobnicate"}`)
	if r := readLine(); r["ok"] != false || r["error"] != "unknown op 'frobnicate'" || r["id"].(float64) != 3 {
		t.Fatalf("unknown op reply %v", r)
	}
	send(`{"id":4,"op":"config","bodies":"no"}`)
	if r := readLine(); r["ok"] != false || !strings.Contains(r["error"].(string), "bodies") {
		t.Fatalf("type error reply %v", r)
	}
	send(`not json`)
	if r := readLine(); r["ok"] != false {
		t.Fatalf("garbage reply %v", r)
	}
	send(`{"id":5,"op":"list","since":0}`)
	if r := readLine(); r["id"].(float64) != 5 {
		t.Fatalf("reply after garbage %v", r)
	}
	inW.Close()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("RunControl: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("RunControl did not return after stdin closed")
	}
	if _, err := net.DialTimeout("tcp", l.Addr().String(), time.Second); err == nil {
		t.Fatal("the listener is still open after exit")
	}
}
