package uia

import (
	"errors"
	"io"
	"reflect"
	"testing"
	"time"
)

func TestHelperEnvHoldsOnlyTheSystemFoldersAndTheLockedTemp(t *testing.T) {
	got := helperEnv(`D:\WINDOWS`, `D:\WINDOWS\system32`, `C:\ProgramData\Alcove\uia\tmp`, 3)
	want := []string{
		`SystemRoot=D:\WINDOWS`,
		`windir=D:\WINDOWS`,
		`SystemDrive=D:`,
		`ComSpec=D:\WINDOWS\system32\cmd.exe`,
		`PATH=D:\WINDOWS\system32;D:\WINDOWS;D:\WINDOWS\system32\Wbem;D:\WINDOWS\system32\WindowsPowerShell\v1.0`,
		`PSModulePath=D:\WINDOWS\system32\WindowsPowerShell\v1.0\Modules`,
		`PSModuleAnalysisCachePath=C:\ProgramData\Alcove\uia\tmp\ModuleAnalysisCache`,
		`TEMP=C:\ProgramData\Alcove\uia\tmp`,
		`TMP=C:\ProgramData\Alcove\uia\tmp`,
		`ALCOVE_UIA_START=3`,
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("env\n got %q\nwant %q", got, want)
	}
}

func TestNotPreparedNamesTheFolderTheReasonAndTheNextStep(t *testing.T) {
	err := notPrepared(`C:\ProgramData\Alcove\uia`, errors.New("mkdir tmp: disk full"))
	want := `the UI helper could not be prepared in C:\ProgramData\Alcove\uia: mkdir tmp: disk full; check free space and the folder's access list`
	if err.Error() != want {
		t.Fatalf("err %q", err)
	}
}

func TestExitGateLetsTheFirstStartThrough(t *testing.T) {
	var g exitGate
	if !g.waitPrevious(0, nil) {
		t.Fatal("a gate without an earlier start did not open")
	}
}

func TestExitGateOpensWhenThePreviousProcessHasEnded(t *testing.T) {
	var g exitGate
	ended := g.started()
	waiting := make(chan struct{})
	opened := make(chan bool, 1)
	go func() {
		close(waiting)
		opened <- g.waitPrevious(longWait, nil)
	}()
	<-waiting
	ended()
	if !<-opened {
		t.Fatal("the gate stayed shut after the previous process ended")
	}
	if !g.waitPrevious(0, nil) {
		t.Fatal("the gate shut again for a process that has ended")
	}
}

func TestExitGateStaysShutWhileThePreviousProcessRuns(t *testing.T) {
	var g exitGate
	ended := g.started()
	if g.waitPrevious(20*time.Millisecond, nil) {
		t.Fatal("the gate opened while the previous process ran")
	}
	ended()
	next := g.started()
	if g.waitPrevious(20*time.Millisecond, nil) {
		t.Fatal("the gate opened while the second process ran")
	}
	next()
	if !g.waitPrevious(0, nil) {
		t.Fatal("the gate stayed shut after the second process ended")
	}
}

func TestNotStartedNamesTheReasonAndTheNextStep(t *testing.T) {
	err := notStarted(errors.New("The system cannot find the file specified."))
	want := "the UI helper could not be started (The system cannot find the file specified.); restart alcove-agent and retry"
	if err.Error() != want {
		t.Fatalf("err %q", err)
	}
}

// fakeProcess is a helper process that ends when exit is closed.
type fakeProcess struct {
	exit chan struct{}
}

func (p *fakeProcess) process() *helperProcess {
	in, _ := io.Pipe()
	_, out := io.Pipe()
	return &helperProcess{stdin: out, stdout: in, kill: func() {}, wait: func() { <-p.exit }}
}

