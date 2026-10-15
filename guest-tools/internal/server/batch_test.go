package server

import (
	"errors"
	"io/fs"
	"os/exec"
	"reflect"
	"strings"
	"testing"
)

func TestABatchArgumentIsQuotedForCmd(t *testing.T) {
	for _, c := range []struct{ arg, want string }{
		{`plain`, `plain`},
		{`C:\dir\file.txt`, `C:\dir\file.txt`},
		{`#$*+-./:?@\_`, `#$*+-./:?@\_`},
		{``, `""`},
		{`a b`, `"a b"`},
		{`100%`, `"100%%cd:~,%"`},
		{`%PATH%`, `"%%cd:~,%PATH%%cd:~,%"`},
		{`a"b`, `"a""b"`},
		{`a\"b`, `"a\\""b"`},
		{`x\`, `"x\\"`},
		{`C:\a b\`, `"C:\a b\\"`},
		{`&|<>^`, `"&|<>^"`},
		{`""`, `""""""`},
		{`!x!`, `"!x!"`},
		{"tab\there", "\"tab\there\""},
		{`über`, `über`},
	} {
		var b strings.Builder
		appendBatchArg(&b, c.arg)
		if got := b.String(); got != c.want {
			t.Errorf("%q is quoted as %s; expected %s", c.arg, got, c.want)
		}
	}
}

func TestABatchFileRunsThroughCmdWithoutAutoRun(t *testing.T) {
	got, err := batchCommandLine(`C:\work\t.bat`, []string{"a b", "100%", `x\`, ""})
	want := `cmd.exe /D /E:ON /V:OFF /S /C ""C:\work\t.bat" "a b" "100%%cd:~,%" "x\\" """`
	if err != nil || got != want {
		t.Fatalf("command line\n got %s, %v\nwant %s", got, err, want)
	}
	if got, err := batchCommandLine(`C:\work\t.cmd`, nil); err != nil || got != `cmd.exe /D /E:ON /V:OFF /S /C ""C:\work\t.cmd""` {
		t.Fatalf("without arguments: %s, %v", got, err)
	}
}

func TestABatchArgumentOrScriptCmdCannotCarryIsRefused(t *testing.T) {
	for i, arg := range []string{"a\rb", "a\nb", "a\x00b"} {
		_, err := batchCommandLine(`C:\work\t.bat`, []string{"ok", arg})
		want := `argument 2 of the batch file 'C:\work\t.bat' holds a line break or NUL, which cmd.exe cannot pass to a batch file; pass it another way, such as in env, or run the batch file with shell 'cmd' and quote the command yourself`
		if err == nil || err.Error() != want {
			t.Errorf("argument %d: %v", i, err)
		}
	}
	for _, script := range []string{`C:\work\"t.bat`, `C:\work\t.bat\`} {
		_, err := batchCommandLine(script, nil)
		want := "the batch file '" + script + `' cannot be passed to cmd.exe because its path contains '"' or ends in '\'; pass the path of the file itself`
		if err == nil || err.Error() != want {
			t.Errorf("%s: %v", script, err)
		}
	}
	for _, script := range []string{`C:\x\a%PATH%b.bat`, `C:\100%\t.bat`} {
		_, err := batchCommandLine(script, nil)
		want := "the batch file '" + script + `' cannot be passed to cmd.exe because its path contains '%', which cmd.exe would expand; move or rename it so that its path has no '%'`
		if err == nil || err.Error() != want {
			t.Errorf("%s: %v", script, err)
		}
	}
}

// fakeFullPath joins relative paths with D:\agent and drops trailing dots
// and spaces of the last element, as GetFullPathNameW does.
func fakeFullPath(p string) (string, error) {
	if p == "" {
		return "", errors.New("empty path")
	}
	if !windowsAbs(p) {
		p = `D:\agent\` + p
	}
	return strings.TrimRight(p, ". "), nil
}

func TestABatchFileIsFoundByItsFullPath(t *testing.T) {
	for _, c := range []struct {
		path, dir, want string
		ok              bool
	}{
		{`C:\work\t.bat`, ``, `C:\work\t.bat`, true},
		{`C:\work\T.BAT`, ``, `C:\work\T.BAT`, true},
		{`C:\work\t.Cmd`, ``, `C:\work\t.Cmd`, true},
		{`C:\work\t.bat.`, ``, `C:\work\t.bat`, true},
		{`C:\work\t.bat  `, ``, `C:\work\t.bat`, true},
		{`scripts\build.cmd`, `E:\repo`, `E:\repo\scripts\build.cmd`, true},
		{`scripts\build.cmd`, ``, `D:\agent\scripts\build.cmd`, true},
		{`\\server\share\x.bat`, `E:\repo`, `\\server\share\x.bat`, true},
		{`C:\work\t.exe`, ``, ``, false},
		{`C:\work\t.bat.exe`, ``, ``, false},
		{`C:\work\bat`, ``, ``, false},
	} {
		got, ok := batchScript(c.path, c.dir, fakeFullPath)
		if got != c.want || ok != c.ok {
			t.Errorf("%s in %q gives %q, %v; expected %q, %v", c.path, c.dir, got, ok, c.want, c.ok)
		}
	}
}

// testFiles returns an isFile that finds exactly names, compared without
// regard to case.
func testFiles(names ...string) func(string) bool {
	return func(p string) bool {
		for _, n := range names {
			if strings.EqualFold(n, p) {
				return true
			}
		}
		return false
	}
}

func TestABatchCommandStartsCmdOfTheSystemFolderAndKeepsItsArgs(t *testing.T) {
	c := &exec.Cmd{Path: `scripts\build.cmd`, Args: []string{`scripts\build.cmd`, "a b"}, Dir: `E:\repo`}
	file, line, err := windowsStart(c, `D:\WINDOWS\System32`, fakeFullPath, testFiles(`E:\repo\scripts\build.cmd`))
	if err != nil || file != `E:\repo\scripts\build.cmd` {
		t.Fatalf("%q, %v", file, err)
	}
	if want := `cmd.exe /D /E:ON /V:OFF /S /C ""E:\repo\scripts\build.cmd" "a b""`; line != want {
		t.Fatalf("command line %s; expected %s", line, want)
	}
	if c.Path != `D:\WINDOWS\System32\cmd.exe` || !reflect.DeepEqual(c.Args, []string{`scripts\build.cmd`, "a b"}) {
		t.Fatalf("path %q, args %q", c.Path, c.Args)
	}

	c = &exec.Cmd{Path: `C:\work\t.bat`, Args: []string{`C:\work\t.bat`, "a\nb"}}
	if _, _, err := windowsStart(c, `D:\WINDOWS\System32`, fakeFullPath, testFiles(`C:\work\t.bat`)); err == nil || c.Path != `C:\work\t.bat` {
		t.Fatalf("an argument with a line break: %v, %q", err, c.Path)
	}
}

func TestAProgramPathIsResolvedWithThePATHEXTOfTheCommand(t *testing.T) {
	for _, tc := range []struct {
		path, dir string
		env       []string
		files     []string
		file      string
		batch     bool
	}{
		{`C:\tools\x.exe`, ``, nil, []string{`C:\tools\x.exe`}, `C:\tools\x.exe`, false},
		{`C:\tools\prog`, ``, []string{"PATHEXT=.COM;.EXE"}, []string{`C:\tools\prog.exe`}, `C:\tools\prog.exe`, false},
		{`tools\gradlew`, `E:\repo`, []string{"PATHEXT=.EXE;.BAT"}, []string{`E:\repo\tools\gradlew.cmd`, `E:\repo\tools\gradlew.bat`}, `E:\repo\tools\gradlew.bat`, true},
		{`C:\Tools\build.v2`, ``, nil, []string{`C:\Tools\build.v2.cmd`}, `C:\Tools\build.v2.cmd`, true},
		{`C:\Tools\tool.v2`, ``, nil, []string{`C:\Tools\tool.v2`, `C:\Tools\tool.v2.cmd`}, `C:\Tools\tool.v2`, false},
		{`C:\Tools\x.bat`, ``, []string{"PATHEXT=.EXE"}, []string{`C:\Tools\x.bat`}, `C:\Tools\x.bat`, true},
	} {
		c := &exec.Cmd{Path: tc.path, Args: []string{tc.path}, Dir: tc.dir, Env: tc.env}
		file, line, err := windowsStart(c, `D:\WINDOWS\System32`, fakeFullPath, testFiles(tc.files...))
		if err != nil || file != tc.file || (line != "") != tc.batch {
			t.Errorf("%s in %q with %q starts %q, line %q, %v; expected %q, batch %v", tc.path, tc.dir, tc.files, file, line, err, tc.file, tc.batch)
			continue
		}
		if want := tc.file; tc.batch {
			if c.Path != `D:\WINDOWS\System32\cmd.exe` || line != `cmd.exe /D /E:ON /V:OFF /S /C ""`+want+`""` {
				t.Errorf("%s runs %q with %s", tc.path, c.Path, line)
			}
		} else if c.Path != want {
			t.Errorf("%s runs %q; expected %q", tc.path, c.Path, want)
		}
	}
}

func TestAProgramPathThatNamesNoFileIsRefused(t *testing.T) {
	for _, tc := range []struct {
		path  string
		env   []string
		files []string
	}{
		{`C:\repo\gradlew`, []string{"PATHEXT=.EXE"}, []string{`C:\repo\gradlew.bat`}},
		{`C:\repo\missing.exe`, nil, nil},
		{`C:\repo\build.v2`, []string{"PATHEXT=.EXE"}, []string{`C:\repo\build.v2.cmd`}},
	} {
		c := &exec.Cmd{Path: tc.path, Args: []string{tc.path}, Env: tc.env}
		_, _, err := windowsStart(c, `D:\WINDOWS\System32`, fakeFullPath, testFiles(tc.files...))
		want := "'" + tc.path + "' names no file, also not with an extension of the command's PATHEXT"
		if err == nil || err.Error() != want || !errors.Is(err, fs.ErrNotExist) || c.Path != tc.path {
			t.Errorf("%s with %q gives %v, path %q", tc.path, tc.files, err, c.Path)
		}
	}
}

func TestAProgramPathIsJoinedWithTheWorkingDirectoryAsCreateProcessDoes(t *testing.T) {
	for _, c := range []struct{ dir, p, want string }{
		{``, `x.bat`, `x.bat`},
		{`E:\repo`, `C:\x.bat`, `C:\x.bat`},
		{`E:\repo`, `\\srv\share\x.bat`, `\\srv\share\x.bat`},
		{`E:\repo\`, `sub\x.bat`, `E:\repo\sub\x.bat`},
		{`E:\repo`, `\x.bat`, `E:\x.bat`},
		{`E:\repo`, `e:x.bat`, `E:\repo\x.bat`},
		{`E:\repo`, `C:x.bat`, `C:x.bat`},
	} {
		if got := joinProgramDir(c.dir, c.p); got != c.want {
			t.Errorf("%s in %s gives %s; expected %s", c.p, c.dir, got, c.want)
		}
	}
}
