// Package logfile writes log files of bounded size.
package logfile

import (
	"os"
	"sync"
)

// MaxBytes is the size limit of agent.log and helper.log.
const MaxBytes = 1 << 20

// OpenFunc opens a file the way os.OpenFile does.
type OpenFunc func(name string, flag int, perm os.FileMode) (*os.File, error)

// Log appends to a file of at most max bytes. A write that would pass the
// limit moves the file to <path>.1, replacing the previous one, and starts an
// empty file; when the file cannot be moved it is emptied instead. A write
// always reports success: what cannot be stored is dropped, and the next
// write opens the file again.
type Log struct {
	path     string
	max      int64
	openFile OpenFunc

	mu       sync.Mutex
	f        *os.File
	size     int64
	truncate bool // the next open empties the file first
	closed   bool
}

// Open opens path for appending with open, or with os.OpenFile when open is
// nil, and creates it when it is missing.
func Open(path string, max int64, open OpenFunc) (*Log, error) {
	if open == nil {
		open = os.OpenFile
	}
	l := &Log{path: path, max: max, openFile: open}
	if err := l.open(); err != nil {
		return nil, err
	}
	return l, nil
}

// open empties the file when truncate is set, then opens it for appending
// only.
func (l *Log) open() error {
	if l.truncate {
		f, err := l.openFile(l.path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
		if err != nil {
			return err
		}
		f.Close()
		l.truncate = false
	}
	f, err := l.openFile(l.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	st, err := f.Stat()
	if err != nil {
		f.Close()
		return err
	}
	l.f, l.size = f, st.Size()
	return nil
}

// Write appends p; of a p longer than the limit it keeps the end. It fails
// only after Close.
func (l *Log) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	n := len(p)
	if l.closed {
		return 0, os.ErrClosed
	}
	if int64(len(p)) > l.max {
		p = p[int64(len(p))-l.max:]
	}
	if l.f == nil && l.open() != nil {
		return n, nil
	}
	if l.size > 0 && l.size+int64(len(p)) > l.max {
		l.f.Close()
		l.f = nil
		_ = os.Remove(l.path + ".1")
		if err := os.Rename(l.path, l.path+".1"); err != nil {
			l.truncate = true
		}
		if l.open() != nil {
			return n, nil
		}
	}
	w, err := l.f.Write(p)
	l.size += int64(w)
	if err != nil {
		l.f.Close()
		l.f = nil
	}
	return n, nil
}

// Close closes the file; later writes fail.
func (l *Log) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.closed = true
	if l.f == nil {
		return nil
	}
	err := l.f.Close()
	l.f = nil
	return err
}
