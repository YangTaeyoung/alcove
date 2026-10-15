package server

import (
	"fmt"
	"net"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

func startSecondConn(t *testing.T, s *Server) (*rpcClient, net.Conn) {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go s.Serve(l)
	conn, err := net.Dial("tcp", l.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	conn.SetDeadline(time.Now().Add(10 * time.Second))
	t.Cleanup(func() { conn.Close(); l.Close() })
	r := proto.NewReader(conn)
	expect(t, r, "hello")
	deadline := time.Now().Add(5 * time.Second)
	for {
		s.connMu.Lock()
		n := len(s.conns)
		s.connMu.Unlock()
		if n >= 2 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("second connection not registered")
		}
		time.Sleep(10 * time.Millisecond)
	}
	return &rpcClient{t: t, r: r, w: proto.NewWriter(conn)}, conn
}

func TestProcKillErrors(t *testing.T) {
	c, _ := newRPCClient(t, Options{})
	res := c.call("proc.kill", proto.Message{})
	if res["ok"] != false || res.String("error") != "missing pid or name" {
		t.Fatalf("res %v", res)
	}
	res = c.call("proc.kill", proto.Message{"pid": 2147483000})
	if res["ok"] != false || res.String("error") == "" {
		t.Fatalf("res %v", res)
	}
	res = c.ok("proc.kill", proto.Message{"name": "alcove-no-such-process"})
	if res.Int("killed") != 0 {
		t.Fatalf("res %v", res)
	}
}

func TestProcListIncludesSelf(t *testing.T) {
	c, _ := newRPCClient(t, Options{})
	procs, _ := c.ok("proc.list", nil)["procs"].([]any)
	self := os.Getpid()
	for _, p := range procs {
		if int(p.(map[string]any)["pid"].(float64)) == self {
			return
		}
	}
	t.Fatalf("pid %d not in %d listed processes", self, len(procs))
}

func TestParseWindowsProcesses(t *testing.T) {
	one := `{"ProcessId":4,"ParentProcessId":0,"Name":"System","ExecutablePath":null,"CommandLine":null,"WorkingSetSize":8192}`
	procs, err := parseWindowsProcesses([]byte("\xef\xbb\xbf" + one))
	if err != nil || len(procs) != 1 || procs[0].PID != 4 || procs[0].Name != "System" || procs[0].MemKB != 8 {
		t.Fatalf("single object: %+v %v", procs, err)
	}
	many := `[` + one + `,{"ProcessId":10,"ParentProcessId":4,"Name":"a.exe","ExecutablePath":"C:\\a.exe","CommandLine":"a.exe -x","WorkingSetSize":2048000}]`
	procs, err = parseWindowsProcesses([]byte(many))
	if err != nil || len(procs) != 2 || procs[1].PPID != 4 || procs[1].Path != `C:\a.exe` || procs[1].Cmd != "a.exe -x" || procs[1].MemKB != 2000 {
		t.Fatalf("array: %+v %v", procs, err)
	}
	if procs, err = parseWindowsProcesses(nil); err != nil || len(procs) != 0 {
		t.Fatalf("empty: %+v %v", procs, err)
	}
}

func TestNameKillTargetsMatchTheImageNameAndPutChildrenFirst(t *testing.T) {
	at := func(s int) time.Time { return time.Unix(1000+int64(s), 0) }
	procs := []procEntry{
		{PID: 4, PPID: 0, Name: "System", Created: at(0)},
		{PID: 10, PPID: 4, Name: "Victim.EXE", Created: at(1)},
		{PID: 11, PPID: 10, Name: "child.exe", Created: at(2)},
		{PID: 12, PPID: 11, Name: "grandchild.exe", Created: at(3)},
		{PID: 13, PPID: 10, Name: "older.exe", Created: at(0)},
		{PID: 20, PPID: 4, Name: "victim.exe", Created: at(1)},
		{PID: 21, PPID: 20, Name: "victim.exe", Created: at(2)},
		{PID: 30, PPID: 4, Name: "victim.exe.old", Created: at(1)},
		{PID: 40, PPID: 10, Name: "agent.exe", Created: at(2)},
		{PID: 41, PPID: 40, Name: "job.exe", Created: at(3)},
	}
	cases := []struct {
		name string
		tree bool
		want string
	}{
		{"victim", false, "[10 20 21]"},
		{"VICTIM.exe", false, "[10 20 21]"},
		{"victim", true, "[12 11 10 21 20]"},
		{"victim.exe.old", false, "[30]"},
		{"agent", true, "[]"},
		{"none", true, "[]"},
	}
	for _, c := range cases {
		if got := fmt.Sprint(nameKillTargets(procs, c.name, c.tree, 40)); got != c.want {
			t.Errorf("%s tree %v: %s, expected %s", c.name, c.tree, got, c.want)
		}
	}
}

func TestTheRefusalOfAKillByNameNamesElevation(t *testing.T) {
	got := killRefusal("svc", 1, 2).Error()
	want := "could not kill 2 of the 3 processes named 'svc' because access was denied (1 was killed); restart alcove-agent elevated through the scheduled task that alcove-agent --install creates, then retry"
	if got != want {
		t.Fatalf("refusal %q", got)
	}
	if got := killRefusal("svc", 0, 1).Error(); !strings.HasPrefix(got, "could not kill 1 of the 1 processes named 'svc' because access was denied (0 were killed); ") {
		t.Fatalf("refusal %q", got)
	}
}

func TestProcKillAnswersTheRefusalOfAKillByNameAsItIs(t *testing.T) {
	kill := killNamed
	killNamed = func(string, bool) (int, error) { return 0, killRefusal("svc", 0, 1) }
	t.Cleanup(func() { killNamed = kill })
	c, _ := newRPCClient(t, Options{})
	res := c.call("proc.kill", proto.Message{"name": "svc"})
	if res["ok"] != false || res.String("error") != killRefusal("svc", 0, 1).Error() {
		t.Fatalf("res %v", res)
	}
}
