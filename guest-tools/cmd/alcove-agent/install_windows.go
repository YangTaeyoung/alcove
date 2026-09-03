//go:build windows

package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

// installAtLogon registers a scheduled task that starts the agent in the
// interactive session at logon (the clipboard is per session, so a service
// in session 0 could not see it) and opens the firewall port.
func installAtLogon(port int, allowExec bool) error {
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
	args := fmt.Sprintf(`--port %d --log "C:\ProgramData\Alcove\agent.log"`, port)
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
