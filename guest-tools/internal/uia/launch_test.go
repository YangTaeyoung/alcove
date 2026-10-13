package uia

import (
	"errors"
	"io"
	"reflect"
	"testing"
	"time"
)

func TestCleanHelperEnv(t *testing.T) {
	environ := []string{
		`SystemRoot=C:\Windows`,
		`COR_ENABLE_PROFILING=1`,
		`cor_profiler={1234}`,
		`COMPlus_Version=v2`,
		`complus_x=1`,
		`DOTNET_ROOT=C:\dotnet`,
		`DotNet_Startup_Hooks=C:\x.dll`,
		`PSModulePath=C:\mods`,
		`psmodulepath=C:\other`,
		`TEMP=C:\Users\a\Temp`,
		`Tmp=C:\Users\a\Tmp`,
		`TEMPORARY=kept`,
		`CORE=kept`,
		`=C:=C:\Users`,
		`NOEQUALS`,
		`EMPTY=`,
		`A=b=c`,
	}
	got := cleanHelperEnv(environ, `C:\ProgramData\Alcove\uia\tmp`)
	want := []string{
		`SystemRoot=C:\Windows`,
		`TEMPORARY=kept`,
		`CORE=kept`,
		`=C:=C:\Users`,
		`EMPTY=`,
		`A=b=c`,
		`TEMP=C:\ProgramData\Alcove\uia\tmp`,
		`TMP=C:\ProgramData\Alcove\uia\tmp`,
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("env\n got %q\nwant %q", got, want)
	}
	if got := cleanHelperEnv(nil, "T"); !reflect.DeepEqual(got, []string{"TEMP=T", "TMP=T"}) {
		t.Fatalf("env of an empty environment: %q", got)
	}
	if environ[1] != `COR_ENABLE_PROFILING=1` || len(environ) != 17 {
		t.Fatalf("the input was changed: %q", environ)
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
	if !g.waitPrevious(0) {
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
		opened <- g.waitPrevious(longWait)
	}()
	<-waiting
	ended()
	if !<-opened {
		t.Fatal("the gate stayed shut after the previous process ended")
	}
	if !g.waitPrevious(0) {
		t.Fatal("the gate shut again for a process that has ended")
	}
}

func TestExitGateStaysShutWhileThePreviousProcessRuns(t *testing.T) {
	var g exitGate
	ended := g.started()
	if g.waitPrevious(20 * time.Millisecond) {
		t.Fatal("the gate opened while the previous process ran")
	}
	ended()
	next := g.started()
	if g.waitPrevious(20 * time.Millisecond) {
		t.Fatal("the gate opened while the second process ran")
	}
	next()
	if !g.waitPrevious(0) {
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
	if _, _, _, err := launch(); err != nil {
		t.Fatal(err)
	}
	launched := make(chan error, 1)
	go func() {
		_, _, _, err := launch()
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
		if _, _, _, err := launch(); err != nil {
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
	if _, _, _, err := launch(); err == nil || err.Error() != "not locked" {
		t.Fatalf("err %v", err)
	}
	if started {
		t.Fatal("the process was started")
	}
}
