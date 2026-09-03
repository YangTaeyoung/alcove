// Package proto defines the newline-delimited JSON messages exchanged between
// the Alcove app and the guest agent (docs/agent-protocol.md).
package proto

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
)

const Version = 1

// Message is a loosely typed envelope: every message carries "t"; the other
// fields are decoded on demand.
type Message map[string]any

// Type returns the discriminator.
func (m Message) Type() string {
	s, _ := m["t"].(string)
	return s
}

// String returns a string field or "".
func (m Message) String(key string) string {
	s, _ := m[key].(string)
	return s
}

// Int returns an integer field (JSON numbers decode as float64) or 0.
func (m Message) Int(key string) int {
	switch v := m[key].(type) {
	case float64:
		return int(v)
	case int:
		return v
	}
	return 0
}

// MaxLine bounds a single message (a file chunk of 256 KiB base64-encodes to ~350 KiB).
const MaxLine = 1 << 20

// Reader decodes messages from a stream.
type Reader struct {
	sc *bufio.Scanner
}

func NewReader(r io.Reader) *Reader {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), MaxLine)
	return &Reader{sc: sc}
}

// Next returns the next message; io.EOF when the stream ends.
func (r *Reader) Next() (Message, error) {
	for r.sc.Scan() {
		line := r.sc.Bytes()
		if len(line) == 0 {
			continue
		}
		var m Message
		if err := json.Unmarshal(line, &m); err != nil {
			continue // tolerate garbage lines
		}
		if m.Type() == "" {
			continue
		}
		return m, nil
	}
	if err := r.sc.Err(); err != nil {
		return nil, err
	}
	return nil, io.EOF
}

// Writer encodes messages one per line.
type Writer struct {
	w io.Writer
}

func NewWriter(w io.Writer) *Writer { return &Writer{w: w} }

func (w *Writer) Send(m Message) error {
	if m.Type() == "" {
		return errors.New("message without type")
	}
	b, err := json.Marshal(m)
	if err != nil {
		return err
	}
	b = append(b, '\n')
	_, err = w.w.Write(b)
	return err
}