func TestLauncherPreparesTheFolderOnlyAfterThePreviousProcessEnded(t *testing.T) {
	first := &fakeProcess{exit: make(chan struct{})}
	second := &fakeProcess{exit: make(chan struct{})}
	defer close(second.exit)
	var steps []string
	firstEnded := false
	waiting := make(chan struct{})
	gate := &exitGate{onWait: func() { close(waiting) }}
	launch := newLauncher(launchSteps{
		prepare: func() error {
			if len(steps) > 0 && !firstEnded {
				t.Error("the folder was prepared while the previous process ran")
			}
			steps = append(steps, "prepare")
			return nil
		},
		start: func(starts int) (*helperProcess, error) {
			steps = append(steps, "start")
			if starts == 0 {
				return first.process(), nil
			}
			return second.process(), nil
		},
	}, gate)
	if _, _, _, err := launch(nil); err != nil {
		t.Fatal(err)
	}
	launched := make(chan error, 1)
	go func() {
		_, _, _, err := launch(nil)
		launched <- err
	}()
	<-waiting
	if got := len(steps); got != 2 {
		t.Fatalf("steps while the previous process runs: %q", steps)
	}
	firstEnded = true
	close(first.exit)
	if err := <-launched; err != nil {
		t.Fatal(err)
	}
	if want := []string{"prepare", "start", "prepare", "start"}; !reflect.DeepEqual(steps, want) {
		t.Fatalf("steps %q, expected %q", steps, want)
	}
}

func TestLauncherPassesTheNumberOfEarlierStarts(t *testing.T) {
	var got []int
	launch := newLauncher(launchSteps{
		prepare: func() error { return nil },
		start: func(starts int) (*helperProcess, error) {
			got = append(got, starts)
			p := &fakeProcess{exit: make(chan struct{})}
			close(p.exit)
			return p.process(), nil
		},
	}, &exitGate{})
	for i := 0; i < 3; i++ {
		if _, _, _, err := launch(nil); err != nil {
			t.Fatal(err)
		}
	}
	if want := []int{0, 1, 2}; !reflect.DeepEqual(got, want) {
		t.Fatalf("starts %v, expected %v", got, want)
	}
}

func TestLauncherDoesNotStartWhenTheFolderIsNotPrepared(t *testing.T) {
	started := false
	launch := newLauncher(launchSteps{
		prepare: func() error { return errors.New("not locked") },
		start: func(int) (*helperProcess, error) {
			started = true
			return nil, errors.New("unexpected")
		},
	}, &exitGate{})
	if _, _, _, err := launch(nil); err == nil || err.Error() != "not locked" {
		t.Fatalf("err %v", err)
	}
	if started {
		t.Fatal("the process was started")
	}
}

func TestExitGateDoesNotWaitAgainForAProcessThatOutlastedAWait(t *testing.T) {
	var g exitGate
	ended := g.started()
	if g.waitPrevious(20*time.Millisecond, nil) {
		t.Fatal("the gate opened while the previous process ran")
	}
	began := time.Now()
	if g.waitPrevious(longWait, nil) {
		t.Fatal("the gate opened while the previous process still ran")
	}
	if waited := time.Since(began); waited >= longWait {
		t.Fatalf("the second wait took %v", waited)
	}
	ended()
	if !g.waitPrevious(0, nil) {
		t.Fatal("the gate stayed shut after the process ended")
	}
	next := g.started()
	defer next()
	waits := 0
	g.onWait = func() { waits++ }
	g.waitPrevious(20*time.Millisecond, nil)
	if waits != 1 {
		t.Fatalf("a new process was waited for %d times", waits)
	}
}

func TestExitGateStopsWaitingWhenStopCloses(t *testing.T) {
	var g exitGate
	ended := g.started()
	defer ended()
	stop := make(chan struct{})
	g.onWait = func() { close(stop) }
	if g.waitPrevious(longWait, stop) {
		t.Fatal("the gate opened while the previous process ran")
	}
}

func TestLauncherRunsNoStepAfterStop(t *testing.T) {
	var steps []string
	launch := newLauncher(launchSteps{
		prepare: func() error { steps = append(steps, "prepare"); return nil },
		start: func(int) (*helperProcess, error) {
			steps = append(steps, "start")
			return nil, errors.New("unexpected")
		},
	}, &exitGate{})
	stop := make(chan struct{})
	close(stop)
	if _, _, _, err := launch(stop); err == nil || err.Error() != errClosed {
		t.Fatalf("err %v", err)
	}
	if len(steps) != 0 {
		t.Fatalf("steps %q", steps)
	}
}

func TestLauncherDoesNotStartWhenStopClosesDuringPrepare(t *testing.T) {
	stop := make(chan struct{})
	started := false
	launch := newLauncher(launchSteps{
		prepare: func() error { close(stop); return nil },
		start: func(int) (*helperProcess, error) {
			started = true
			return nil, errors.New("unexpected")
		},
	}, &exitGate{})
	if _, _, _, err := launch(stop); err == nil || err.Error() != errClosed || started {
		t.Fatalf("err %v, started %v", err, started)
	}
}
