package server

import (
	"context"
	"fmt"
	"os/exec"
	"strings"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/sysfolder"
)

// powerShellPrefix runs first in every -Command the agent passes to Windows
// PowerShell: it sets PSModulePath to that PowerShell's own module folder
// and makes the console streams UTF-8 without a byte order mark.
const powerShellPrefix = `$env:PSModulePath = $PSHOME + '\Modules'; ` +
	"[Console]::InputEncoding=[Text.UTF8Encoding]::new($false); [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $OutputEncoding=[Console]::OutputEncoding; "

// powerShell is Windows PowerShell below a Windows folder.
type powerShell struct {
	windows string // the Windows folder
	system  string // its System32 folder
}

// windowsPowerShell returns Windows PowerShell below the Windows folder that
// windowsFolder returns, with the System32 folder expanded from it by
// sysfolder.
func windowsPowerShell(windowsFolder func() (string, error)) (powerShell, error) {
	windows, err := windowsFolder()
	var vars map[string]string
	if err == nil {
		vars, err = sysfolder.BaseVars(windows)
	}
	system := ""
	if err == nil {
		system, err = sysfolder.Expand(`%SystemRoot%\System32`, vars)
	}
	if err != nil {
		return powerShell{}, fmt.Errorf("Windows PowerShell could not be located (%v); restart alcove-agent and retry", err)
	}
	return powerShell{windows: windows, system: system}, nil
}

// home is Windows PowerShell's folder.
func (p powerShell) home() string { return p.system + `\WindowsPowerShell\v1.0` }

// program is powershell.exe.
func (p powerShell) program() string { return p.home() + `\powershell.exe` }

// modules is Windows PowerShell's own module folder.
func (p powerShell) modules() string { return p.home() + `\Modules` }

// systemEnv is a whole environment of the system folders only: SystemRoot,
// windir, SystemDrive, ComSpec, PATH of the System32 folder, the Windows
// folder, Wbem and Windows PowerShell's folder, and PSModulePath of
// Windows PowerShell's own modules.
func (p powerShell) systemEnv() []string {
	return []string{
		"SystemRoot=" + p.windows,
		"windir=" + p.windows,
		"SystemDrive=" + p.windows[:2],
		"ComSpec=" + p.system + `\cmd.exe`,
		"PATH=" + strings.Join([]string{p.system, p.windows, p.system + `\Wbem`, p.home()}, ";"),
		"PSModulePath=" + p.modules(),
	}
}

// commandArgs returns the arguments that make powershell.exe run script after
// powerShellPrefix, without a profile, without prompts and under the
// Restricted execution policy.
func commandArgs(script string) []string {
	return []string{"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Restricted", "-Command", powerShellPrefix + script}
}

// withModulePath returns a copy of env without its PSModulePath entries,
// whose names are compared without regard to case, and with
// PSModulePath=modules at its end.
func withModulePath(env []string, modules string) []string {
	out := make([]string, 0, len(env)+1)
	for _, kv := range env {
		if name, _, ok := strings.Cut(kv, "="); ok && strings.EqualFold(name, "PSModulePath") {
			continue
		}
		out = append(out, kv)
	}
	return append(out, "PSModulePath="+modules)
}

// recipeCommand returns the command of one of the agent's own PowerShell
// recipes: powershell.exe below the Windows folder that windowsFolder
// returns, running script with commandArgs in that PowerShell's systemEnv.
// Nothing of the agent's environment is passed on.
func recipeCommand(ctx context.Context, windowsFolder func() (string, error), script string) (*exec.Cmd, error) {
	ps, err := windowsPowerShell(windowsFolder)
	if err != nil {
		return nil, err
	}
	c := exec.CommandContext(ctx, ps.program(), commandArgs(script)...)
	c.Env = ps.systemEnv()
	return c, nil
}
