package server

import (
	"bytes"
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

func (s *Server) pathArg(req proto.Message, key string) (string, error) {
	return s.resolvePath(req.String(key))
}

func mtimeString(fi os.FileInfo) string {
	return fi.ModTime().UTC().Format(time.RFC3339)
}

func fileDigest(path string) (string, error) {
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

func (s *Server) fsStat(req proto.Message) (proto.Message, error) {
	path, err := s.pathArg(req, "path")
	if err != nil {
		return nil, err
	}
	fi, err := os.Stat(path)
	if errors.Is(err, fs.ErrNotExist) {
		return proto.Message{"exists": false, "path": path}, nil
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

func (s *Server) fsList(req proto.Message) (proto.Message, error) {
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
	recursive := req.Bool("recursive")
	withSum := req.Bool("sha256")

	entries := []any{}
	truncated := false
	walkErr := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if p == root {
			if err != nil {
				return err
			}
			return nil
		}
		if err != nil {
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
	return proto.Message{"entries": entries, "truncated": truncated}, nil
}

func openRegular(path string) (*os.File, os.FileInfo, error) {
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

// startsWithUTF16BOM reports whether the file begins with the bytes FF FE.
func startsWithUTF16BOM(f *os.File) bool {
	var head [2]byte
	n, _ := f.ReadAt(head[:], 0)
	return n == 2 && head[0] == 0xFF && head[1] == 0xFE
}

// withEncoding adds "encoding": "utf-16le" to out for a file that begins with
// the bytes FF FE.
func withEncoding(out proto.Message, utf16 bool) proto.Message {
	if utf16 {
		out["encoding"] = "utf-16le"
	}
	return out
}

func (s *Server) fsRead(req proto.Message) (proto.Message, error) {
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

func (s *Server) fsTail(req proto.Message) (proto.Message, error) {
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

func (s *Server) fsWrite(req proto.Message) (proto.Message, error) {
	path, err := s.pathArg(req, "path")
	if err != nil {
		return nil, err
	}
	data, err := base64.StdEncoding.DecodeString(req.String("data"))
	if err != nil {
		return nil, errors.New("data is not valid base64; send the bytes base64-encoded")
	}
	offset := int64(req.Int("offset"))
	if offset < 0 {
		return nil, errors.New("offset must not be negative")
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
	appendMode := req.Bool("append")
	switch {
	case appendMode:
		flags |= os.O_APPEND
	case req.Bool("truncate"):
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

func (s *Server) fsRename(req proto.Message) (proto.Message, error) {
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

func (s *Server) fsMkdir(req proto.Message) (proto.Message, error) {
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

func (s *Server) fsDelete(req proto.Message) (proto.Message, error) {
	path, err := s.pathArg(req, "path")
	if err != nil {
		return nil, err
	}
	home := filepath.Clean(s.opt.HomeDir)
	if s.opt.HomeDir != "" && pathContains(path, home, filepath.Separator, runtime.GOOS == "windows") ||
		isFileSystemRoot(path, filepath.VolumeName(path), filepath.Separator) {
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
