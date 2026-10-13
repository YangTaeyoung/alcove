//go:build windows

package server

func pidAlive(int) bool { return false }

func killPIDForce(pid int) { _ = killPID(pid) }
