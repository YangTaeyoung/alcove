//go:build !windows

package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"syscall"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/server"
)

// hostKeyPath is the file that holds the host key outside Windows.
const hostKeyPath = "/etc/alcove/host.key"

// newHostKeyStore returns the store of hostKeyPath, whose folder ownKeyFolder
// readies before a key is saved; the arguments are used on Windows only.
func newHostKeyStore(string, error, error) server.KeyStore {
	return fileKeyStore{path: hostKeyPath, prepare: func() error { return ownKeyFolder(filepath.Dir(hostKeyPath)) }}
}

// forgetHostKeyPath returns the key file --forget-host-key removes.
func forgetHostKeyPath() (string, error) { return hostKeyPath, nil }

// ownKeyFolder creates dir with mode 0700, or narrows an existing dir to that
// mode. A dir that is a symbolic link, not a directory or owned by another
// user than the effective one is refused.
func ownKeyFolder(dir string) error {
	if err := os.Mkdir(dir, 0o700); err != nil && !errors.Is(err, fs.ErrExist) {
		return fmt.Errorf("%s could not be created (%v); run alcove-agent as root", dir, unwrapPathError(err))
	}
	fi, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !fi.IsDir() || !ok || int(st.Uid) != os.Geteuid() {
		return fmt.Errorf("%s is not a folder of this user; remove it and connect again", dir)
	}
	return os.Chmod(dir, 0o700)
}

// readKeyFile returns the content of the key file at path, or nil when it
// does not exist. The file is opened without following a link and read only
// when it is a regular file of the effective user that no other user can
// read or write.
func readKeyFile(path string) ([]byte, error) {
	notOwn := fmt.Errorf("%s is not a regular file of this user that only it can read; run alcove-agent --forget-host-key as an administrator and connect again", path)
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if errors.Is(err, syscall.ELOOP) {
		return nil, notOwn
	}
	if err != nil {
		return nil, fmt.Errorf("%s could not be read or written (%v); run alcove-agent as an administrator (root on Linux)", path, unwrapPathError(err))
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return nil, err
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !fi.Mode().IsRegular() || !ok || int(st.Uid) != os.Geteuid() || fi.Mode().Perm()&0o077 != 0 {
		return nil, notOwn
	}
	return readLimited(f)
}

// writeKeyFile creates path with mode 0600, without following a link and
// failing when an entry exists, and writes data to it. A file that could not
// be written completely is removed.
func writeKeyFile(path string, data []byte) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return unwrapPathError(err)
	}
	err = f.Chmod(0o600)
	if err == nil {
		_, err = f.Write(data)
	}
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		os.Remove(path)
	}
	return err
}
