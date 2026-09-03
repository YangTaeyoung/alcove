// Package clipboard reads and writes the guest's text clipboard.
package clipboard

// Clipboard is a platform text clipboard.
type Clipboard interface {
	// Available reports whether a clipboard exists in this session.
	Available() bool
	// Text returns the current text, or "" when the clipboard holds no text.
	Text() (string, error)
	// SetText replaces the clipboard content.
	SetText(string) error
	// Sequence is a value that changes whenever the clipboard content changes
	// (used for cheap polling); implementations without one return a hash.
	Sequence() uint64
}
