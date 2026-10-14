//go:build !windows

package uia

import (
	"errors"
	"io"
)

// Available reports whether this build can start a helper.
func Available() bool { return false }

// LockHelperFolders does nothing on systems without the helper.
func LockHelperFolders(parent, dir string) ([]string, error) { return nil, nil }

// LockDeployRoot does nothing on systems without the helper.
func LockDeployRoot(dir string) (string, error) { return "", nil }

// DeployRootLocked reports false on systems without the helper.
func DeployRootLocked(dir string) bool { return false }

// DefaultLauncher returns a launcher that always fails on this system.
func DefaultLauncher(dir string, logf func(format string, args ...any)) Launcher {
	return func(<-chan struct{}) (io.WriteCloser, io.ReadCloser, func(), error) {
		return nil, nil, nil, errors.New("UI Automation is only available on Windows guests")
	}
}
