//go:build windows

package server

import (
	"fmt"
	"syscall"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/sysfolder"
)

// childEnvironment returns windowsChildEnv of this machine: the values of
// sessionEnvironmentKey, sysfolder.MachineVars, the ProgramData value of
// the ProfileList key, the profile folder of the agent's account
// (sysfolder.ProfileFolder of the SID of its token), the account's name and
// domain (LookupAccountSidW of that SID) and the computer name
// (GetComputerNameW). No environment variable is read.
func childEnvironment() ([]string, error) {
	folders, err := sysfolder.MachineVars()
	if err != nil {
		return nil, fmt.Errorf("the system folders could not be read (%v); restart alcove-agent and retry", err)
	}
	machine, err := sysfolder.MachineValues(sessionEnvironmentKey)
	if err != nil {
		return nil, fmt.Errorf("the machine's environment variables could not be read (%v); restart alcove-agent and retry", err)
	}
	sid, err := agentSID()
	if err != nil {
		return nil, fmt.Errorf("the account of alcove-agent could not be read (%v); restart alcove-agent and retry", err)
	}
	profile, err := sysfolder.ProfileFolder(sid.text, folders)
	if err != nil {
		return nil, fmt.Errorf(`the profile folder of alcove-agent's account could not be read (%v); check the ProfileImagePath value of HKLM\%s\%s, then retry`,
			err, sysfolder.ProfileListKey, sid.text)
	}
	in := windowsEnvInputs{machine: machine, folders: folders, profile: profile}
	if raw, err := sysfolder.MachineString(sysfolder.ProfileListKey, "ProgramData"); err == nil {
		in.programData, _ = sysfolder.Expand(raw, folders)
	}
	in.user, in.domain, _, _ = sid.sid.LookupAccount("")
	in.computer, _ = syscall.ComputerName()
	return windowsChildEnv(in), nil
}

// tokenSID is the SID of the agent's token, as a SID and as its string.
type tokenSID struct {
	sid  *syscall.SID
	text string
}

// agentSID returns the SID of the user of the agent's process token.
func agentSID() (tokenSID, error) {
	t, err := syscall.OpenCurrentProcessToken()
	if err != nil {
		return tokenSID{}, err
	}
	defer t.Close()
	u, err := t.GetTokenUser()
	if err != nil {
		return tokenSID{}, err
	}
	sid, err := u.User.Sid.Copy()
	if err != nil {
		return tokenSID{}, err
	}
	text, err := sid.String()
	if err != nil {
		return tokenSID{}, err
	}
	return tokenSID{sid: sid, text: text}, nil
}

// agentHome returns the profile folder of the agent's account: the
// ProfileImagePath of its SID under the ProfileList key, expanded with
// sysfolder.MachineVars; "" when it cannot be read. No environment variable
// is read.
func agentHome() string {
	folders, err := sysfolder.MachineVars()
	if err != nil {
		return ""
	}
	sid, err := agentSID()
	if err != nil {
		return ""
	}
	home, err := sysfolder.ProfileFolder(sid.text, folders)
	if err != nil {
		return ""
	}
	return home
}
