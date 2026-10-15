package proto

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"testing"
)

func TestWriterKeepsAngleBracketsAndAmpersandsAsTheyAre(t *testing.T) {
	var buf bytes.Buffer
	if err := NewWriter(&buf).Send(Message{"t": "res", "name": "<a href=\"x\">&amp;</a>"}); err != nil {
		t.Fatal(err)
	}
	if want := `{"name":"<a href=\"x\">&amp;</a>","t":"res"}` + "\n"; buf.String() != want {
		t.Fatalf("line %q, expected %q", buf.String(), want)
	}
}

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

func TestNextStrictReturnsErrNotMessageForALineThatIsNotAMessage(t *testing.T) {
	for _, line := range []string{"garbage", `{"no":"type"}`, `["t"]`, `{"t":1}`, "null"} {
		r := NewReader(strings.NewReader("\n" + line + "\n{\"t\":\"ping\"}\n"))
		if m, err := r.NextStrict(); err != ErrNotMessage {
			t.Fatalf("%s: NextStrict returned %v, %v", line, m, err)
		}
		if m, err := r.NextStrict(); err != nil || m.Type() != "ping" {
			t.Fatalf("%s: the next line read as %v, %v", line, m, err)
		}
	}
}

// failAfter returns data and then err.
type failAfter struct {
	data []byte
	err  error
}

func (f *failAfter) Read(p []byte) (int, error) {
	if len(f.data) == 0 {
		return 0, f.err
	}
	n := copy(p, f.data)
	f.data = f.data[n:]
	return n, nil
}

func TestNextStrictReturnsTheReadErrorThatCutALineOff(t *testing.T) {
	cut := errors.New("cut")
	r := NewReader(&failAfter{data: []byte(`{"t":"ping"}` + "\n" + `{"t":"pi`), err: cut})
	if m, err := r.NextStrict(); err != nil || m.Type() != "ping" {
		t.Fatalf("first line %v, %v", m, err)
	}
	if m, err := r.NextStrict(); err != cut {
		t.Fatalf("cut line %v, %v", m, err)
	}
}

func TestLongLineIsAnError(t *testing.T) {
	r := NewReader(strings.NewReader(strings.Repeat("x", MaxLine+10) + "\n"))
	if _, err := r.Next(); err == nil {
		t.Fatal("expected error for oversized line")
	}
}

func TestMessageAccessors(t *testing.T) {
	var m Message
	if err := json.Unmarshal([]byte(`{"t":"req","on":true,"off":false,"n":null,"s":"x","list":["a","b"],"mixed":["a",1],"env":{"K":"v","N":1}}`), &m); err != nil {
		t.Fatal(err)
	}
	if !m.Bool("on") || m.Bool("off") || m.Bool("s") || m.Bool("missing") {
		t.Fatal("Bool")
	}
	if !m.Has("off") || !m.Has("n") || m.Has("missing") {
		t.Fatal("Has")
	}
	if got := m.Strings("list"); len(got) != 2 || got[0] != "a" || got[1] != "b" {
		t.Fatalf("Strings %v", got)
	}
	if m.Strings("mixed") != nil || m.Strings("s") != nil || m.Strings("missing") != nil {
		t.Fatal("Strings must be nil for non string arrays")
	}
	if got := m.StringMap("env"); len(got) != 1 || got["K"] != "v" {
		t.Fatalf("StringMap %v", got)
	}
	if m.StringMap("s") != nil || m.StringMap("missing") != nil {
		t.Fatal("StringMap must be nil for non objects")
	}
}
