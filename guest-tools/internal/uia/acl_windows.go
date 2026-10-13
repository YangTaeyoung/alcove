//go:build windows

package uia

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"unsafe"
)

var (
	advapi32                 = syscall.NewLazyDLL("advapi32.dll")
	kernel32                 = syscall.NewLazyDLL("kernel32.dll")
	procSDDLToDescriptor     = advapi32.NewProc("ConvertStringSecurityDescriptorToSecurityDescriptorW")
	procDescriptorToSDDL     = advapi32.NewProc("ConvertSecurityDescriptorToStringSecurityDescriptorW")
	procGetDescriptorOwner   = advapi32.NewProc("GetSecurityDescriptorOwner")
	procGetDescriptorDacl    = advapi32.NewProc("GetSecurityDescriptorDacl")
	procGetNamedSecurityInfo = advapi32.NewProc("GetNamedSecurityInfoW")
	procSetNamedSecurityInfo = advapi32.NewProc("SetNamedSecurityInfoW")
	procLocalFree            = kernel32.NewProc("LocalFree")
	procGetSystemDirectory   = kernel32.NewProc("GetSystemDirectoryW")
	procGetFileAttributes    = kernel32.NewProc("GetFileAttributesW")
)

const (
	seFileObject            = 1
	ownerSecurityInfo       = 0x00000001
	daclSecurityInfo        = 0x00000004
	protectedDaclInfo       = 0x80000000
	unprotectedDaclInfo     = 0x20000000
	sddlRevision1           = 1
	errorAlreadyExists      = syscall.Errno(183)
	emptyACLRevisionAndLen  = 0x00080002
	invalidFileAttributes   = 0xFFFFFFFF
	fileAttributeReparse    = 0x00000400
	fileAttributeDirectory  = 0x00000010
)

// lockedDescriptor is lockedSDDL as a security descriptor with its owner and
// DACL; free releases it.
type lockedDescriptor struct {
	sd    uintptr
	owner uintptr
	dacl  unsafe.Pointer
}

func newLockedDescriptor() (*lockedDescriptor, error) {
	text, err := syscall.UTF16PtrFromString(lockedSDDL)
	if err != nil {
		return nil, err
	}
	d := &lockedDescriptor{}
	if r, _, e := procSDDLToDescriptor.Call(uintptr(unsafe.Pointer(text)), sddlRevision1, uintptr(unsafe.Pointer(&d.sd)), 0); r == 0 {
		return nil, fmt.Errorf("ConvertStringSecurityDescriptorToSecurityDescriptor: %v", e)
	}
	var defaulted, present int32
	if r, _, e := procGetDescriptorOwner.Call(d.sd, uintptr(unsafe.Pointer(&d.owner)), uintptr(unsafe.Pointer(&defaulted))); r == 0 {
		d.free()
		return nil, fmt.Errorf("GetSecurityDescriptorOwner: %v", e)
	}
	if r, _, e := procGetDescriptorDacl.Call(d.sd, uintptr(unsafe.Pointer(&present)), uintptr(unsafe.Pointer(&d.dacl)), uintptr(unsafe.Pointer(&defaulted))); r == 0 || present == 0 {
		d.free()
		return nil, fmt.Errorf("GetSecurityDescriptorDacl: %v", e)
	}
	return d, nil
}

func (d *lockedDescriptor) free() { procLocalFree.Call(d.sd) }

// ownerAndDACL returns the owner and DACL of a file or directory in SDDL form.
func ownerAndDACL(path string) (string, error) {
	name, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return "", err
	}
	var sd uintptr
	if r, _, _ := procGetNamedSecurityInfo.Call(uintptr(unsafe.Pointer(name)), seFileObject, ownerSecurityInfo|daclSecurityInfo,
		0, 0, 0, 0, uintptr(unsafe.Pointer(&sd))); r != 0 {
		return "", fmt.Errorf("GetNamedSecurityInfo: %v", syscall.Errno(r))
	}
	defer procLocalFree.Call(sd)
	var text *uint16
	if r, _, e := procDescriptorToSDDL.Call(sd, sddlRevision1, ownerSecurityInfo|daclSecurityInfo, uintptr(unsafe.Pointer(&text)), 0); r == 0 {
		return "", fmt.Errorf("ConvertSecurityDescriptorToStringSecurityDescriptor: %v", e)
	}
	defer procLocalFree.Call(uintptr(unsafe.Pointer(text)))
	var units []uint16
	for p := text; *p != 0; p = (*uint16)(unsafe.Add(unsafe.Pointer(p), 2)) {
		units = append(units, *p)
	}
	return syscall.UTF16ToString(units), nil
}

