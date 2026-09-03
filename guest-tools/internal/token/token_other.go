//go:build !windows && !linux

package token

// Read is unsupported on this platform (used only for host-side unit tests).
func Read() string { return "" }
