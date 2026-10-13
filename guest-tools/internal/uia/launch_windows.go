//go:build windows

package uia

import (
	"bytes"
	_ "embed"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
)

//go:embed assets/bootstrap.ps1
var bootstrapScript []byte

//go:embed assets/helper.cs
var helperSource []byte

const createNoWindow = 0x08000000

// Available reports whether this build can start a helper.
func Available() bool { return true }

// DefaultLauncher writes the embedded files below dir and starts
// powershell.exe without a console window.
func DefaultLauncher(dir string) Launcher {
	return func() (io.WriteCloser, io.ReadCloser, func(), error) {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, nil, nil, err
		}
		if err := writeIfDifferent(filepath.Join(dir, "bootstrap.ps1"), bootstrapScript); err != nil {
			return nil, nil, nil, err
		}
		if err := writeIfDifferent(filepath.Join(dir, "helper.cs"), helperSource); err != nil {
			return nil, nil, nil, err
		}
		logFile, err := os.OpenFile(filepath.Join(dir, "helper.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
		if err != nil {
			return nil, nil, nil, err
		}
		cmd := exec.Command("powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
			"-File", filepath.Join(dir, "bootstrap.ps1"))
		cmd.Dir = dir
		cmd.Stderr = logFile
		cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: createNoWindow}
		stdin, err := cmd.StdinPipe()
		if err != nil {
			logFile.Close()
			return nil, nil, nil, err
		}
		stdout, err := cmd.StdoutPipe()
		if err != nil {
			logFile.Close()
			return nil, nil, nil, err
		}
		if err := cmd.Start(); err != nil {
			logFile.Close()
			return nil, nil, nil, err
		}
		kill := func() {
			_ = cmd.Process.Kill()
			go func() {
				_ = cmd.Wait()
				logFile.Close()
			}()
		}
		return stdin, stdout, kill, nil
	}
}

func writeIfDifferent(path string, want []byte) error {
	if have, err := os.ReadFile(path); err == nil && bytes.Equal(have, want) {
		return nil
	}
	if err := os.WriteFile(path, want, 0o644); err != nil {
		return fmt.Errorf("write %s: %v", path, err)
	}
	return nil
}
