package server

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"sort"
	"strings"
	"sync/atomic"
	"time"
	"unicode/utf8"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

const (
	runStreamBytes    = 200000
	defaultRunTimeout = 120 * time.Second
	pipeWaitDelay     = 2 * time.Second
)

// commandSystem is what buildCommand reads of the system it builds for.
type commandSystem struct {
	goos string
	// environ is the base environment of the commands (childEnvironment).
	environ []string
	// windows returns the system's Windows folder; shells powershell and cmd
	// call it.
	windows func() (string, error)
	// isFile reports whether a path names a file that is not a directory;
	// the lookup of a bare argv[0] on Windows calls it.
	isFile func(string) bool
}

// agentSystem returns the commandSystem of the running agent.
func agentSystem() (commandSystem, error) {
	env, err := childEnvironment()
	if err != nil {
		return commandSystem{}, err
	}
	return commandSystem{goos: runtime.GOOS, environ: env, windows: windowsFolder, isFile: isFile}, nil
}

// isFile reports whether path names a file that is not a directory.
func isFile(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && !fi.IsDir()
}

// buildCommand turns request fields into a command for sys. On Windows the
// command's environment is the base environment of sys, with PSModulePath
// set to Windows PowerShell's own module folder for shell powershell, which
// runs powershell.exe of the Windows folder with commandArgs; shell cmd runs
// cmd.exe of the System32 folder; a bare argv[0] is looked up by
// lookWindowsProgram in that environment with env of the request added.
// Elsewhere the command inherits the agent's environment. env of the request
// is added after the environment.
func buildCommand(req proto.Message, sys commandSystem) (*exec.Cmd, error) {
	cmdline := req.String("cmd")
	argv := req.Strings("argv")
	shell := req.String("shell")
	if cmdline == "" && len(argv) == 0 {
		return nil, errors.New("missing cmd or argv")
	}
	if shell == "none" && len(argv) == 0 {
		return nil, errors.New("shell 'none' needs argv")
	}
	if cmdline != "" && len(argv) > 0 {
		return nil, errors.New("pass cmd or argv, not both")
	}
	if len(argv) > 0 && shell != "" && shell != "none" {
		return nil, fmt.Errorf("shell '%s' does not run argv; pass shell 'none' or leave shell out", shell)
	}

	windows := sys.goos == "windows"
	var c *exec.Cmd
	switch {
	case len(argv) > 0 && windows:
		c = &exec.Cmd{Path: argv[0], Args: slices.Clone(argv)}
	case len(argv) > 0:
		c = exec.Command(argv[0], argv[1:]...)
	default:
		if shell == "" {
			shell = "sh"
			if sys.goos == "windows" {
				shell = "powershell"
			}
		}
		switch shell {
		case "powershell":
			if sys.goos != "windows" {
				return nil, errors.New("shell 'powershell' exists only on Windows; use shell 'sh'")
			}
			ps, err := windowsPowerShell(sys.windows)
			if err != nil {
				return nil, err
			}
			c = exec.Command(ps.program(), commandArgs(cmdline)...)
			c.Env = withModulePath(sys.environ, ps.modules())
		case "cmd":
			if sys.goos != "windows" {
				return nil, errors.New("shell 'cmd' exists only on Windows; use shell 'sh'")
			}
			_, system, err := systemFolders(sys.windows)
			if err != nil {
				return nil, fmt.Errorf("cmd.exe could not be located (%v); restart alcove-agent and retry", err)
			}
			c = exec.Command(system+`\cmd.exe`, "/S", "/C", cmdline)
			setRawCommandLine(c, cmdExeLine(cmdline))
		case "sh":
			c = exec.Command("/bin/sh", "-c", cmdline)
		default:
			return nil, fmt.Errorf("unknown shell '%s'; use powershell, cmd, sh or none", shell)
		}
	}

	c.Dir = req.String("cwd")
	if windows && c.Env == nil {
		c.Env = slices.Clone(sys.environ)
	}
	if env := req.StringMap("env"); len(env) > 0 {
		keys := make([]string, 0, len(env))
		for k := range env {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		if c.Env == nil {
			c.Env = slices.Clone(sys.environ)
		}
		for _, k := range keys {
			c.Env = append(c.Env, k+"="+env[k])
		}
	}
	if windows && len(argv) > 0 && !strings.ContainsAny(argv[0], `\/:`) {
		program, ok := lookWindowsProgram(argv[0], c.Env, sys.isFile)
		if !ok {
			return nil, fmt.Errorf("'%s' is not in a folder of the command's PATH (the machine's PATH, or PATH of env); pass the full path of the program", argv[0])
		}
		c.Path = program
	}
	return c, nil
}

// cmdExeLine is the raw command line that makes cmd.exe run cmdline verbatim:
// with /S, cmd.exe removes exactly the outer pair of quotes.
func cmdExeLine(cmdline string) string {
	return `cmd.exe /S /C "` + cmdline + `"`
}

// commandLine is the text shown for a request in job listings.
func commandLine(req proto.Message) string {
	if cmd := req.String("cmd"); cmd != "" {
		return cmd
	}
	return strings.Join(req.Strings("argv"), " ")
}

// resolveHomePath expands "~" and anchors relative paths at home.
func resolveHomePath(home, p string) string {
	switch {
	case p == "~":
		return home
	case strings.HasPrefix(p, "~/"), strings.HasPrefix(p, `~\`):
		return filepath.Join(home, p[2:])
	case filepath.IsAbs(p):
		return p
	}
	return filepath.Join(home, p)
}

// newCommand builds a request's command with the working directory resolved
// (the home directory without cwd), no console window and its own process
// tree.
func (s *Server) newCommand(req proto.Message) (*exec.Cmd, error) {
	sys, err := agentSystem()
	if err != nil {
		return nil, err
	}
	c, err := buildCommand(req, sys)
	if err != nil {
		return nil, err
	}
	if c.Dir != "" {
		c.Dir = resolveHomePath(s.homeDir(), c.Dir)
	} else {
		c.Dir = s.homeDir()
	}
	hideWindow(c)
	prepareTree(c)
	c.WaitDelay = pipeWaitDelay
	return c, nil
}

func startError(err error) error {
	return fmt.Errorf("cannot start the command: %v; check cmd, argv, cwd and shell", err)
}

// text converts captured bytes to a string with invalid UTF-8 replaced.
func text(b []byte) string {
	return strings.ToValidUTF8(string(b), "�")
}

// completeUTF8Len returns the length of b without a trailing partial rune.
func completeUTF8Len(b []byte) int {
	for back := 1; back <= utf8.UTFMax-1 && back <= len(b); back++ {
		i := len(b) - back
		if utf8.RuneStart(b[i]) {
			if !utf8.FullRune(b[i:]) {
				return i
			}
			break
		}
	}
	return len(b)
}

func (s *Server) registerShell() {
	s.register("exec.run", true, s.execRun)
	s.registerJobs()
	s.registerProcs()
}

// execRun runs a command to its end. Its process tree is killed when the
// timeout passes or the connection of the request closes.
func (s *Server) execRun(ctx context.Context, req proto.Message) (proto.Message, error) {
	c, err := s.newCommand(req)
	if err != nil {
		return nil, err
	}
	stdout, stderr := newRing(runStreamBytes), newRing(runStreamBytes)
	c.Stdout, c.Stderr = stdout, stderr
	// The child reads the stdin text from a pipe that ends after it; without
	// the field the pipe is at end-of-file from the start.
	c.Stdin = strings.NewReader(req.String("stdin"))
	timeout := defaultRunTimeout
	if ms := req.Int("timeout_ms"); ms > 0 {
		timeout = time.Duration(ms) * time.Millisecond
	}
	if err := c.Start(); err != nil {
		return nil, startError(err)
	}
	pid := c.Process.Pid
	var timedOut atomic.Bool
	timer := time.AfterFunc(timeout, func() {
		timedOut.Store(true)
		_ = killTree(pid)
	})
	stopOnClose := context.AfterFunc(ctx, func() { _ = killTree(pid) })
	_ = c.Wait()
	timer.Stop()
	stopOnClose()

	code := -1
	if c.ProcessState != nil && !timedOut.Load() {
		code = c.ProcessState.ExitCode()
	}
	out, outCut := stdout.snapshot()
	errOut, errCut := stderr.snapshot()
	return proto.Message{
		"code":      code,
		"stdout":    streamText(out, outCut),
		"stderr":    streamText(errOut, errCut),
		"timed_out": timedOut.Load(),
		"truncated": outCut || errCut,
	}, nil
}
