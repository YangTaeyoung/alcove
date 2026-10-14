//go:build !windows

package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"syscall"
)

// openNoFollow makes an open fail when the last element of the path is a
// symbolic link.
const openNoFollow = syscall.O_NOFOLLOW

// installLogFolder is the folder of install.log outside Windows.
const installLogFolder = "/var/log/alcove"

// refuseReparse reports an error when path is a symbolic link.
func refuseReparse(path string) error {
	if fi, err := os.Lstat(path); err == nil && fi.Mode()&os.ModeSymlink != 0 {
		return errors.New(path + " is a symbolic link; remove it")
	}
	return nil
}

// lockDataFolder returns installLogFolder after ownLogFolder made it.
func lockDataFolder() (string, error) {
	return ownLogFolder(installLogFolder)
}

// ownLogFolder creates dir with access for its owner only, or narrows an
// existing dir to that access, and returns it. A dir that is a symbolic link,
// not a directory or owned by another user than the effective one is refused.
func ownLogFolder(dir string) (string, error) {
	if err := os.Mkdir(dir, 0o700); err != nil && !errors.Is(err, fs.ErrExist) {
		return "", err
	}
	fi, err := os.Lstat(dir)
	if err != nil {
		return "", err
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !fi.IsDir() || !ok || int(st.Uid) != os.Geteuid() {
		return "", fmt.Errorf("%s is not a plain folder owned by this user; remove it and run alcove-agent --install again", dir)
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return "", err
	}
	return dir, nil
}

// installAtLogon installs a systemd system unit on Linux whose command line
// carries peerArgs.
func installAtLogon(port int, allowExec bool, peerArgs []string, _ string) error {
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
	for _, a := range peerArgs {
		extra += " " + a
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
