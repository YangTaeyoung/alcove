//go:build !windows

package server

import (
	"errors"
	"os"
	"os/exec"
	"syscall"
	"time"
)

func platformShutdown() error {
	if _, err := exec.LookPath("systemctl"); err == nil {
		return exec.Command("systemctl", "poweroff").Run()
	}
	return exec.Command("shutdown", "-h", "now").Run()
}

// resolutionSupported says whether setResolution can change the display mode.
const resolutionSupported = false

// clipboardPollFastest and clipboardPollSlowest bound the time between two
// clipboard polls, which run a clipboard tool here.
const (
	clipboardPollFastest = 500 * time.Millisecond
	clipboardPollSlowest = 4 * time.Second
)

func currentResolution() (int, int, bool) { return 0, 0, false }

func setResolution(w, h int) error {
	return errors.New("resolution change not supported on this platform")
}

// volumeRoots returns the root folder.
func volumeRoots(string) ([]string, error) { return []string{"/"}, nil }

// platformFileID returns the device and inode of path.
func platformFileID(path string, follow bool) (fileID, error) {
	stat := os.Lstat
	if follow {
		stat = os.Stat
	}
	fi, err := stat(path)
	if err != nil {
		return fileID{}, err
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return fileID{}, errors.New("the file system reports no device and inode")
	}
	return fileID{volume: uint64(st.Dev), index: uint64(st.Ino)}, nil
}

// platformEntryOwner reports no owners on this system.
func platformEntryOwner(string) (string, bool) { return "", false }
