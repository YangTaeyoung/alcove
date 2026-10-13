package server

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync/atomic"
	"time"
	"unicode/utf8"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

const (
	powershellUTF8Prefix = "[Console]::InputEncoding=[Text.UTF8Encoding]::new($false); [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $OutputEncoding=[Console]::OutputEncoding; "
	runStreamBytes       = 200000
	defaultRunTimeout    = 120 * time.Second
	pipeWaitDelay        = 2 * time.Second
)

// buildCommand turns request fields into a command for the given OS.
func buildCommand(req proto.Message, goos string) (*exec.Cmd, error) {
	cmdline := req.String("cmd")
	argv := req.Strings("argv")
	shell := req.String("shell")
	if cmdline == "" && len(argv) == 0 {
		return nil, errors.New("missing cmd or argv")
	}
	if shell == "none" && len(argv) == 0 {
		return nil, errors.New("shell 'none' needs argv")
	}

	var c *exec.Cmd
	switch {
	case len(argv) > 0:
		c = exec.Command(argv[0], argv[1:]...)
	default:
		if shell == "" {
			shell = "sh"
			if goos == "windows" {
				shell = "powershell"
			}
		}
		switch shell {
		case "powershell":
			if goos != "windows" {
				return nil, errors.New("shell 'powershell' exists only on Windows; use shell 'sh'")
			}
			c = exec.Command("powershell.exe", "-NoProfile", "-NonInteractive", "-Command", powershellUTF8Prefix+cmdline)
		case "cmd":
			if goos != "windows" {
				return nil, errors.New("shell 'cmd' exists only on Windows; use shell 'sh'")
			}
			c = exec.Command("cmd.exe", "/S", "/C", cmdline)
			setRawCommandLine(c, cmdExeLine(cmdline))
		case "sh":
			c = exec.Command("/bin/sh", "-c", cmdline)
		default:
			return nil, fmt.Errorf("unknown shell '%s'; use powershell, cmd, sh or none", shell)
		}
	}

	c.Dir = req.String("cwd")
	if env := req.StringMap("env"); len(env) > 0 {
		keys := make([]string, 0, len(env))
		for k := range env {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		c.Env = os.Environ()
		for _, k := range keys {
			c.Env = append(c.Env, k+"="+env[k])
		}
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

// newCommand builds a request's command with the working directory resolved,
// no console window and its own process tree.
func (s *Server) newCommand(req proto.Message) (*exec.Cmd, error) {
	c, err := buildCommand(req, runtime.GOOS)
	if err != nil {
		return nil, err
	}
	if c.Dir != "" {
		c.Dir = resolveHomePath(s.opt.HomeDir, c.Dir)
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

func (s *Server) execRun(_ context.Context, req proto.Message) (proto.Message, error) {
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
	_ = c.Wait()
	timer.Stop()

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
