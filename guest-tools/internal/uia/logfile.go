package uia

import (
	"os"
	"sync"
)

const maxLogBytes = 1 << 20

// cappedLog appends to a file of at most max bytes. A write that would pass
// the limit moves the file to <path>.1, replacing the previous one, and
// starts an empty file. A write always reports success: what cannot be
// stored is dropped, and the next write opens the file again.
type cappedLog struct {
	path string
	max  int64

	mu     sync.Mutex
	f      *os.File
	size   int64
	mode   int // open flags for the next open of the file
	closed bool
}

func openCappedLog(path string, max int64) (*cappedLog, error) {
	l := &cappedLog{path: path, max: max, mode: os.O_APPEND}
	if err := l.open(); err != nil {
		return nil, err
	}
	return l, nil
}

func (l *cappedLog) open() error {
	f, err := os.OpenFile(l.path, os.O_CREATE|os.O_WRONLY|l.mode, 0o644)
	if err != nil {
		return err
	}
	st, err := f.Stat()
	if err != nil {
		f.Close()
		return err
	}
	l.f, l.size, l.mode = f, st.Size(), os.O_APPEND
	return nil
}

// Write appends p; of a p longer than the limit it keeps the end. It fails
// only after Close.
func (l *cappedLog) Write(p []byte) (int, error) {
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
			l.mode = os.O_APPEND | os.O_TRUNC
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

func (l *cappedLog) Close() error {
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
