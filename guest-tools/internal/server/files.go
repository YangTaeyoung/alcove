package server

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/proto"
)

const (
	fsChunkMax    = 262144
	fsTailWindow  = 262144
	fsTailDefault = 200
	fsListMax     = 5000
)

// resolvePath maps "~", "~/x", relative and absolute paths to an absolute
// path; relative forms resolve against Options.HomeDir.
func (s *Server) resolvePath(p string) (string, error) {
	if p == "" {
		return "", errors.New("missing path; pass a file or directory path")
	}
	home := s.opt.HomeDir
	switch {
	case p == "~":
		return filepath.Clean(home), nil
	case strings.HasPrefix(p, "~/") || strings.HasPrefix(p, `~\`):
		return filepath.Join(home, filepath.FromSlash(strings.ReplaceAll(p[2:], `\`, "/"))), nil
	case filepath.IsAbs(p):
		return filepath.Clean(p), nil
	}
	return filepath.Join(home, p), nil
}

// windowsPathFormError refuses the Windows path forms that depend on a
// current folder the caller cannot see: a drive with no separator after it
// ("C:foo") and a path that starts at the root of the current drive ("\x").
// Other paths answer nil.
func windowsPathFormError(p string) error {
	if len(p) >= 2 && p[1] == ':' && (len(p) == 2 || p[2] != '\\' && p[2] != '/') {
		return fmt.Errorf("'%s' is relative to the current folder of drive %s; pass a full path such as %s\\%s", p, p[:2], p[:2], p[2:])
	}
	if p != "" && (p[0] == '\\' || p[0] == '/') && !(len(p) >= 2 && (p[1] == '\\' || p[1] == '/')) {
		return fmt.Errorf("'%s' starts at the root of the agent's current drive; pass a full path with its drive, such as C:%s", p, strings.ReplaceAll(p, "/", `\`))
	}
	return nil
}

func (s *Server) pathArg(req proto.Message, key string) (string, error) {
	if runtime.GOOS == "windows" {
		if err := windowsPathFormError(req.String(key)); err != nil {
			return "", err
		}
	}
	return s.resolvePath(req.String(key))
}

func mtimeString(fi os.FileInfo) string {
	return fi.ModTime().UTC().Format(time.RFC3339)
}

// notRegular is the error for a path that is neither a regular file nor a
// directory, such as a FIFO.
func notRegular(path string) error {
	return fmt.Errorf("'%s' is not a regular file; fs.read, fs.tail and sha256 read regular files only", path)
}

// isIrregular reports whether path leads to something other than a regular
// file or a directory.
func isIrregular(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && !fi.IsDir() && !fi.Mode().IsRegular()
}

func fileDigest(path string) (string, error) {
	if isIrregular(path) {
		return "", notRegular(path)
	}
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", fmt.Errorf("cannot read '%s': %v", path, err)
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func (s *Server) registerFiles() {
	s.register("fs.stat", true, s.fsStat)
	s.register("fs.list", true, s.fsList)
	s.register("fs.read", true, s.fsRead)
	s.register("fs.tail", true, s.fsTail)
	s.register("fs.write", true, s.fsWrite)
	s.register("fs.rename", true, s.fsRename)
	s.register("fs.mkdir", true, s.fsMkdir)
	s.register("fs.delete", true, s.fsDelete)
}

// isLink reports whether mode, read without following links, is that of a
// symbolic link or of another entry that stands for something else and is not
// a directory, such as a Windows junction.
func isLink(mode os.FileMode) bool {
	return mode&os.ModeSymlink != 0 || mode&os.ModeIrregular != 0 && !mode.IsDir()
}

// entryOwner returns the owner of the entry at path itself, without following
// a link, as ownerName gives it; false means the system reports no owners.
var entryOwner = platformEntryOwner

// ownerName names the owner SID sid: "administrators" for the Administrators
// group, "system" for LocalSystem, "user" for the account the agent runs as
// (userSID), and the SID string for any other owner.
func ownerName(sid, userSID string) string {
	switch {
	case sid == "S-1-5-32-544":
		return "administrators"
	case sid == "S-1-5-18":
		return "system"
	case userSID != "" && sid == userSID:
		return "user"
	}
	return sid
}

// fsStat describes what path leads to. "link" is set when the entry at path
// itself is a link, also when what it points to does not exist. "owner" names
// the owner of the entry at path itself where entryOwner reports one.
func (s *Server) fsStat(_ context.Context, req proto.Message) (proto.Message, error) {
	path, err := s.pathArg(req, "path")
	if err != nil {
		return nil, err
	}
	link, owner, hasOwner := false, "", false
	if li, err := os.Lstat(path); err == nil {
		link = isLink(li.Mode())
		owner, hasOwner = entryOwner(path)
	}
	fi, err := os.Stat(path)
	if errors.Is(err, fs.ErrNotExist) || errors.Is(err, syscall.ENOTDIR) {
		out := proto.Message{"exists": false, "path": path}
		if link {
			out["link"] = true
		}
		if hasOwner {
			out["owner"] = owner
		}
		return out, nil
	}
	if err != nil {
		return nil, fmt.Errorf("cannot stat '%s': %v", path, err)
	}
	out := proto.Message{
		"exists": true,
		"dir":    fi.IsDir(),
		"size":   0,
		"mtime":  mtimeString(fi),
		"path":   path,
	}
	if link {
		out["link"] = true
	}
	if hasOwner {
		out["owner"] = owner
	}
	if !fi.IsDir() {
		out["size"] = fi.Size()
		if req.Bool("sha256") {
			sum, err := fileDigest(path)
			if err != nil {
				return nil, fmt.Errorf("cannot hash '%s': %v", path, err)
			}
			out["sha256"] = sum
		}
	}
	return out, nil
}

func (s *Server) fsList(_ context.Context, req proto.Message) (proto.Message, error) {
	root, err := s.pathArg(req, "path")
	if err != nil {
		return nil, err
	}
	fi, err := os.Stat(root)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, fmt.Errorf("'%s' does not exist", root)
	}
	if err != nil {
		return nil, fmt.Errorf("cannot list '%s': %v", root, err)
	}
	if !fi.IsDir() {
		return nil, fmt.Errorf("'%s' is not a directory; use fs.stat or fs.read for files", root)
	}
	if li, err := os.Lstat(root); err == nil && isLink(li.Mode()) {
		return nil, fmt.Errorf("'%s' is a link and fs.list does not follow links; list the folder it leads to", root)
	}
	recursive := req.Bool("recursive")
	withSum := req.Bool("sha256")

	entries := []any{}
	truncated := false
	skipped := 0
	walkErr := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if p == root {
			if err != nil {
				return err
			}
			return nil
		}
		if err != nil {
			skipped++
			if d != nil && d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		if len(entries) >= fsListMax {
			truncated = true
			return fs.SkipAll
		}
		info, err := d.Info()
		if err != nil {
			skipped++
			return nil
		}
		rel, err := filepath.Rel(root, p)
		if err != nil {
			return nil
		}
		e := map[string]any{
			"name":  filepath.ToSlash(rel),
			"dir":   d.IsDir(),
			"size":  int64(0),
			"mtime": mtimeString(info),
		}
		if isLink(info.Mode()) {
			e["link"] = true
		}
		if !d.IsDir() {
			e["size"] = info.Size()
			if withSum && info.Mode().IsRegular() {
				if sum, err := fileDigest(p); err == nil {
					e["sha256"] = sum
				}
			}
		}
		entries = append(entries, e)
		if d.IsDir() && !recursive {
			return fs.SkipDir
		}
		return nil
	})
	if walkErr != nil {
		return nil, fmt.Errorf("cannot list '%s': %v", root, walkErr)
	}
	out := proto.Message{"entries": entries, "truncated": truncated}
	if skipped > 0 {
		out["skipped"] = skipped
	}
	return out, nil
}

func openRegular(path string) (*os.File, os.FileInfo, error) {
	if isIrregular(path) {
		return nil, nil, notRegular(path)
	}
	f, err := os.Open(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil, fmt.Errorf("'%s' does not exist", path)
	}
	if err != nil {
		return nil, nil, fmt.Errorf("cannot open '%s': %v", path, err)
	}
	fi, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, nil, fmt.Errorf("cannot stat '%s': %v", path, err)
	}
	if fi.IsDir() {
		f.Close()
		return nil, nil, fmt.Errorf("'%s' is a directory; use fs.list", path)
	}
	return f, fi, nil
}

// startsWithUTF16BOM reports whether the file begins with the bytes FF FE
// and not with FF FE 00 00, the UTF-32LE byte order mark.
func startsWithUTF16BOM(f *os.File) bool {
	var head [4]byte
	n, _ := f.ReadAt(head[:], 0)
	if n < 2 || head[0] != 0xFF || head[1] != 0xFE {
		return false
	}
	return n < 4 || head[2] != 0 || head[3] != 0
}

// withEncoding adds "encoding": "utf-16le" to out for a file that begins with
// the bytes FF FE.
func withEncoding(out proto.Message, utf16 bool) proto.Message {
	if utf16 {
		out["encoding"] = "utf-16le"
	}
	return out
}

func (s *Server) fsRead(_ context.Context, req proto.Message) (proto.Message, error) {
	path, err := s.pathArg(req, "path")
	if err != nil {
		return nil, err
	}
	f, fi, err := openRegular(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	offset := int64(req.Int("offset"))
	if offset < 0 {
		return nil, errors.New("offset must not be negative")
	}
	length := req.Int("length")
	if length <= 0 || length > fsChunkMax {
		length = fsChunkMax
	}
	buf := make([]byte, length)
	n, err := f.ReadAt(buf, offset)
	if err != nil && err != io.EOF {
		return nil, fmt.Errorf("cannot read '%s': %v", path, err)
	}
	size := fi.Size()
	return withEncoding(proto.Message{
		"data": base64.StdEncoding.EncodeToString(buf[:n]),
		"size": size,
		"eof":  offset+int64(n) >= size,
	}, startsWithUTF16BOM(f)), nil
}

func (s *Server) fsTail(_ context.Context, req proto.Message) (proto.Message, error) {
	path, err := s.pathArg(req, "path")
	if err != nil {
		return nil, err
	}
	f, fi, err := openRegular(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	lines := req.Int("lines")
	if lines <= 0 {
		lines = fsTailDefault
	}
	// A file that begins with FF FE is read as UTF-16LE: its lines start
	// after the byte order mark and end with the code unit 0A 00.
	utf16 := startsWithUTF16BOM(f)
	unit, first := int64(1), int64(0)
	if utf16 {
		unit, first = 2, 2
	}
	size := fi.Size()
	start := size - fsTailWindow
	if start < first {
		start = first
	}
	start += (start - first) % unit
	readFrom := start
	if start > first {
		readFrom = start - unit
	}
	buf := make([]byte, size-readFrom)
	n, err := f.ReadAt(buf, readFrom)
	if err != nil && err != io.EOF {
		return nil, fmt.Errorf("cannot read '%s': %v", path, err)
	}
	buf = buf[:n]
	partialFirst := false
	if start > first && int64(len(buf)) >= unit {
		partialFirst = !isLineFeed(buf, int(unit))
		buf = buf[unit:]
	}
	return withEncoding(proto.Message{
		"data": base64.StdEncoding.EncodeToString(lastLines(buf, lines, partialFirst, int(unit))),
		"size": size,
	}, utf16), nil
}

// isLineFeed reports whether b begins with a line feed of the given code unit
// size: 0A for 1, 0A 00 for 2.
func isLineFeed(b []byte, unit int) bool {
	if len(b) < unit || b[0] != '\n' {
		return false
	}
	return unit == 1 || b[1] == 0
}

// lineFeedIndex returns the offset of the first (last when fromEnd is set)
// line feed in b that starts at a multiple of unit, or -1.
func lineFeedIndex(b []byte, unit int, fromEnd bool) int {
	if unit == 1 {
		if fromEnd {
			return bytes.LastIndexByte(b, '\n')
		}
		return bytes.IndexByte(b, '\n')
	}
	last := len(b) - len(b)%unit - unit
	if fromEnd {
		for i := last; i >= 0; i -= unit {
			if isLineFeed(b[i:], unit) {
				return i
			}
		}
		return -1
	}
	for i := 0; i <= last; i += unit {
		if isLineFeed(b[i:], unit) {
			return i
		}
	}
	return -1
}

// lastLines returns the last n lines of buf, whose code units are unit bytes
// wide. When buf begins in the middle of a line and fewer than n complete
// lines follow, the partial first line is dropped.
func lastLines(buf []byte, n int, partialFirst bool, unit int) []byte {
	body := buf
	if len(buf) >= unit && len(buf)%unit == 0 && isLineFeed(buf[len(buf)-unit:], unit) {
		body = buf[:len(buf)-unit]
	}
	idx := len(body)
	for i := 0; i < n; i++ {
		j := lineFeedIndex(body[:idx], unit, true)
		if j < 0 {
			if partialFirst {
				if k := lineFeedIndex(buf, unit, false); k >= 0 {
					return buf[k+unit:]
				}
				return nil
			}
			return buf
		}
		idx = j
	}
	return buf[idx+unit:]
}

// pastTheEnd is the error of an fs.write whose offset lies past the end of
// the file of size bytes, counted after truncation when truncated is set.
func pastTheEnd(offset int64, path string, size int64, truncated bool) error {
	after, hint := "", "0"
	if truncated {
		after = " after truncate"
	}
	if size > 0 {
		hint = fmt.Sprintf("%d or lower", size)
	}
	return fmt.Errorf("offset %d lies past the end of '%s' (%d bytes%s); write from offset %s", offset, path, size, after, hint)
}

// fsWrite writes at most fsChunkMax bytes at an offset within the file or at
// its end, or appends them.
func (s *Server) fsWrite(_ context.Context, req proto.Message) (proto.Message, error) {
	path, err := s.pathArg(req, "path")
	if err != nil {
		return nil, err
	}
	data, err := base64.StdEncoding.DecodeString(req.String("data"))
	if err != nil {
		return nil, errors.New("data is not valid base64; send the bytes base64-encoded")
	}
	if len(data) > fsChunkMax {
		return nil, fmt.Errorf("data is %d bytes; fs.write takes at most %d bytes, so write the rest with further calls", len(data), fsChunkMax)
	}
	offset := int64(req.Int("offset"))
	if offset < 0 {
		return nil, errors.New("offset must not be negative")
	}
	appendMode, truncate := req.Bool("append"), req.Bool("truncate")
	if appendMode && truncate {
		return nil, errors.New("pass append or truncate, not both")
	}
	if !appendMode {
		var size int64
		if fi, err := os.Stat(path); err == nil && !truncate {
			size = fi.Size()
		}
		if offset > size {
			return nil, pastTheEnd(offset, path, size, truncate)
		}
	}
	dir := filepath.Dir(path)
	if _, err := os.Stat(dir); errors.Is(err, fs.ErrNotExist) {
		if !req.Bool("mkdirs") {
			return nil, fmt.Errorf("directory '%s' does not exist; pass mkdirs to create it", dir)
		}
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, fmt.Errorf("cannot create '%s': %v", dir, err)
		}
	}
	flags := os.O_WRONLY | os.O_CREATE
	switch {
	case appendMode:
		flags |= os.O_APPEND
	case truncate:
		flags |= os.O_TRUNC
	}
	f, err := os.OpenFile(path, flags, 0o644)
	if err != nil {
		return nil, fmt.Errorf("cannot open '%s' for writing: %v", path, err)
	}
	if appendMode {
		_, err = f.Write(data)
	} else {
		_, err = f.WriteAt(data, offset)
	}
	if err != nil {
		f.Close()
		return nil, fmt.Errorf("cannot write '%s': %v", path, err)
	}
	fi, statErr := f.Stat()
	if err := f.Close(); err != nil {
		return nil, fmt.Errorf("cannot write '%s': %v", path, err)
	}
	if statErr != nil {
		return nil, fmt.Errorf("cannot stat '%s': %v", path, statErr)
	}
	return proto.Message{"size": fi.Size()}, nil
}

func (s *Server) fsRename(_ context.Context, req proto.Message) (proto.Message, error) {
	from, err := s.pathArg(req, "from")
	if err != nil {
		return nil, err
	}
	to, err := s.pathArg(req, "to")
	if err != nil {
		return nil, err
	}
	if _, err := os.Lstat(from); err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil, fmt.Errorf("'%s' does not exist", from)
		}
		return nil, fmt.Errorf("cannot stat '%s': %v", from, err)
	}
	if dst, err := os.Lstat(to); err == nil {
		if !req.Bool("overwrite") {
			return nil, fmt.Errorf("'%s' exists; pass overwrite to replace it", to)
		}
		if dst.IsDir() {
			return nil, fmt.Errorf("'%s' is a directory; delete it first with fs.delete", to)
		}
	}
	if err := os.Rename(from, to); err != nil {
		return nil, fmt.Errorf("cannot rename '%s' to '%s': %v", from, to, err)
	}
	return proto.Message{"path": to}, nil
}

func (s *Server) fsMkdir(_ context.Context, req proto.Message) (proto.Message, error) {
	path, err := s.pathArg(req, "path")
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(path, 0o755); err != nil {
		return nil, fmt.Errorf("cannot create '%s': %v", path, err)
	}
	return proto.Message{"path": path}, nil
}

// isFileSystemRoot reports whether the cleaned path is the root of its volume:
// the separator alone, or a volume name followed by the separator.
func isFileSystemRoot(path, volume string, sep byte) bool {
	return strings.HasPrefix(path, volume) && path[len(volume):] == string(sep)
}

// pathContains reports whether target equals dir or lies below it, comparing
// whole components split on sep; fold ignores letter case.
func pathContains(dir, target string, sep byte, fold bool) bool {
	if fold {
		dir, target = strings.ToLower(dir), strings.ToLower(target)
	}
	split := func(p string) []string { return strings.Split(strings.TrimRight(p, string(sep)), string(sep)) }
	d, t := split(dir), split(target)
	if len(d) > len(t) {
		return false
	}
	for i := range d {
		if d[i] != t[i] {
			return false
		}
	}
	return true
}

// protectedFromDelete reports whether path is a file-system root, the home
// directory or one of its ancestors, compared with the home directory as
// given and with its links resolved.
func (s *Server) protectedFromDelete(path string) bool {
	if isFileSystemRoot(path, filepath.VolumeName(path), filepath.Separator) {
		return true
	}
	if s.opt.HomeDir == "" {
		return false
	}
	fold := runtime.GOOS == "windows"
	home := filepath.Clean(s.opt.HomeDir)
	if pathContains(path, home, filepath.Separator, fold) {
		return true
	}
	real, err := filepath.EvalSymlinks(home)
	return err == nil && pathContains(path, real, filepath.Separator, fold)
}

// resolveParent returns path without a \\?\ prefix before a drive letter and
// with the links, junctions and short names of its parent folder resolved
// and its last element kept; it returns path when the parent cannot be
// resolved.
func resolveParent(path string) string {
	p := path
	if strings.HasPrefix(p, `\\?\`) && len(p) >= 6 && p[5] == ':' {
		p = p[4:]
	}
	p = filepath.Clean(p)
	dir, err := filepath.EvalSymlinks(filepath.Dir(p))
	if err != nil {
		return p
	}
	return filepath.Join(dir, filepath.Base(p))
}

func (s *Server) fsDelete(_ context.Context, req proto.Message) (proto.Message, error) {
	path, err := s.pathArg(req, "path")
	if err != nil {
		return nil, err
	}
	if s.protectedFromDelete(path) || s.protectedFromDelete(resolveParent(path)) {
		return nil, fmt.Errorf("refusing to delete '%s': it is the home directory or contains it; delete its contents instead, or use exec.run if this is intended", path)
	}
	fi, err := os.Lstat(path)
	if errors.Is(err, fs.ErrNotExist) {
		return proto.Message{"deleted": false}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("cannot stat '%s': %v", path, err)
	}
	if fi.IsDir() && !req.Bool("recursive") {
		children, err := os.ReadDir(path)
		if err != nil {
			return nil, fmt.Errorf("cannot read '%s': %v", path, err)
		}
		if len(children) > 0 {
			return nil, fmt.Errorf("'%s' is not empty; pass recursive to delete it with its contents", path)
		}
	}
	if err := os.RemoveAll(path); err != nil {
		return nil, fmt.Errorf("cannot delete '%s': %v", path, err)
	}
	return proto.Message{"deleted": true}, nil
}
