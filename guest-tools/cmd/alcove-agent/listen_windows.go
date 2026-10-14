//go:build windows

package main

import "syscall"

// soExclusiveAddrUse is SO_EXCLUSIVEADDRUSE of winsock2.h, ~SO_REUSEADDR.
const soExclusiveAddrUse = ^syscall.SO_REUSEADDR

// exclusiveControl sets SO_EXCLUSIVEADDRUSE on the socket, so no other socket
// can bind its port on any address while it is bound.
func exclusiveControl(_, _ string, c syscall.RawConn) error {
	var serr error
	if err := c.Control(func(fd uintptr) {
		serr = syscall.SetsockoptInt(syscall.Handle(fd), syscall.SOL_SOCKET, soExclusiveAddrUse, 1)
	}); err != nil {
		return err
	}
	return serr
}
