//go:build windows

package uia

import (
	_ "embed"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"
	"time"
)

//go:embed assets/bootstrap.ps1
var bootstrapScript []byte

//go:embed assets/helper.cs
var helperSource []byte

const createNoWindow = 0x08000000

// stderrDrainWait is how long after the helper process ended its remaining
// stderr output is still copied to the log.
const stderrDrainWait = 2 * time.Second

// Available reports whether this build can start a helper.
func Available() bool { return true }

// DefaultLauncher returns a launcher that waits for the PowerShell process of
// its previous start to end, locks dir and its parent to Administrators and
// SYSTEM, writes the embedded files into dir and starts Windows PowerShell
// from the system directory without a console window. The helper is not
// started when the previous process still runs after previousExitWait or when
// the folders cannot be locked. Each start passes the number of helpers this
// launcher started before it as ALCOVE_UIA_START. The helper's environment is
// cleanHelperEnv of the agent's, with the tmp folder inside dir as its
// temporary directory.
func DefaultLauncher(dir string) Launcher {
	starts := 0
	var gate exitGate
	return func() (io.WriteCloser, io.ReadCloser, func(), error) {
		system, err := systemDirectory()
		if err != nil {
			return nil, nil, nil, err
		}
		if !gate.waitPrevious(previousExitWait) {
			return nil, nil, nil, fmt.Errorf("the previous UI helper process has not ended after %d s; retry", int(previousExitWait.Seconds()))
		}
		if err := LockHelperFolders(filepath.Dir(dir), dir); err != nil {
			return nil, nil, nil, fmt.Errorf("the UI helper folder %s could not be locked (%v); fix its owner and access list, then retry", dir, err)
		}
		if err := os.WriteFile(filepath.Join(dir, "bootstrap.ps1"), bootstrapScript, 0o644); err != nil {
			return nil, nil, nil, notPrepared(dir, err)
		}
		if err := os.WriteFile(filepath.Join(dir, "helper.cs"), helperSource, 0o644); err != nil {
			return nil, nil, nil, notPrepared(dir, err)
		}
		tmp := filepath.Join(dir, "tmp")
		if err := os.Mkdir(tmp, 0o755); err != nil {
			return nil, nil, nil, notPrepared(dir, err)
		}
		logFile, err := openCappedLog(filepath.Join(dir, "helper.log"), maxLogBytes)
		if err != nil {
			return nil, nil, nil, notPrepared(dir, err)
		}
		cmd := exec.Command(filepath.Join(system, "WindowsPowerShell", "v1.0", "powershell.exe"),
			"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", filepath.Join(dir, "bootstrap.ps1"))
		cmd.Dir = dir
		cmd.Env = append(cleanHelperEnv(os.Environ(), tmp), "ALCOVE_UIA_START="+strconv.Itoa(starts))
		cmd.Stderr = logFile
		cmd.WaitDelay = stderrDrainWait
		cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: createNoWindow}
		childIn, stdin, err := os.Pipe()
		if err != nil {
			logFile.Close()
			return nil, nil, nil, err
		}
		stdout, childOut, err := os.Pipe()
		if err != nil {
			childIn.Close()
			stdin.Close()
			logFile.Close()
			return nil, nil, nil, err
		}
		cmd.Stdin, cmd.Stdout = childIn, childOut
		err = cmd.Start()
		childIn.Close()
		childOut.Close()
		if err != nil {
			stdin.Close()
			stdout.Close()
			logFile.Close()
			return nil, nil, nil, err
		}
		starts++
		ended := gate.started()
		go func() {
			_ = cmd.Wait()
			logFile.Close()
			ended()
		}()
		kill := func() { _ = cmd.Process.Kill() }
		return stdin, stdout, kill, nil
	}
}
