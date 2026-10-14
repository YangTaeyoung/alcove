//go:build !windows

package main

import "syscall"

// exclusiveControl leaves the socket as it is outside Windows.
func exclusiveControl(string, string, syscall.RawConn) error { return nil }
