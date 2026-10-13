//go:build !windows

package uia

import (
	"errors"
	"io"
)

// Available reports whether this build can start a helper.
func Available() bool { return false }

// DefaultLauncher returns a launcher that always fails on this system.
func DefaultLauncher(dir string) Launcher {
	return func() (io.WriteCloser, io.ReadCloser, func(), error) {
		return nil, nil, nil, errors.New("UI Automation is only available on Windows guests")
	}
}
