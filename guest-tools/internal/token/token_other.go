//go:build !windows && !linux

package token

// OEMStrings is unsupported on this platform (used only for host-side unit tests).
func OEMStrings() []string { return nil }
