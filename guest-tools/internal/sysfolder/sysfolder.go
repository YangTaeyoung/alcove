// Package sysfolder expands the folder values of the machine's registry with
// the system's own folders instead of the process environment.
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

// Expand replaces the %VAR% references of raw with the values of vars, whose
// keys are lower-case names. A reference to a name not in vars, an unmatched
// '%', or a result that does not start with a drive letter and a backslash is
// an error.
func Expand(raw string, vars map[string]string) (string, error) {
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
	out := b.String()
	if !HasDrive(out) || len(out) < 3 || out[2] != '\\' {
		return "", fmt.Errorf("%q is not a folder on a drive", raw)
	}
	return out, nil
}

// HasDrive reports whether s starts with a drive letter and a colon.
func HasDrive(s string) bool {
	if len(s) < 2 || s[1] != ':' {
		return false
	}
	c := s[0] | 0x20
	return c >= 'a' && c <= 'z'
}
