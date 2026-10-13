package uia

import (
	"errors"
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
