//go:build !windows

package main

import (
	"fmt"
	"os"
	"os/exec"
)

// refuseReparse never refuses outside Windows; there are no junctions to plant.
func refuseReparse(string) error { return nil }

// installAtLogon installs a systemd system unit on Linux.
func installAtLogon(port int, allowExec bool) error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	dst := "/usr/local/bin/alcove-agent"
	if data, err := os.ReadFile(exe); err == nil {
		_ = os.WriteFile(dst, data, 0o755)
	}
	extra := ""
	if allowExec {
		extra = " --allow-exec"
	}
	unit := fmt.Sprintf(`[Unit]
Description=Alcove guest agent
After=network.target

[Service]
ExecStart=%s --port %d%s
Restart=always

[Install]
WantedBy=multi-user.target
`, dst, port, extra)
	if err := os.WriteFile("/etc/systemd/system/alcove-agent.service", []byte(unit), 0o644); err != nil {
		return err
	}
	if out, err := exec.Command("systemctl", "enable", "--now", "alcove-agent").CombinedOutput(); err != nil {
		return fmt.Errorf("systemctl: %v: %s", err, out)
	}
	return nil
}
