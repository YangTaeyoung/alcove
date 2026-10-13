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
	"strconv"
	"strings"
	"syscall"
)

//go:embed assets/bootstrap.ps1
var bootstrapScript []byte

//go:embed assets/helper.cs
var helperSource []byte

const createNoWindow = 0x08000000

// Available reports whether this build can start a helper.
func Available() bool { return true }

// DefaultLauncher locks dir and its parent to Administrators and SYSTEM, writes
// the embedded files into it and starts Windows PowerShell from the system
// directory without a console window. When the folders cannot be locked the
// helper is not started. Each start passes the number of helpers this launcher
// started before it as ALCOVE_UIA_START. The helper's environment drops the
// variables that redirect the .NET runtime and PowerShell module loading, and
// its temporary directory is a folder inside the locked directory, so that no
// other process of the user can plant files that the elevated compile reads.
func DefaultLauncher(dir string) Launcher {
	starts := 0
	return func() (io.WriteCloser, io.ReadCloser, func(), error) {
		system, err := systemDirectory()
		if err != nil {
			return nil, nil, nil, err
		}
		if err := LockHelperFolders(filepath.Dir(dir), dir); err != nil {
			return nil, nil, nil, fmt.Errorf("the UI helper folder %s could not be locked (%v); fix its owner and access list, then retry", dir, err)
		}
		if err := writeIfDifferent(filepath.Join(dir, "bootstrap.ps1"), bootstrapScript); err != nil {
			return nil, nil, nil, err
		}
		if err := writeIfDifferent(filepath.Join(dir, "helper.cs"), helperSource); err != nil {
			return nil, nil, nil, err
		}
		tmp := filepath.Join(dir, "tmp")
		if err := os.MkdirAll(tmp, 0o755); err != nil {
			return nil, nil, nil, err
		}
		logFile, err := openCappedLog(filepath.Join(dir, "helper.log"), maxLogBytes)
		if err != nil {
			return nil, nil, nil, err
		}
		cmd := exec.Command(filepath.Join(system, "WindowsPowerShell", "v1.0", "powershell.exe"),
			"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", filepath.Join(dir, "bootstrap.ps1"))
		cmd.Dir = dir
		cmd.Env = append(cleanHelperEnv(tmp), "ALCOVE_UIA_START="+strconv.Itoa(starts))
		starts++
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

// cleanHelperEnv returns the agent's environment without the variables that
// would redirect the .NET runtime (COR_*, COMPlus_*, DOTNET_*) or PowerShell
// module loading (PSModulePath), with TEMP and TMP set to tmp.
func cleanHelperEnv(tmp string) []string {
	env := make([]string, 0, len(os.Environ())+2)
	for _, kv := range os.Environ() {
		eq := strings.IndexByte(kv, '=')
		if eq < 0 {
			continue
		}
		name := strings.ToUpper(kv[:eq])
		if strings.HasPrefix(name, "COR_") || strings.HasPrefix(name, "COMPLUS_") ||
			strings.HasPrefix(name, "DOTNET_") || name == "PSMODULEPATH" || name == "TEMP" || name == "TMP" {
			continue
		}
		env = append(env, kv)
	}
	return append(env, "TEMP="+tmp, "TMP="+tmp)
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
