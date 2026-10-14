//go:build windows

package server

import "errors"

func mkfifo(string) error { return errors.New("named pipes are not files on Windows") }
