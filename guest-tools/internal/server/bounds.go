package server

import (
	"unicode/utf8"
)

const (
	execListCmdChars  = 4096
	procListCmdChars  = 8192
	clipboardMaxBytes = 700000
)

// cutChars keeps the first max characters of s and appends "…" when it cut.
func cutChars(s string, max int) string {
	n := 0
	for i := range s {
		if n == max {
			return s[:i] + "…"
		}
		n++
	}
	return s
}

// cutUTF8Bytes keeps the longest prefix of s that is at most max bytes and
// ends on a character boundary.
func cutUTF8Bytes(s string, max int) string {
	if len(s) <= max {
		return s
	}
	for max > 0 && !utf8.RuneStart(s[max]) {
		max--
	}
	return s[:max]
}

// streamText converts the bytes a ring kept to a string. When older bytes were
// dropped (cut), leading continuation bytes of a split character are skipped.
func streamText(b []byte, cut bool) string {
	if cut {
		for skip := 0; skip < utf8.UTFMax-1 && len(b) > 0 && !utf8.RuneStart(b[0]); skip++ {
			b = b[1:]
		}
	}
	return text(b)
}
