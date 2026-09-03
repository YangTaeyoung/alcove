package proto

import (
	"bytes"
	"io"
	"strings"
	"testing"
)

func TestRoundTripAndTolerance(t *testing.T) {
	var buf bytes.Buffer
	w := NewWriter(&buf)
	if err := w.Send(Message{"t": "hello", "v": Version, "caps": []string{"clipboard"}}); err != nil {
		t.Fatal(err)
	}
	buf.WriteString("garbage\n\n{\"no\":\"type\"}\n{\"t\":\"ping\"}\n")
	r := NewReader(&buf)
	m, err := r.Next()
	if err != nil || m.Type() != "hello" || m.Int("v") != 1 {
		t.Fatalf("hello: %v %v", m, err)
	}
	m, err = r.Next()
	if err != nil || m.Type() != "ping" {
		t.Fatalf("ping: %v %v", m, err)
	}
	if _, err = r.Next(); err != io.EOF {
		t.Fatalf("want EOF, got %v", err)
	}
	if err := w.Send(Message{}); err == nil {
		t.Fatal("untyped message must be rejected")
	}
}

func TestLongLineIsAnError(t *testing.T) {
	r := NewReader(strings.NewReader(strings.Repeat("x", MaxLine+10) + "\n"))
	if _, err := r.Next(); err == nil {
		t.Fatal("expected error for oversized line")
	}
}
