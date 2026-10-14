//go:build windows

package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"syscall"
	"unsafe"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/server"
)

// keyFileSDDL gives Administrators and SYSTEM full control of the key file
// and nobody else any access; it takes no entries from the folder.
const keyFileSDDL = "O:BAD:P(A;;FA;;;BA)(A;;FA;;;SY)"

var (
	procSDDLToDescriptor = syscall.NewLazyDLL("advapi32.dll").NewProc("ConvertStringSecurityDescriptorToSecurityDescriptorW")
	procLocalFree        = syscall.NewLazyDLL("kernel32.dll").NewProc("LocalFree")
)

// newHostKeyStore returns the store of host.key in the Alcove data folder
// alcoveDir. Without the folder (dataErr) or when it is not locked (lockErr)
// every Load and Save answers why.
func newHostKeyStore(alcoveDir string, dataErr, lockErr error) server.KeyStore {
	switch {
	case dataErr != nil:
		return fileKeyStore{unusable: errors.New("%ProgramData% is not set; start alcove-agent through its scheduled task")}
	case lockErr != nil:
		return fileKeyStore{unusable: fmt.Errorf("the data folder %s is not locked (%v); fix its owner and access list as an administrator and restart alcove-agent", alcoveDir, lockErr)}
	}
	return fileKeyStore{path: filepath.Join(alcoveDir, "host.key")}
}

// forgetHostKeyPath returns the key file --forget-host-key removes.
func forgetHostKeyPath() (string, error) {
	alcoveDir, _, err := dataFolders(os.Getenv("ProgramData"))
	if err != nil {
		return "", errors.New("%ProgramData% is not set, so the host key cannot be located; run alcove-agent --forget-host-key from an elevated prompt where it is set")
	}
	return filepath.Join(alcoveDir, "host.key"), nil
}

// readKeyFile returns the content of the key file at path, or nil when it
// does not exist. A reparse point is not read.
func readKeyFile(path string) ([]byte, error) {
	if refuseReparse(path) != nil {
		return nil, fmt.Errorf("%s is a reparse point; run alcove-agent --forget-host-key as an administrator and connect again", path)
	}
	f, err := os.Open(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("%s could not be read or written (%v); run alcove-agent as an administrator (root on Linux)", path, unwrapPathError(err))
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if !fi.Mode().IsRegular() {
		return nil, fmt.Errorf("%s does not hold 64 hexadecimal digits; run alcove-agent --forget-host-key as an administrator and connect again", path)
	}
	return readLimited(f)
}

// writeKeyFile creates path with CREATE_NEW, without following a reparse
// point, owned by Administrators with keyFileSDDL as its access list, and
// writes data to it. A file that could not be written completely is removed.
func writeKeyFile(path string, data []byte) error {
	text, err := syscall.UTF16PtrFromString(keyFileSDDL)
	if err != nil {
		return err
	}
	var sd uintptr
	if r, _, e := procSDDLToDescriptor.Call(uintptr(unsafe.Pointer(text)), 1, uintptr(unsafe.Pointer(&sd)), 0); r == 0 {
		return fmt.Errorf("ConvertStringSecurityDescriptorToSecurityDescriptor: %v", e)
	}
	defer procLocalFree.Call(sd)
	sa := syscall.SecurityAttributes{SecurityDescriptor: sd}
	sa.Length = uint32(unsafe.Sizeof(sa))
	name, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	h, err := syscall.CreateFile(name, syscall.GENERIC_WRITE, 0, &sa, syscall.CREATE_NEW,
		syscall.FILE_ATTRIBUTE_NORMAL|syscall.FILE_FLAG_OPEN_REPARSE_POINT, 0)
	if err != nil {
		return err
	}
	f := os.NewFile(uintptr(h), path)
	_, err = f.Write(data)
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
