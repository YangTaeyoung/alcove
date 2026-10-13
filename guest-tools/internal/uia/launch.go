package uia

import (
	"fmt"
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

// exitGate remembers the process of the latest start. It is used from one
// goroutine at a time.
type exitGate struct {
	exited chan struct{} // closed when that process has ended; nil before the first start
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
