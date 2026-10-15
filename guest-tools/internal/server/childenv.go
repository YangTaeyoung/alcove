package server

import (
	"sort"
	"strings"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/sysfolder"
)

// windowsEnvInputs is what windowsChildEnv reads of a Windows system.
type windowsEnvInputs struct {
	// machine holds the string values of the Session Manager Environment key
	// of HKEY_LOCAL_MACHINE as stored.
	machine []sysfolder.Value
	// folders maps the lower-case names of the system folder variables to
	// their folders (sysfolder.MachineVars).
	folders map[string]string
	// programData is the ProgramData folder of the ProfileList key, or "".
	programData string
	// profile is the profile folder of the agent's account, from the
	// ProfileList key.
	profile string
	// user and domain name the agent's account and computer names the
	// machine; "" leaves the variable out.
	user, domain, computer string
}

// systemFolderVariables are the variables windowsChildEnv sets from
// windowsEnvInputs.folders, spelled as Windows spells them.
var systemFolderVariables = []string{"SystemRoot", "windir", "SystemDrive", "ProgramFiles", "ProgramFiles(x86)", "ProgramW6432",
	"CommonProgramFiles", "CommonProgramFiles(x86)", "CommonProgramW6432"}

// sessionVariables are the upper-case names of the variables windowsChildEnv
// takes from the account and the system folders and never from the machine
// values.
var sessionVariables = map[string]bool{"USERNAME": true, "USERDOMAIN": true, "COMPUTERNAME": true, "USERPROFILE": true,
	"HOMEDRIVE": true, "HOMEPATH": true, "APPDATA": true, "LOCALAPPDATA": true, "TEMP": true, "TMP": true, "PROGRAMDATA": true}

// windowsChildEnv returns the base environment of the processes the agent
// starts on Windows, sorted by the upper-case names:
//   - each machine value whose name is not empty, has no '=' and is not one
//     of sessionVariables: a REG_SZ value as stored, a REG_EXPAND_SZ value
//     expanded from folders by sysfolder.ExpandText and left out when it
//     names another variable; Path holds the folders machinePathFolders
//     keeps;
//   - USERNAME, USERDOMAIN and COMPUTERNAME; USERPROFILE, HOMEDRIVE and
//     HOMEPATH of the profile, APPDATA (its AppData\Roaming), LOCALAPPDATA
//     (its AppData\Local), TEMP and TMP (LOCALAPPDATA\Temp); ProgramData;
//     each of these is left out when its input is "";
//   - the systemFolderVariables that folders holds, replacing a machine
//     value of the same name without regard to case.
func windowsChildEnv(in windowsEnvInputs) []string {
	vars := map[string]string{}
	set := func(name, value string) { vars[strings.ToUpper(name)] = name + "=" + value }
	for _, v := range in.machine {
		if v.Name == "" || strings.Contains(v.Name, "=") || sessionVariables[strings.ToUpper(v.Name)] {
			continue
		}
		text := v.Text
		switch {
		case strings.EqualFold(v.Name, "Path"):
			text = strings.Join(machinePathFolders(v.Text, in.folders), ";")
		case v.Expand:
			expanded, err := sysfolder.ExpandText(v.Text, in.folders)
			if err != nil {
				continue
			}
			text = expanded
		}
		set(v.Name, text)
	}
	for name, value := range map[string]string{"USERNAME": in.user, "USERDOMAIN": in.domain, "COMPUTERNAME": in.computer, "ProgramData": in.programData} {
		if value != "" {
			set(name, value)
		}
	}
	if in.profile != "" {
		set("USERPROFILE", in.profile)
		if sysfolder.HasDrive(in.profile) {
			set("HOMEDRIVE", in.profile[:2])
			set("HOMEPATH", in.profile[2:])
		}
		local := in.profile + `\AppData\Local`
		set("APPDATA", in.profile+`\AppData\Roaming`)
		set("LOCALAPPDATA", local)
		set("TEMP", local+`\Temp`)
		set("TMP", local+`\Temp`)
	}
	for _, name := range systemFolderVariables {
		if dir, ok := in.folders[strings.ToLower(name)]; ok {
			set(name, dir)
		}
	}
	names := make([]string, 0, len(vars))
	for name := range vars {
		names = append(names, name)
	}
	sort.Strings(names)
	env := make([]string, len(names))
	for i, name := range names {
		env[i] = vars[name]
	}
	return env
}

// machinePathFolders returns the folders of the machine's Path value raw,
// in order: each entry expanded by sysfolder.Expand with vars, and left out
// when that fails.
func machinePathFolders(raw string, vars map[string]string) []string {
	var dirs []string
	for _, dir := range strings.Split(raw, ";") {
		if full, err := sysfolder.Expand(strings.TrimSpace(dir), vars); err == nil {
			dirs = append(dirs, full)
		}
	}
	return dirs
}

// envValue returns the value of the last entry of env named name, compared
// without regard to case, or "".
func envValue(env []string, name string) string {
	for i := len(env) - 1; i >= 0; i-- {
		if k, v, ok := strings.Cut(env[i], "="); ok && strings.EqualFold(k, name) {
			return v
		}
	}
	return ""
}

// lookWindowsProgram returns the file a bare program name names on Windows:
// the first one isFile finds in the folders of the PATH of env that start
// with a drive and a backslash or with two backslashes, in their order,
// trying name itself when it has an extension and then name with each
// extension of the PATHEXT of env (.com, .exe, .bat and .cmd without one).
// The current directory is not searched. ok is false when no folder holds
// such a file.
func lookWindowsProgram(name string, env []string, isFile func(string) bool) (string, bool) {
	exts := pathExts(env)
	hasExt := strings.Contains(name, ".")
	for _, dir := range strings.Split(envValue(env, "PATH"), ";") {
		if !strings.HasPrefix(dir, `\\`) && (!sysfolder.HasDrive(dir) || len(dir) < 3 || dir[2] != '\\') {
			continue
		}
		file := strings.TrimRight(dir, `\`) + `\` + name
		if hasExt && isFile(file) {
			return file, true
		}
		for _, e := range exts {
			if isFile(file + e) {
				return file + e, true
			}
		}
	}
	return "", false
}
