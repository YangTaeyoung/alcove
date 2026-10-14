package main

import (
	"fmt"
	"strings"
)

// expandSystemFolder expands a folder value of the registry such as
// `%SystemDrive%\ProgramData` with the Windows folder windows only:
// %SystemDrive% becomes the drive of windows, %SystemRoot% and %windir%
// become windows. A value with any other variable, an unmatched '%', or a
// result that does not start with a drive letter and a backslash is an
// error.
func expandSystemFolder(raw, windows string) (string, error) {
	if !hasDrive(windows) {
		return "", fmt.Errorf("the Windows folder %q has no drive letter", windows)
	}
	vars := map[string]string{"systemdrive": windows[:2], "systemroot": windows, "windir": windows}
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
			return "", fmt.Errorf("%q names %%%s%%, which is not SystemDrive, SystemRoot or windir", raw, name)
		}
		b.WriteString(v)
		rest = rest[i+2+j:]
	}
	out := b.String()
	if !hasDrive(out) || len(out) < 3 || out[2] != '\\' {
		return "", fmt.Errorf("%q is not a folder on a drive", raw)
	}
	return out, nil
}

// hasDrive reports whether s starts with a drive letter and a colon.
func hasDrive(s string) bool {
	if len(s) < 2 || s[1] != ':' {
		return false
	}
	c := s[0] | 0x20
	return c >= 'a' && c <= 'z'
}
