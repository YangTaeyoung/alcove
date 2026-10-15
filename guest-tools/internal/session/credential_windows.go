//go:build windows

package session

// Credential returns nil: on Windows the agent starts programs as itself.
func (s Session) Credential() any { return nil }
