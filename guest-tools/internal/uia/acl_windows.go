//go:build windows

package uia

import (
	"fmt"
	"os"
	"path/filepath"
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
)

const (
	seFileObject           = 1
	ownerSecurityInfo      = 0x00000001
	daclSecurityInfo       = 0x00000004
	protectedDaclInfo      = 0x80000000
	unprotectedDaclInfo    = 0x20000000
	sddlRevision1          = 1
	errorAlreadyExists     = syscall.Errno(183)
	emptyACLRevisionAndLen = 0x00080002
)

// lockedDescriptor is lockedSDDL as a security descriptor with its owner and
// DACL; free releases it.
type lockedDescriptor struct {
	sd    uintptr
	owner uintptr
	dacl  uintptr
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

func setSecurity(path string, info uintptr, owner, dacl uintptr) error {
	name, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	if r, _, _ := procSetNamedSecurityInfo.Call(uintptr(unsafe.Pointer(name)), seFileObject, info, owner, 0, dacl, 0); r != 0 {
		return fmt.Errorf("SetNamedSecurityInfo(%s): %v", path, syscall.Errno(r))
	}
	return nil
}

// secureDir makes dir a directory that only Administrators and SYSTEM can
// read or change. A new directory is created that way. An existing directory
// with any other owner or access list gets lockedSDDL; its helper scripts and
// compiled helpers are then deleted and its other files take their access
// from the directory. An error means the directory is not known to be locked.
func secureDir(dir string) error {
	d, err := newLockedDescriptor()
	if err != nil {
		return err
	}
	defer d.free()
	if err := os.MkdirAll(filepath.Dir(dir), 0o755); err != nil {
		return err
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
	if st, serr := os.Lstat(dir); serr != nil || !st.IsDir() || st.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("%s is not a directory", dir)
	}
	have, err := ownerAndDACL(dir)
	if err != nil {
		return err
	}
	if isLockedSDDL(have) {
		return nil
	}
	if err := setSecurity(dir, ownerSecurityInfo|daclSecurityInfo|protectedDaclInfo, d.owner, d.dacl); err != nil {
		return err
	}
	if have, err = ownerAndDACL(dir); err != nil {
		return err
	}
	if !isLockedSDDL(have) {
		return fmt.Errorf("%s still has the access list %s", dir, have)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	emptyACL := [2]uint32{emptyACLRevisionAndLen, 0}
	for _, e := range entries {
		path := filepath.Join(dir, e.Name())
		lower := strings.ToLower(e.Name())
		if lower == "bootstrap.ps1" || lower == "helper.cs" || (strings.HasPrefix(lower, "helper-") && strings.HasSuffix(lower, ".dll")) {
			if err := os.RemoveAll(path); err != nil {
				return err
			}
			continue
		}
		if err := setSecurity(path, ownerSecurityInfo|daclSecurityInfo|unprotectedDaclInfo, d.owner, uintptr(unsafe.Pointer(&emptyACL))); err != nil {
			return err
		}
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
