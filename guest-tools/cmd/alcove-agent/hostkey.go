package main

import (
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"strings"
)

// keyFileMax bounds what Load reads of a key file.
const keyFileMax = 256

// fileKeyStore keeps the host key in a file that holds the key as 64
// hexadecimal digits and a newline.
type fileKeyStore struct {
	path string
	// unusable, when set, is the error of every Load and Save.
	unusable error
	// prepare, when set, readies the folder of path before a Save.
	prepare func() error
}

// Load returns the stored key, or nil when the file does not exist. A file
// that readKeyFile refuses or that does not hold a key is an error.
func (s fileKeyStore) Load() ([]byte, error) {
	if s.unusable != nil {
		return nil, s.unusable
	}
	data, err := readKeyFile(s.path)
	if err != nil || data == nil {
		return nil, err
	}
	key, err := hex.DecodeString(strings.TrimSpace(string(data)))
	if err != nil || len(key) != 32 {
		return nil, fmt.Errorf("%s does not hold 64 hexadecimal digits; run alcove-agent --forget-host-key as an administrator and connect again", s.path)
	}
	return key, nil
}

// Save writes key to a file created new at path; it fails when an entry
// exists there.
func (s fileKeyStore) Save(key []byte) error {
	if s.unusable != nil {
		return s.unusable
	}
	if s.prepare != nil {
		if err := s.prepare(); err != nil {
			return err
		}
	}
	if err := writeKeyFile(s.path, []byte(hex.EncodeToString(key)+"\n")); err != nil {
		return fmt.Errorf("%s could not be read or written (%v); run alcove-agent as an administrator (root on Linux)", s.path, err)
	}
	return nil
}

// readLimited reads at most keyFileMax bytes of f.
func readLimited(f *os.File) ([]byte, error) {
	return io.ReadAll(io.LimitReader(f, keyFileMax))
}

// forgetHostKey removes the key file at path and writes what it did to out,
// or the failure to errOut; it returns the exit code.
func forgetHostKey(path string, out, errOut io.Writer) int {
	err := os.Remove(path)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		fmt.Fprintln(out, "no host key was stored")
	case err != nil:
		fmt.Fprintf(errOut, "cannot remove %s (%v); run alcove-agent --forget-host-key as an administrator (root on Linux)\n", path, unwrapPathError(err))
		return 1
	default:
		fmt.Fprintln(out, "the host key was removed; the next host that connects pairs with this agent")
	}
	return 0
}

// unwrapPathError returns the error inside a *fs.PathError, or err.
func unwrapPathError(err error) error {
	var pe *fs.PathError
	if errors.As(err, &pe) {
		return pe.Err
	}
	return err
}
