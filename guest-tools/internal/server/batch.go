package server

import (
	"fmt"
	"os/exec"
	"strings"
	"unicode"
)

// batchUnquoted holds the ASCII characters other than letters and digits
// that appendBatchArg leaves unquoted.
const batchUnquoted = `#$*+-./:?@\_`

// appendBatchArg appends arg to b as an argument of a batch file on the
// command line batchCommandLine builds. An argument that is empty, ends in
// '\', or holds a control character or an ASCII character other than
// letters, digits and batchUnquoted is put in quotes. Inside the quotes '"'
// is doubled after the backslashes before it are doubled, '%' is preceded by
// "%%cd:~," (an empty substring of %cd%, which /E:ON allows), so that cmd.exe
// expands no variable, and the backslashes before the closing quote are
// doubled.
func appendBatchArg(b *strings.Builder, arg string) {
	quote := arg == "" || strings.HasSuffix(arg, `\`)
	for _, r := range arg {
		if r < 0x80 && !('a' <= r && r <= 'z' || 'A' <= r && r <= 'Z' || '0' <= r && r <= '9' || strings.ContainsRune(batchUnquoted, r)) || unicode.IsControl(r) {
			quote = true
		}
	}
	if quote {
		b.WriteByte('"')
	}
	backslashes := 0
	for _, r := range arg {
		switch r {
		case '\\':
			backslashes++
		case '"':
			b.WriteString(strings.Repeat(`\`, backslashes))
			b.WriteByte('"')
			backslashes = 0
		case '%':
			b.WriteString("%%cd:~,")
			backslashes = 0
		default:
			backslashes = 0
		}
		b.WriteRune(r)
	}
	if quote {
		b.WriteString(strings.Repeat(`\`, backslashes))
		b.WriteByte('"')
	}
}

// batchCommandLine returns the command line that makes cmd.exe run the batch
// file script with args: cmd.exe /D /E:ON /V:OFF /S /C ""<script>" <args>",
// each argument written by appendBatchArg. /D skips the AutoRun commands of
// the registry, /V:OFF keeps '!' literal and with /S cmd.exe removes exactly
// the outer pair of quotes. A script path that holds '"' or '%' or ends in
// '\', and an argument with CR, LF or NUL, are errors.
func batchCommandLine(script string, args []string) (string, error) {
	if strings.Contains(script, `"`) || strings.HasSuffix(script, `\`) {
		return "", fmt.Errorf(`the batch file '%s' cannot be passed to cmd.exe because its path contains '"' or ends in '\'; pass the path of the file itself`, script)
	}
	if strings.Contains(script, "%") {
		return "", fmt.Errorf("the batch file '%s' cannot be passed to cmd.exe because its path contains '%%', which cmd.exe would expand; move or rename it so that its path has no '%%'", script)
	}
	var b strings.Builder
	b.WriteString(`cmd.exe /D /E:ON /V:OFF /S /C ""`)
	b.WriteString(script)
	b.WriteByte('"')
	for i, arg := range args {
		if strings.ContainsAny(arg, "\r\n\x00") {
			return "", fmt.Errorf("argument %d of the batch file '%s' holds a line break or NUL, which cmd.exe cannot pass to a batch file; pass it another way, such as in env, or run the batch file with shell 'cmd' and quote the command yourself", i+1, script)
		}
		b.WriteByte(' ')
		appendBatchArg(&b, arg)
	}
	b.WriteByte('"')
	return b.String(), nil
}

// isSlash reports whether c separates the elements of a Windows path.
func isSlash(c byte) bool { return c == '\\' || c == '/' }

// windowsAbs reports whether p starts with a drive and a separator or with
// two separators.
func windowsAbs(p string) bool {
	return len(p) > 2 && (p[1] == ':' && isSlash(p[2]) || isSlash(p[0]) && isSlash(p[1]))
}

