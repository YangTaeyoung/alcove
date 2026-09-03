//go:build !windows

package server

import (
	"errors"
	"os/exec"
)

func platformShutdown() error {
	if _, err := exec.LookPath("systemctl"); err == nil {
		return exec.Command("systemctl", "poweroff").Run()
	}
	return exec.Command("shutdown", "-h", "now").Run()
}

func currentResolution() (int, int, bool) { return 0, 0, false }

func setResolution(w, h int) error {
	return errors.New("resolution change not supported on this platform")
}
