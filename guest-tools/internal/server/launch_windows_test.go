//go:build windows

package server

import "strconv"

// exitProgram returns the app.launch path and args of a program that exits
// with code.
func exitProgram(code int) (string, []string) {
	return "cmd.exe", []string{"/c", "exit", strconv.Itoa(code)}
}
