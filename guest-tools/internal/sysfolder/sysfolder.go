// Package sysfolder expands the folder and text values of the machine's
// registry with the system's own folders instead of the process environment.
package sysfolder

import (
	"fmt"
	"strings"
)

// BaseVars returns the variables the Windows folder windows defines:
// systemdrive is its drive, systemroot and windir are windows. Names are
// lower case.
func BaseVars(windows string) (map[string]string, error) {
	if !HasDrive(windows) {
		return nil, fmt.Errorf("the Windows folder %q has no drive letter", windows)
	}
	return map[string]string{"systemdrive": windows[:2], "systemroot": windows, "windir": windows}, nil
}

// programFilesValues maps the variables of the Program Files folders to the
// names of their values under HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion.
var programFilesValues = map[string]string{
	"programfiles":            "ProgramFilesDir",
	"programfiles(x86)":       "ProgramFilesDir (x86)",
	"programfiles(arm)":       "ProgramFilesDir (Arm)",
	"programw6432":            "ProgramW6432Dir",
	"commonprogramfiles":      "CommonFilesDir",
	"commonprogramfiles(x86)": "CommonFilesDir (x86)",
	"commonprogramfiles(arm)": "CommonFilesDir (Arm)",
	"commonprogramw6432":      "CommonW6432Dir",
}

// folderVars returns BaseVars of the Windows folder windows and each Program
// Files variable of programFilesValues whose value, read by value, expands
// with BaseVars by Expand. A value that value cannot read, that is "" or that
// does not expand is left out.
func folderVars(windows string, value func(name string) (string, error)) (map[string]string, error) {
	base, err := BaseVars(windows)
	if err != nil {
		return nil, err
	}
	vars := make(map[string]string, len(base)+len(programFilesValues))
	for name, dir := range base {
		vars[name] = dir
	}
	for name, v := range programFilesValues {
		raw, err := value(v)
		if err != nil || raw == "" {
			continue
		}
		if dir, err := Expand(raw, base); err == nil {
			vars[name] = dir
		}
	}
	return vars, nil
}

// Value is a string value of a registry key: Text as stored, and Expand set
// for a REG_EXPAND_SZ value.
type Value struct {
	Name   string
	Text   string
	Expand bool
}

// Expand replaces the %VAR% references of raw with the values of vars, as
// ExpandText does, and requires the result to start with a drive letter and a
// backslash.
func Expand(raw string, vars map[string]string) (string, error) {
	out, err := ExpandText(raw, vars)
	if err != nil {
		return "", err
	}
	if !HasDrive(out) || len(out) < 3 || out[2] != '\\' {
		return "", fmt.Errorf("%q is not a folder on a drive", raw)
	}
	return out, nil
}

// ExpandText replaces the %VAR% references of raw with the values of vars,
// whose keys are lower-case names. A reference to a name not in vars or an
// unmatched '%' is an error.
func ExpandText(raw string, vars map[string]string) (string, error) {
	var b strings.Builder
	rest := raw
	for {
		i := strings.IndexByte(rest, '%')
		if i < 0 {
			b.WriteString(rest)
			break
		}
		b.WriteString(rest[:i])
		j := strings.IndexByte(rest[i+1:], '%')
		if j < 0 {
			return "", fmt.Errorf("%q has an unmatched %%", raw)
		}
		name := rest[i+1 : i+1+j]
		v, ok := vars[strings.ToLower(name)]
		if !ok {
			return "", fmt.Errorf("%q names %%%s%%, which is not a system folder", raw, name)
		}
		b.WriteString(v)
		rest = rest[i+2+j:]
	}
	return b.String(), nil
}

// stringUnits returns the number of UTF-16 units that hold a registry value
// of size bytes, an odd last byte included.
func stringUnits(size uint32) int {
	return int((size + 1) / 2)
}

// HasDrive reports whether s starts with a drive letter and a colon.
func HasDrive(s string) bool {
	if len(s) < 2 || s[1] != ':' {
		return false
	}
	c := s[0] | 0x20
	return c >= 'a' && c <= 'z'
}
