package server

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/session"
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
	// explain returns err, the error of an operation on name, as a sentence
	// when the file system refused a link.
	explain(name string, err error) error
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
func (plainFS) explain(_ string, err error) error          { return err }
func (plainFS) Close() error                               { return nil }

// homeFS acts on names relative to the session's home through an os.Root, so
// no name reaches outside the home, also through a link; os.Root follows only
// relative links that stay inside it. Entries it creates are given to owner
// without following a link: files through their open descriptors, folders by
// a chown of the folder itself.
type homeFS struct {
	home  string
	root  *os.Root
	owner fileOwner
	// user and uid name the session's user, whose files may be written
	// whatever their link count.
	user string
	uid  uint32
}

func (h homeFS) Stat(name string) (fs.FileInfo, error)  { return h.root.Stat(name) }
func (h homeFS) Lstat(name string) (fs.FileInfo, error) { return h.root.Lstat(name) }

// OpenFile creates name, given to the owner, or opens the existing file. An
// existing file that has other hard links and does not belong to the
// session's user is refused before it is truncated or written.
func (h homeFS) OpenFile(name string, flag int, perm fs.FileMode) (*os.File, error) {
	if flag&os.O_CREATE != 0 {
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
	}
	f, err := h.root.OpenFile(name, flag&^(os.O_CREATE|os.O_TRUNC), perm)
	if err != nil {
		return nil, err
	}
	fi, err := f.Stat()
	if err == nil && fi.Mode().IsRegular() && linkedElsewhere(fi, h.uid) {
		err = fmt.Errorf("it has other hard links and does not belong to %s, so it may be a file outside the home folder of the desktop user; write to that file's own path", h.user)
	}
	if err == nil && flag&os.O_TRUNC != 0 {
		err = f.Truncate(0)
	}
	if err != nil {
		f.Close()
		return nil, err
	}
	return f, nil
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
		if !h.owner.set {
			continue
		}
		if fi, err := h.root.Lstat(cur); err != nil || !fi.IsDir() {
			continue
		}
		if err := h.root.Lchown(cur, h.owner.uid, h.owner.gid); err != nil {
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

// explain returns, for the error of an os.Root name that leaves the root, a
// sentence that names the link with an absolute target on the way to name,
// with relink advice only when that target lies inside the home,
// or says that the path leads out of the home; other errors are returned as
// they are.
func (h homeFS) explain(name string, err error) error {
	if err == nil || !strings.Contains(err.Error(), "path escapes from parent") {
		return err
	}
	cur := ""
	for _, part := range strings.Split(filepath.ToSlash(filepath.Clean(name)), "/") {
		if part == "" || part == "." {
			continue
		}
		cur = filepath.Join(cur, part)
		fi, lerr := h.root.Lstat(cur)
		if lerr != nil {
			break
		}
		if fi.Mode()&fs.ModeSymlink == 0 {
			continue
		}
		target, rerr := h.root.Readlink(cur)
		if rerr != nil || !filepath.IsAbs(target) {
			continue
		}
		link := filepath.Join(h.home, cur)
		if _, inside := homeRelative(h.home, filepath.Clean(target)); !inside {
			return fmt.Errorf("'%s' is a link with the absolute target '%s' outside the home folder of the desktop user, which the agent does not follow there; pass the path it leads to",
				link, target)
		}
		return fmt.Errorf("'%s' is a link with the absolute target '%s', and the agent follows only relative links inside the home folder of the desktop user; make it a relative link or pass the path it leads to",
			link, target)
	}
	return errors.New("the path leads out of the home folder of the desktop user through a link, which the agent does not follow there; pass the path the link leads to")
}

// explainEither explains err, the error of an operation on the names a and
// b, by the name whose explanation names a link with an absolute target,
// else by b.
func explainEither(fsys writeFS, a, b string, err error) error {
	if ea := fsys.explain(a, err); strings.Contains(ea.Error(), "absolute target") {
		return ea
	}
	return fsys.explain(b, err)
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

// homeView is the home directory one request works with, read once for the
// whole request.
type homeView struct {
	// dir is the home of ~ and relative paths.
	dir string
	// sess is the desktop session when hasSess is set.
	sess    session.Session
	hasSess bool
	// inSession says that dir is the session's home, whose entries are changed
	// through an os.Root and given to owner.
	inSession bool
	owner     fileOwner
}

// usableHome reports whether home can serve as a session's home: an absolute
// path other than the file-system root.
func usableHome(home string) bool {
	return filepath.IsAbs(home) && filepath.Clean(home) != string(filepath.Separator)
}

// view reads the home of a request: Options.HomeDir when set; else the
// desktop session's home when the session has a usable one, with the
// session's user and primary group as the owner of new entries while the
// agent runs as root and that user is not root; else the agent's own home.
func (s *Server) view() homeView {
	if s.opt.HomeDir != "" {
		return homeView{dir: s.opt.HomeDir}
	}
	v := homeView{dir: s.ownHome}
	sess, ok := s.session()
	if !ok {
		return v
	}
	v.sess, v.hasSess = sess, true
	if !usableHome(sess.Home) {
		return v
	}
	v.dir, v.inSession = filepath.Clean(sess.Home), true
	if os.Geteuid() == 0 && sess.UID != 0 {
		v.owner = fileOwner{set: true, uid: int(sess.UID), gid: int(sess.GID)}
	}
	return v
}

// contains reports whether path is the session's home of v or lies below it.
func (v homeView) contains(path string) bool {
	if !v.inSession {
		return false
	}
	_, in := homeRelative(v.dir, path)
	return in
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

// writerIn returns the file system that changes path and path's name in it:
// the session's home of v opened as an os.Root for a path in that home, the
// plain file system otherwise. The caller closes the file system.
func (s *Server) writerIn(v homeView, path string) (writeFS, string, error) {
	if !v.contains(path) {
		return plainFS{}, path, nil
	}
	rel, _ := homeRelative(v.dir, path)
	root, err := os.OpenRoot(v.dir)
	if err != nil {
		return nil, "", err
	}
	return homeFS{home: v.dir, root: root, owner: v.owner, user: v.sess.User, uid: v.sess.UID}, rel, nil
}
