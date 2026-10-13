//go:build !windows

package server

import "syscall"

func pidAlive(pid int) bool { return syscall.Kill(pid, 0) == nil }

func killPIDForce(pid int) { _ = syscall.Kill(pid, syscall.SIGKILL) }
