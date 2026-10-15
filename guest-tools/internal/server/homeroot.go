package server

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// writeFS is where the fs operations and file drops change entries: the plain
// file system for absolute paths, or the desktop session's home opened as an
// os.Root for paths relative to it.
type writeFS interface {
	Stat(name string) (fs.FileInfo, error)
	Lstat(name string) (fs.FileInfo, error)
	// OpenFile opens name; an entry it creates belongs to the owner of the
	// file system.
	OpenFile(name string, flag int, perm fs.FileMode) (*os.File, error)
	// MkdirAll creates name and its missing parents; the folders it creates
	// belong to the owner of the file system.
	MkdirAll(name string) error
	Rename(from, to string) error
	Remove(name string) error
	RemoveAll(name string) error
	ReadDir(name string) ([]fs.DirEntry, error)
	Close() error
}

// plainFS acts on absolute paths as the agent.
type plainFS struct{}

func (plainFS) Stat(name string) (fs.FileInfo, error)  { return os.Stat(name) }
func (plainFS) Lstat(name string) (fs.FileInfo, error) { return os.Lstat(name) }
func (plainFS) OpenFile(name string, flag int, perm fs.FileMode) (*os.File, error) {
	return os.OpenFile(name, flag, perm)
}
func (plainFS) MkdirAll(name string) error                 { return os.MkdirAll(name, 0o755) }
func (plainFS) Rename(from, to string) error               { return os.Rename(from, to) }
func (plainFS) Remove(name string) error                   { return os.Remove(name) }
func (plainFS) RemoveAll(name string) error                { return os.RemoveAll(name) }
func (plainFS) ReadDir(name string) ([]fs.DirEntry, error) { return os.ReadDir(name) }
func (plainFS) Close() error                               { return nil }

// homeFS acts on names relative to the session's home through an os.Root, so
// no name reaches outside the home, also through a link. Entries it creates
// are given to owner through their open descriptors.
type homeFS struct {
	home  string
	root  *os.Root
	owner fileOwner
}

func (h homeFS) Stat(name string) (fs.FileInfo, error)  { return h.root.Stat(name) }
func (h homeFS) Lstat(name string) (fs.FileInfo, error) { return h.root.Lstat(name) }

func (h homeFS) OpenFile(name string, flag int, perm fs.FileMode) (*os.File, error) {
	if flag&os.O_CREATE == 0 {
		return h.root.OpenFile(name, flag, perm)
	}
	f, err := h.root.OpenFile(name, flag|os.O_EXCL, perm)
	if err == nil {
		if err := h.owner.give(f); err != nil {
			f.Close()
			_ = h.root.Remove(name)
			return nil, err
		}
		return f, nil
	}
	if flag&os.O_EXCL != 0 || !errors.Is(err, fs.ErrExist) {
		return nil, err
	}
	return h.root.OpenFile(name, flag&^os.O_CREATE, perm)
}

func (h homeFS) MkdirAll(name string) error {
	cur := ""
	for _, part := range strings.Split(filepath.ToSlash(filepath.Clean(name)), "/") {
		if part == "" || part == "." {
			continue
		}
		cur = filepath.Join(cur, part)
		err := h.root.Mkdir(cur, 0o755)
		if errors.Is(err, fs.ErrExist) {
			continue
		}
		if err != nil {
			return err
		}
		d, err := h.root.Open(cur)
		if err != nil {
			return err
		}
		if fi, err := d.Stat(); err == nil && fi.IsDir() {
			err = h.owner.give(d)
		}
		d.Close()
		if err != nil {
			return err
		}
	}
	if fi, err := h.root.Stat(name); err != nil {
		return err
	} else if !fi.IsDir() {
		return &fs.PathError{Op: "mkdir", Path: name, Err: errors.New("not a directory")}
	}
	return nil
}

func (h homeFS) Rename(from, to string) error { return h.root.Rename(from, to) }
func (h homeFS) Remove(name string) error     { return h.root.Remove(name) }
func (h homeFS) RemoveAll(name string) error  { return h.root.RemoveAll(name) }
func (h homeFS) ReadDir(name string) ([]fs.DirEntry, error) {
	d, err := h.root.Open(name)
	if err != nil {
		return nil, err
	}
	defer d.Close()
	return d.ReadDir(-1)
}
func (h homeFS) Close() error { return h.root.Close() }

// homeError returns, for the error of an os.Root name that leads out of the
// home, a sentence that says so; other errors are returned as they are.
func homeError(err error) error {
	if err != nil && strings.Contains(err.Error(), "path escapes from parent") {
		return errors.New("the path leads out of the home folder of the desktop user through a link, which the agent does not follow there; pass the path the link leads to")
	}
	return err
}

// fileOwner is the user and group that give hands entries to when set.
type fileOwner struct {
	set      bool
	uid, gid int
}

// give makes the owner own the open file f.
func (o fileOwner) give(f *os.File) error {
	if !o.set {
		return nil
	}
	return f.Chown(o.uid, o.gid)
}

// sessionHome returns the desktop session's home directory and the owner of
// what the agent creates in it: the session's user and primary group while
// the agent runs as root and that user is not root. ok is false without a
// session, and when Options.HomeDir is set.
func (s *Server) sessionHome() (home string, owner fileOwner, ok bool) {
	if s.opt.HomeDir != "" {
		return "", fileOwner{}, false
	}
	sess, found := s.session()
	if !found || sess.Home == "" {
		return "", fileOwner{}, false
	}
	if os.Geteuid() == 0 && sess.UID != 0 {
		owner = fileOwner{set: true, uid: int(sess.UID), gid: int(sess.GID)}
	}
	return filepath.Clean(sess.Home), owner, true
}

// homeRelative returns path relative to home when path is home or lies below
// it, compared component by component; ok is false otherwise.
func homeRelative(home, path string) (string, bool) {
	if !pathContains(home, path, filepath.Separator, false) {
		return "", false
	}
	rel, err := filepath.Rel(home, path)
	if err != nil {
		return "", false
	}
	return rel, true
}

// writerFor returns the file system that changes path and path's name in
// it: the session's home opened as an os.Root for a path in that home, the
// plain file system otherwise. The caller closes the file system.
func (s *Server) writerFor(path string) (writeFS, string, error) {
	home, owner, ok := s.sessionHome()
	if !ok {
		return plainFS{}, path, nil
	}
	rel, in := homeRelative(home, path)
	if !in {
		return plainFS{}, path, nil
	}
	root, err := os.OpenRoot(home)
	if err != nil {
		return nil, "", err
	}
	return homeFS{home: home, root: root, owner: owner}, rel, nil
}

// inSessionHome reports whether path is the desktop session's home or lies
// below it.
func (s *Server) inSessionHome(path string) bool {
	home, _, ok := s.sessionHome()
	if !ok {
		return false
	}
	_, in := homeRelative(home, path)
	return in
}
