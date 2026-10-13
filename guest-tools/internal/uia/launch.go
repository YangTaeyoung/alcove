package uia

import (
	"fmt"
	"io"
	"strings"
	"time"
)

// previousExitWait is how long a start waits for the process of the start
// before it to end.
const previousExitWait = 10 * time.Second

// cleanHelperEnv returns environ without the COR_*, COMPlus_*, DOTNET_*,
// PSModulePath, TEMP and TMP variables and without entries that have no '=',
// followed by TEMP and TMP set to tmp. Names are compared without regard to
// case.
func cleanHelperEnv(environ []string, tmp string) []string {
	env := make([]string, 0, len(environ)+2)
	for _, kv := range environ {
		eq := strings.IndexByte(kv, '=')
		if eq < 0 {
			continue
		}
		name := strings.ToUpper(kv[:eq])
		if strings.HasPrefix(name, "COR_") || strings.HasPrefix(name, "COMPLUS_") ||
			strings.HasPrefix(name, "DOTNET_") || name == "PSMODULEPATH" || name == "TEMP" || name == "TMP" {
			continue
		}
		env = append(env, kv)
	}
	return append(env, "TEMP="+tmp, "TMP="+tmp)
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
	onWait func()        // runs when waitPrevious finds that process still running; may be nil
}

// waitPrevious returns true when no process was started before or the latest
// one has ended, and false when it still runs after limit.
func (g *exitGate) waitPrevious(limit time.Duration) bool {
	if g.exited == nil {
		return true
	}
	select {
	case <-g.exited:
		return true
	default:
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
		return false
	}
}

// started records a new process and returns the function that reports its
// end.
func (g *exitGate) started() (ended func()) {
	exited := make(chan struct{})
	g.exited = exited
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
// not run start when prepare failed.
func newLauncher(steps launchSteps, gate *exitGate) Launcher {
	starts := 0
	return func() (io.WriteCloser, io.ReadCloser, func(), error) {
		if !gate.waitPrevious(previousExitWait) {
			return nil, nil, nil, fmt.Errorf("the previous UI helper process has not ended after %d s; retry", int(previousExitWait.Seconds()))
		}
		if err := steps.prepare(); err != nil {
			return nil, nil, nil, err
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
