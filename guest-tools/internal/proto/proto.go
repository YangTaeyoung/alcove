// Package proto defines the newline-delimited JSON messages exchanged between
// the Alcove app and the guest agent (docs/agent-protocol.md).
package proto

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
)

const Version = 1

// RPCVersion is the request/response layer revision announced in hello.
const RPCVersion = 2

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

// Bool returns a boolean field or false.
func (m Message) Bool(key string) bool {
	b, _ := m[key].(bool)
	return b
}

// Has reports whether the key is present.
func (m Message) Has(key string) bool {
	_, ok := m[key]
	return ok
}

// Strings returns a JSON array of strings, or nil when the field is missing,
// not an array, or holds a non-string element.
func (m Message) Strings(key string) []string {
	arr, ok := m[key].([]any)
	if !ok {
		return nil
	}
	out := make([]string, 0, len(arr))
	for _, v := range arr {
		s, ok := v.(string)
		if !ok {
			return nil
		}
		out = append(out, s)
	}
	return out
}

// StringMap returns a JSON object of string values, or nil when the field is
// missing or not an object. Non-string values are skipped.
func (m Message) StringMap(key string) map[string]string {
	obj, ok := m[key].(map[string]any)
	if !ok {
		return nil
	}
	out := make(map[string]string, len(obj))
	for k, v := range obj {
		if s, ok := v.(string); ok {
			out[k] = s
		}
	}
	return out
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

// ErrNotMessage is the error of NextStrict for a line that is not a JSON
// object with a string "t".
var ErrNotMessage = errors.New("a line is not a JSON object with a string t")

// Next returns the next message, skipping empty lines and lines that are not
// a JSON object with a string "t"; io.EOF when the stream ends.
func (r *Reader) Next() (Message, error) {
	return r.next(false)
}

// NextStrict returns the next message, skipping empty lines; a line that is
// not a JSON object with a string "t" returns ErrNotMessage. A line cut off
// by a read error returns that error, and io.EOF the end of the stream.
func (r *Reader) NextStrict() (Message, error) {
	return r.next(true)
}

func (r *Reader) next(strict bool) (Message, error) {
	for r.sc.Scan() {
		line := r.sc.Bytes()
		if len(line) == 0 {
			continue
		}
		var m Message
		if err := json.Unmarshal(line, &m); err != nil || m.Type() == "" {
			if !strict {
				continue
			}
			if err := r.sc.Err(); err != nil {
				return nil, err
			}
			return nil, ErrNotMessage
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
	b, err := Encode(m)
	if err != nil {
		return err
	}
	_, err = w.w.Write(b)
	return err
}

// Encode returns the line Send writes for m, newline included. '<', '>' and
// '&' are written as they are.
func Encode(m Message) ([]byte, error) {
	if m.Type() == "" {
		return nil, errors.New("message without type")
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(m); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