// joinProgramDir returns the program path p of a process whose working
// directory is dir as CreateProcess reads it: p itself when it is absolute
// or dir is empty; p after dir's drive when p starts with one separator; p
// after dir when p has no drive, or dir's drive when it names that drive.
func joinProgramDir(dir, p string) string {
	switch {
	case dir == "" || p == "" || windowsAbs(p):
		return p
	case len(p) > 1 && p[1] == ':':
		if len(dir) > 1 && strings.EqualFold(p[:1], dir[:1]) {
			return strings.TrimRight(dir, `\/`) + `\` + p[2:]
		}
		return p
	case isSlash(p[0]):
		if len(dir) > 1 && dir[1] == ':' {
			return dir[:2] + p
		}
		return p
	}
	return strings.TrimRight(dir, `\/`) + `\` + p
}

// isBatchFile reports whether path ends in .bat or .cmd, compared without
// regard to case.
func isBatchFile(path string) bool {
	if len(path) < 4 {
		return false
	}
	ext := strings.ToLower(path[len(path)-4:])
	return ext == ".bat" || ext == ".cmd"
}

// batchScript returns the full path of the program path of a process whose
// working directory is dir (joinProgramDir, then fullPath) when it is a
// batch file; ok is false otherwise.
func batchScript(path, dir string, fullPath func(string) (string, error)) (string, bool) {
	full, err := fullPath(joinProgramDir(dir, path))
	if err != nil || !isBatchFile(full) {
		return "", false
	}
	return full, true
}

// pathExts returns the extensions of the PATHEXT of env in lower case, each
// with a leading '.', leaving out entries with '\', '/' or ':'; or .com,
// .exe, .bat and .cmd when none is left.
func pathExts(env []string) []string {
	var exts []string
	for _, e := range strings.Split(strings.ToLower(envValue(env, "PATHEXT")), ";") {
		if e == "" || strings.ContainsAny(e, `\/:`) {
			continue
		}
		if e[0] != '.' {
			e = "." + e
		}
		exts = append(exts, e)
	}
	if len(exts) == 0 {
		exts = []string{".com", ".exe", ".bat", ".cmd"}
	}
	return exts
}

// hasExt reports whether the last element of path has an extension: a '.'
// after the last '\', '/' or ':'.
func hasExt(path string) bool {
	i := strings.LastIndex(path, ".")
	return i >= 0 && strings.LastIndexAny(path, `\/:`) < i
}

// windowsStart prepares c for its start on Windows and returns the file the
// process runs. A program path with '\', '/' or ':' is joined with c.Dir as
// joinProgramDir does and resolved with the PATHEXT of c.Env as Go's
// findExecutable resolves it: the path itself when its last element has an
// extension and isFile finds it, else the path with each extension in turn;
// c.Path becomes the file found, an existing file whose last element has an
// extension. A path that names no file is an error, and c is left as it is.
// When the file, normalised by
// fullPath, is a batch file, file is that script, c.Path becomes cmd.exe of
// the folder system and line is batchCommandLine of the script and
// c.Args[1:], which the caller passes as the raw command line; otherwise
// line is empty. c.Args stays as it is.
func windowsStart(c *exec.Cmd, system string, fullPath func(string) (string, error), isFile func(string) bool) (file, line string, err error) {
	if strings.ContainsAny(c.Path, `\/:`) {
		base := joinProgramDir(c.Dir, c.Path)
		found := ""
		if hasExt(base) && isFile(base) {
			found = base
		} else {
			for _, e := range pathExts(c.Env) {
				if isFile(base + e) {
					found = base + e
					break
				}
			}
		}
		if found == "" {
			return "", "", fmt.Errorf("'%s' names no file, also not with an extension of the command's PATHEXT; pass the file name with its extension, or check PATHEXT in env", c.Path)
		}
		c.Path = found
	}
	script, ok := batchScript(c.Path, c.Dir, fullPath)
	if !ok {
		return c.Path, "", nil
	}
	var args []string
	if len(c.Args) > 1 {
		args = c.Args[1:]
	}
	line, err = batchCommandLine(script, args)
	if err != nil {
		return "", "", err
	}
	c.Path = system + `\cmd.exe`
	return script, line, nil
}
