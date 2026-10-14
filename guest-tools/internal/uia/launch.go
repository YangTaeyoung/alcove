package uia

import (
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"time"
)

// previousExitWait is how long a start waits for the process of the start
// before it to end.
const previousExitWait = 10 * time.Second

// helperEnv returns the whole environment of a helper process, built from the
// Windows folder windows, the system folder system and the locked temporary
// folder tmp: SystemRoot, windir, SystemDrive, ComSpec, PATH of the system
// folders, PSModulePath of the system's PowerShell modules only, the
// PowerShell module analysis cache inside tmp, TEMP and TMP set to tmp, and
// ALCOVE_UIA_START set to starts.
func helperEnv(windows, system, tmp string, starts int) []string {
	drive := ""
	if len(windows) >= 2 && windows[1] == ':' {
		drive = windows[:2]
	}
	ps := system + `\WindowsPowerShell\v1.0`
	return []string{
		"SystemRoot=" + windows,
		"windir=" + windows,
		"SystemDrive=" + drive,
		"ComSpec=" + system + `\cmd.exe`,
		"PATH=" + strings.Join([]string{system, windows, system + `\Wbem`, ps}, ";"),
		"PSModulePath=" + ps + `\Modules`,
		"PSModuleAnalysisCachePath=" + tmp + `\ModuleAnalysisCache`,
		"TEMP=" + tmp,
		"TMP=" + tmp,
		"ALCOVE_UIA_START=" + strconv.Itoa(starts),
	}
}

// notPrepared is the error for a helper folder whose files could not be
// written.
func notPrepared(dir string, reason error) error {
	return fmt.Errorf("the UI helper could not be prepared in %s: %v; check free space and the folder's access list", dir, reason)
}

// notStarted is the error for a helper process that could not be started.
func notStarted(reason error) error {
	return fmt.Errorf("the UI helper could not be started (%v); restart alcove-agent and retry", reason)
}

// exitGate remembers the process of the latest start. It is used from one
// goroutine at a time.
type exitGate struct {
	exited chan struct{} // closed when that process has ended; nil before the first start
	stuck  bool          // a wait for that process ran out while it still ran
	onWait func()        // runs when waitPrevious waits for that process; may be nil
}

// waitPrevious returns true when no process was started before or the latest
// one has ended, and false when it still runs after limit or stop closed
// first. Once a wait for a process ran out, later calls do not wait for that
// process again and return false while it runs.
func (g *exitGate) waitPrevious(limit time.Duration, stop <-chan struct{}) bool {
	if g.exited == nil {
		return true
	}
	select {
	case <-g.exited:
		return true
	default:
	}
	if g.stuck {
		return false
	}
	if g.onWait != nil {
		g.onWait()
	}
	timer := time.NewTimer(limit)
	defer timer.Stop()
	select {
	case <-g.exited:
		return true
	case <-timer.C:
		g.stuck = true
		return false
	case <-stop:
		return false
	}
}

// started records a new process and returns the function that reports its
// end.
func (g *exitGate) started() (ended func()) {
	exited := make(chan struct{})
	g.exited = exited
	g.stuck = false
	return func() { close(exited) }
}

// helperProcess is a started helper process.
type helperProcess struct {
	stdin  io.WriteCloser
	stdout io.ReadCloser
	kill   func()
	wait   func() // returns when the process has ended and its log is closed
}

// launchSteps are the parts of a helper start.
type launchSteps struct {
	// prepare locks and empties the helper folder and writes the helper files.
	prepare func() error
	// start starts the helper process; starts is the number of earlier starts.
	start func(starts int) (*helperProcess, error)
}

// newLauncher returns a launcher that waits up to previousExitWait for the
// process of its previous start to end, then runs prepare, then start. It
// runs neither when the previous process still runs after the wait, and does
// not run start when prepare failed. A launcher whose stop channel is closed
// before a step runs that step no more and answers errClosed.
func newLauncher(steps launchSteps, gate *exitGate) Launcher {
	starts := 0
	return func(stop <-chan struct{}) (io.WriteCloser, io.ReadCloser, func(), error) {
		if stopped(stop) {
			return nil, nil, nil, errors.New(errClosed)
		}
		if !gate.waitPrevious(previousExitWait, stop) {
			if stopped(stop) {
				return nil, nil, nil, errors.New(errClosed)
			}
			return nil, nil, nil, fmt.Errorf("the previous UI helper process has not ended after %d s; retry", int(previousExitWait.Seconds()))
		}
		if err := steps.prepare(); err != nil {
			return nil, nil, nil, err
		}
		if stopped(stop) {
			return nil, nil, nil, errors.New(errClosed)
		}
		p, err := steps.start(starts)
		if err != nil {
			return nil, nil, nil, err
		}
		starts++
		ended := gate.started()
		go func() {
			p.wait()
			ended()
		}()
		return p.stdin, p.stdout, p.kill, nil
	}
}

// stopped reports whether stop is closed; a nil stop never is.
func stopped(stop <-chan struct{}) bool {
	select {
	case <-stop:
		return true
	default:
		return false
	}
}
