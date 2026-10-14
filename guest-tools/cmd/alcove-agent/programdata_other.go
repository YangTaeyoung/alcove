//go:build !windows

package main

import "errors"

// programDataFolder fails outside Windows, which has no ProgramData folder.
func programDataFolder() (string, error) {
	return "", errors.New("this system has no ProgramData folder")
}
