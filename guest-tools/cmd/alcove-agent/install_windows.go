//go:build windows

package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/uia"
)

// refuseReparse reports an error when path is a reparse point (a junction or
// symbolic link), so a log file is not opened through a planted link.
func refuseReparse(path string) error {
	name, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	const invalid = 0xFFFFFFFF
	const reparse = 0x00000400
	r, _, _ := syscall.NewLazyDLL("kernel32.dll").NewProc("GetFileAttributesW").Call(uintptr(unsafe.Pointer(name)))
	if uint32(r) != invalid && uint32(r)&reparse != 0 {
		return errors.New(path + " is a reparse point; remove it")
	}
	return nil
}

// lockDataFolder locks the Alcove folder under %ProgramData% and its uia
// folder to Administrators and SYSTEM and returns the Alcove folder.
func lockDataFolder() (string, error) {
	base := os.Getenv("ProgramData")
	if base == "" {
		return "", errors.New("the ProgramData environment variable is empty, so the Alcove data folder cannot be located; set it (normally C:\\ProgramData) and run alcove-agent --install again")
	}
	dir := filepath.Join(base, "Alcove")
	if err := uia.LockHelperFolders(dir, filepath.Join(dir, "uia")); err != nil {
		return "", fmt.Errorf("the Alcove data folder %s could not be locked (%v); fix its owner and access list with icacls, then run alcove-agent --install again", dir, err)
	}
	return dir, nil
}

// installAtLogon registers a scheduled task that starts the agent in the
// interactive session at logon (the clipboard is per session, so a service
// in session 0 could not see it) with its log in dataDir, opens the firewall
// port and starts the task.
func installAtLogon(port int, allowExec bool, dataDir string) error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	dir := `C:\Program Files\Alcove`
	_ = os.MkdirAll(dir, 0o755)
	dst := dir + `\alcove-agent.exe`
	if !strings.EqualFold(exe, dst) {
		data, err := os.ReadFile(exe)
		if err != nil {
			return err
		}
		// a running copy locks the file: stop the task and any agent process first
		_ = exec.Command("schtasks", "/End", "/TN", "AlcoveAgent").Run()
		// kill running agents, but not this installer (same image name)
		_ = exec.Command("taskkill", "/F", "/FI", "IMAGENAME eq alcove-agent.exe", "/FI", fmt.Sprintf("PID ne %d", os.Getpid())).Run()
		var werr error
		for i := 0; i < 20; i++ {
			werr = os.WriteFile(dst, data, 0o755)
			if werr == nil {
				break
			}
			time.Sleep(250 * time.Millisecond)
		}
		if werr != nil {
			return fmt.Errorf("copy to %s: %w", dst, werr)
		}
		if st, err := os.Stat(dst); err != nil || st.Size() != int64(len(data)) {
			return fmt.Errorf("copy to %s verification failed", dst)
		}
	}
	args := fmt.Sprintf(`--port %d --log "%s"`, port, filepath.Join(dataDir, "agent.log"))
	if allowExec {
		args += " --allow-exec"
	}
	tr := fmt.Sprintf(`"%s" %s`, dst, args)
	_ = exec.Command("schtasks", "/Delete", "/TN", "AlcoveAgent", "/F").Run()
	if out, err := exec.Command("schtasks", "/Create", "/TN", "AlcoveAgent", "/SC", "ONLOGON", "/RL", "HIGHEST", "/F", "/TR", tr).CombinedOutput(); err != nil {
		return fmt.Errorf("schtasks: %v: %s", err, out)
	}
	_ = exec.Command("netsh", "advfirewall", "firewall", "delete", "rule", "name=AlcoveAgent").Run()
	if out, err := exec.Command("netsh", "advfirewall", "firewall", "add", "rule", "name=AlcoveAgent", "dir=in", "action=allow", "protocol=TCP", fmt.Sprintf("localport=%d", port)).CombinedOutput(); err != nil {
		return fmt.Errorf("netsh: %v: %s", err, out)
	}
	// start it now in this session too
	if out, err := exec.Command("schtasks", "/Run", "/TN", "AlcoveAgent").CombinedOutput(); err != nil {
		return fmt.Errorf("schtasks run: %v: %s", err, out)
	}
	return nil
}
