package server

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

type procInfo struct {
	PID, PPID       int
	Name, Path, Cmd string
	MemKB           int
}

func (s *Server) registerProcs() {
	s.register("proc.list", true, procList)
	s.register("proc.kill", true, procKill)
}

func procList(req proto.Message) (proto.Message, error) {
	procs, err := listProcesses()
	if err != nil {
		return nil, fmt.Errorf("cannot list processes: %v", err)
	}
	filter := strings.ToLower(req.String("name"))
	out := []any{}
	for _, p := range procs {
		if filter != "" && !strings.Contains(strings.ToLower(p.Name), filter) {
			continue
		}
		out = append(out, map[string]any{
			"pid": p.PID, "ppid": p.PPID, "name": p.Name, "path": p.Path, "cmd": p.Cmd, "mem_kb": p.MemKB,
		})
	}
	return proto.Message{"procs": out}, nil
}

func procKill(req proto.Message) (proto.Message, error) {
	tree := req.Bool("tree")
	if pid := req.Int("pid"); pid > 0 {
		var err error
		if tree {
			err = killTree(pid)
		} else {
			err = killPID(pid)
		}
		if err != nil {
			return nil, fmt.Errorf("cannot kill pid %d: %v; call proc.list to check it", pid, err)
		}
		return proto.Message{"killed": 1}, nil
	}
	name := req.String("name")
	if name == "" {
		return nil, fmt.Errorf("missing pid or name")
	}
	n, err := killByName(name, tree)
	if err != nil {
		return nil, fmt.Errorf("cannot kill '%s': %v; call proc.list to check it", name, err)
	}
	return proto.Message{"killed": n}, nil
}

func killPID(pid int) error {
	p, err := os.FindProcess(pid)
	if err != nil {
		return err
	}
	return p.Kill()
}

type windowsProcess struct {
	ProcessId       int
	ParentProcessId int
	Name            string
	ExecutablePath  *string
	CommandLine     *string
	WorkingSetSize  float64
}

// parseWindowsProcesses reads the Get-CimInstance JSON, which is a bare
// object when exactly one process matched.
func parseWindowsProcesses(data []byte) ([]procInfo, error) {
	data = bytes.TrimSpace(bytes.TrimPrefix(bytes.TrimSpace(data), []byte("\xef\xbb\xbf")))
	if len(data) == 0 {
		return nil, nil
	}
	var raw []windowsProcess
	if data[0] == '[' {
		if err := json.Unmarshal(data, &raw); err != nil {
			return nil, err
		}
	} else {
		var one windowsProcess
		if err := json.Unmarshal(data, &one); err != nil {
			return nil, err
		}
		raw = []windowsProcess{one}
	}
	out := make([]procInfo, 0, len(raw))
	for _, w := range raw {
		p := procInfo{PID: w.ProcessId, PPID: w.ParentProcessId, Name: w.Name, MemKB: int(w.WorkingSetSize / 1024)}
		if w.ExecutablePath != nil {
			p.Path = *w.ExecutablePath
		}
		if w.CommandLine != nil {
			p.Cmd = *w.CommandLine
		}
		out = append(out, p)
	}
	return out, nil
}
