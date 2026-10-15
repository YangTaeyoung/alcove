package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

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

func procList(_ context.Context, req proto.Message) (proto.Message, error) {
	procs, err := listProcesses()
	if err != nil {
		return nil, fmt.Errorf("cannot list processes: %v", err)
	}
	return proto.Message{"procs": procListEntries(procs, req.String("name"))}, nil
}

// procListEntries builds the proc.list reply entries for the processes whose
// name contains filter, each command line cut to procListCmdChars characters.
func procListEntries(procs []procInfo, filter string) []any {
	filter = strings.ToLower(filter)
	out := []any{}
	for _, p := range procs {
		if filter != "" && !strings.Contains(strings.ToLower(p.Name), filter) {
			continue
		}
		out = append(out, map[string]any{
			"pid": p.PID, "ppid": p.PPID, "name": p.Name, "path": p.Path, "cmd": cutChars(p.Cmd, procListCmdChars), "mem_kb": p.MemKB,
		})
	}
	return out
}

func procKill(_ context.Context, req proto.Message) (proto.Message, error) {
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
	n, err := killNamed(name, tree)
	var refused *killRefusedError
	if errors.As(err, &refused) {
		return nil, err
	}
	if err != nil {
		return nil, fmt.Errorf("cannot kill '%s': %v; call proc.list to check it", name, err)
	}
	return proto.Message{"killed": n}, nil
}

// killNamed kills the processes of a name for proc.kill.
var killNamed = killByName

// killRefusedError is the answer of a kill by name that some processes
// refused.
type killRefusedError struct{ text string }

func (e *killRefusedError) Error() string { return e.text }

// killRefusal is the error of a kill by name of which denied processes
// refused access and killed processes ended.
func killRefusal(name string, killed, denied int) error {
	verb := "were"
	if killed == 1 {
		verb = "was"
	}
	return &killRefusedError{fmt.Sprintf("could not kill %d of the %d processes named '%s' because access was denied (%d %s killed); restart alcove-agent elevated through the scheduled task that alcove-agent --install creates, then retry",
		denied, killed+denied, name, killed, verb)}
}

// procEntry is a running process as a kill by name on Windows sees it.
type procEntry struct {
	PID, PPID int
	Name      string
	// Created is the creation time, zero when it is unknown.
	Created time.Time
}

// nameKillTargets returns the processes a kill by name on Windows ends: those
// whose name equals name without regard to case, with ".exe" added to a name
// without an extension, and with tree their descendants, each child before
// its parent. A process counts as a child of its parent only when it was not
// created before the parent. self and the processes below it are never
// targets.
func nameKillTargets(procs []procEntry, name string, tree bool, self int) []int {
	if filepath.Ext(name) == "" {
		name += ".exe"
	}
	byPID := make(map[int]procEntry, len(procs))
	for _, p := range procs {
		byPID[p.PID] = p
	}
	children := map[int][]int{}
	for _, p := range procs {
		parent, ok := byPID[p.PPID]
		if !ok || p.PPID == p.PID {
			continue
		}
		if !p.Created.IsZero() && !parent.Created.IsZero() && p.Created.Before(parent.Created) {
			continue
		}
		children[p.PPID] = append(children[p.PPID], p.PID)
	}
	seen := map[int]bool{self: true}
	out := []int{}
	var visit func(pid int)
	visit = func(pid int) {
		if seen[pid] {
			return
		}
		seen[pid] = true
		if tree {
			for _, c := range children[pid] {
				visit(c)
			}
		}
		out = append(out, pid)
	}
	for _, p := range procs {
		if strings.EqualFold(p.Name, name) {
			visit(p.PID)
		}
	}
	return out
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
