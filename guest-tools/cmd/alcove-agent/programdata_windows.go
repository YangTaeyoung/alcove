//go:build windows

package main

import "github.com/YangTaeyoung/alcove/guest-tools/internal/sysfolder"

// programDataFolder returns the folder Windows names as ProgramData: the
// ProgramData value of the ProfileList key of HKEY_LOCAL_MACHINE, expanded
// by sysfolder.Expand with the system's Windows folder. No environment
// variable is read.
func programDataFolder() (string, error) {
	raw, err := sysfolder.MachineString(profileListKey, "ProgramData")
	if err != nil {
		return "", err
	}
	windows, err := sysfolder.WindowsFolder()
	if err != nil {
		return "", err
	}
	vars, err := sysfolder.BaseVars(windows)
	if err != nil {
		return "", err
	}
	return sysfolder.Expand(raw, vars)
}
