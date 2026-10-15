//go:build !windows

package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strings"
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

// installAtLogon installs the running binary as /usr/local/bin/alcove-agent
// and the systemd system unit alcove-agent.service, whose command line
// carries peerArgs, and starts or restarts the service.
func installAtLogon(port int, allowExec bool, peerArgs []string, _ string) error {
	exe, err := os.Executable()
	if err != nil {
		return fmt.Errorf("the path of the running alcove-agent cannot be read (%v); run it by its full path", err)
	}
	in := systemdInstall{exe: exe, bin: "/usr/local/bin/alcove-agent", unit: "/etc/systemd/system/alcove-agent.service",
		systemctl: func(args ...string) ([]byte, error) { return exec.Command("systemctl", args...).CombinedOutput() }}
	return in.run(port, allowExec, peerArgs)
}

// systemdInstall copies exe to bin, writes the unit file unit and runs
// systemctl.
type systemdInstall struct {
	exe, bin, unit string
	systemctl      func(args ...string) ([]byte, error)
}

// run installs the binary, writes the unit and runs systemctl daemon-reload,
// enable and restart, stopping at the first step that fails.
func (in systemdInstall) run(port int, allowExec bool, peerArgs []string) error {
	if err := in.copyBinary(); err != nil {
		return err
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
`, in.bin, port, extra)
	if err := os.WriteFile(in.unit, []byte(unit), 0o644); err != nil {
		return fmt.Errorf("cannot write %s (%v); run alcove-agent --install as root", in.unit, err)
	}
	for _, step := range [][]string{{"daemon-reload"}, {"enable", "alcove-agent"}, {"restart", "alcove-agent"}} {
		if out, err := in.systemctl(step...); err != nil {
			return fmt.Errorf("systemctl %s failed (%v: %s); check journalctl -u alcove-agent, then run alcove-agent --install again",
				strings.Join(step, " "), err, strings.TrimSpace(string(out)))
		}
	}
	return nil
}

// copyBinary replaces bin with exe, unless they are the same file.
func (in systemdInstall) copyBinary() error {
	if a, err := os.Stat(in.exe); err == nil {
		if b, err := os.Stat(in.bin); err == nil && os.SameFile(a, b) {
			return nil
		}
	}
	data, err := os.ReadFile(in.exe)
	if err != nil {
		return fmt.Errorf("cannot read %s (%v); run alcove-agent --install from a copy you can read", in.exe, err)
	}
	if err := replaceFile(in.bin, data, 0o755); err != nil {
		return fmt.Errorf("cannot replace %s (%v); run alcove-agent --install as root", in.bin, err)
	}
	return nil
}

// replaceFile writes data to a new file beside path, flushes it to disk and
// renames it over path, which works while path is a running program.
func replaceFile(path string, data []byte, perm os.FileMode) error {
	dir := filepath.Dir(path)
	f, err := os.CreateTemp(dir, "."+filepath.Base(path)+"-*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	done := false
	defer func() {
		if !done {
			_ = os.Remove(tmp)
		}
	}()
	if _, err := f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err := f.Chmod(perm); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		return err
	}
	done = true
	if d, err := os.Open(dir); err == nil {
		_ = d.Sync()
		d.Close()
	}
	return nil
}

// ensureHome sets HOME to the home directory of the agent's user when the
// agent was started without one, as systemd starts a system service.
func ensureHome() {
	if os.Getenv("HOME") != "" {
		return
	}
	if u, err := user.Current(); err == nil && u.HomeDir != "" {
		_ = os.Setenv("HOME", u.HomeDir)
	}
}