func setSecurity(path string, info uintptr, owner uintptr, dacl unsafe.Pointer) error {
	name, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	if r, _, _ := procSetNamedSecurityInfo.Call(uintptr(unsafe.Pointer(name)), seFileObject, info, owner, 0, uintptr(dacl), 0); r != 0 {
		return fmt.Errorf("SetNamedSecurityInfo(%s): %v", path, syscall.Errno(r))
	}
	return nil
}

// fileAttributes returns the attribute bits of a path, or invalidFileAttributes
// when the path does not exist or cannot be read.
func fileAttributes(path string) uint32 {
	name, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return invalidFileAttributes
	}
	r, _, _ := procGetFileAttributes.Call(uintptr(unsafe.Pointer(name)))
	return uint32(r)
}

// isReparsePoint reports whether the path is a reparse point (a junction or a
// symbolic link), which the lock must not follow.
func isReparsePoint(path string) bool {
	a := fileAttributes(path)
	return a != invalidFileAttributes && a&fileAttributeReparse != 0
}

// LockHelperFolders locks the uia folder and the parent Alcove folder to
// Administrators and SYSTEM so that no one else can read or change them. The
// parent keeps its files (the agent logs); the uia folder keeps only its logs.
// An error means a folder is not known to be locked and the helper must not be
// started from it.
func LockHelperFolders(parent, dir string) error {
	if err := secureDir(parent, nil); err != nil {
		return err
	}
	return secureDir(dir, map[string]bool{"helper.log": true, "helper.log.1": true})
}

// secureDir makes dir a directory that only Administrators and SYSTEM can read
// or change. A new directory is created that way. An existing directory with
// any other owner or access list gets lockedSDDL. A reparse point at dir is
// refused rather than followed. When keep is non-nil the directory is pruned:
// every entry except the kept names is deleted; when keep is nil only reparse
// points are deleted and the other entries take their access from the
// directory. An error means the directory is not known to be locked.
func secureDir(dir string, keep map[string]bool) error {
	d, err := newLockedDescriptor()
	if err != nil {
		return err
	}
	defer d.free()
	if err := os.MkdirAll(filepath.Dir(dir), 0o755); err != nil {
		return err
	}
	if isReparsePoint(dir) {
		return fmt.Errorf("%s is a reparse point; remove it", dir)
	}
	name, err := syscall.UTF16PtrFromString(dir)
	if err != nil {
		return err
	}
	sa := syscall.SecurityAttributes{SecurityDescriptor: d.sd}
	sa.Length = uint32(unsafe.Sizeof(sa))
	err = syscall.CreateDirectory(name, &sa)
	if err != nil && err != errorAlreadyExists {
		return fmt.Errorf("create %s: %v", dir, err)
	}
	a := fileAttributes(dir)
	if a == invalidFileAttributes || a&fileAttributeDirectory == 0 || a&fileAttributeReparse != 0 {
		return fmt.Errorf("%s is not a directory", dir)
	}
	have, err := ownerAndDACL(dir)
	if err != nil {
		return err
	}
	if !isLockedSDDL(have) {
		if err := setSecurity(dir, ownerSecurityInfo|daclSecurityInfo|protectedDaclInfo, d.owner, d.dacl); err != nil {
			return err
		}
		if have, err = ownerAndDACL(dir); err != nil {
			return err
		}
		if !isLockedSDDL(have) {
			return fmt.Errorf("%s still has the access list %s", dir, have)
		}
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	emptyACL := [2]uint32{emptyACLRevisionAndLen, 0}
	for _, e := range entries {
		path := filepath.Join(dir, e.Name())
		if isReparsePoint(path) {
			if err := os.Remove(path); err != nil {
				return err
			}
			continue
		}
		if keep != nil && !keep[strings.ToLower(e.Name())] {
			if err := os.RemoveAll(path); err != nil {
				return err
			}
			continue
		}
		if err := setSecurity(path, ownerSecurityInfo|daclSecurityInfo|unprotectedDaclInfo, d.owner, unsafe.Pointer(&emptyACL)); err != nil {
			return err
		}
		runtime.KeepAlive(&emptyACL)
	}
	return nil
}

// systemDirectory returns the Windows system directory.
func systemDirectory() (string, error) {
	buf := make([]uint16, syscall.MAX_PATH)
	n, _, e := procGetSystemDirectory.Call(uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	if n == 0 || int(n) >= len(buf) {
		return "", fmt.Errorf("GetSystemDirectory: %v", e)
	}
	return syscall.UTF16ToString(buf[:n]), nil
}
