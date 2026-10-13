//go:build windows

package uia

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

var (
	advapi32                 = syscall.NewLazyDLL("advapi32.dll")
	kernel32                 = syscall.NewLazyDLL("kernel32.dll")
	procSDDLToDescriptor     = advapi32.NewProc("ConvertStringSecurityDescriptorToSecurityDescriptorW")
	procDescriptorToSDDL     = advapi32.NewProc("ConvertSecurityDescriptorToStringSecurityDescriptorW")
	procGetDescriptorOwner   = advapi32.NewProc("GetSecurityDescriptorOwner")
	procGetDescriptorDacl    = advapi32.NewProc("GetSecurityDescriptorDacl")
	procGetSecurityInfo      = advapi32.NewProc("GetSecurityInfo")
	procSetSecurityInfo      = advapi32.NewProc("SetSecurityInfo")
	procSetNamedSecurityInfo = advapi32.NewProc("SetNamedSecurityInfoW")
	procLocalFree            = kernel32.NewProc("LocalFree")
	procGetSystemDirectory   = kernel32.NewProc("GetSystemDirectoryW")
	procGetFileAttributes    = kernel32.NewProc("GetFileAttributesW")
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
	readControl            = 0x00020000
	writeDAC               = 0x00040000
	writeOwner             = 0x00080000
	fileReadAttributes     = 0x00000080
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

// handleOwnerAndDACL returns the owner and DACL of an open file or directory
// in SDDL form.
func handleOwnerAndDACL(h syscall.Handle) (string, error) {
	var sd uintptr
	if r, _, _ := procGetSecurityInfo.Call(uintptr(h), seFileObject, ownerSecurityInfo|daclSecurityInfo,
		0, 0, 0, 0, uintptr(unsafe.Pointer(&sd))); r != 0 {
		return "", fmt.Errorf("GetSecurityInfo: %v", syscall.Errno(r))
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

func setHandleSecurity(h syscall.Handle, info uintptr, owner uintptr, dacl unsafe.Pointer) error {
	if r, _, _ := procSetSecurityInfo.Call(uintptr(h), seFileObject, info, owner, 0, uintptr(dacl), 0); r != 0 {
		return fmt.Errorf("SetSecurityInfo: %v", syscall.Errno(r))
	}
	return nil
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

// LockHelperFolders locks the uia folder and the parent Alcove folder to
// Administrators and SYSTEM. The parent keeps its files (the agent logs) and
// leaves the uia entry to the lock of the uia folder; the uia folder keeps
// only its logs. An error means a folder is not known to be locked.
func LockHelperFolders(parent, dir string) error {
	if err := secureDir(parent, nil, map[string]bool{strings.ToLower(filepath.Base(dir)): true}); err != nil {
		return err
	}
	return secureDir(dir, map[string]bool{"helper.log": true, "helper.log.1": true}, nil)
}

// openDir opens what is at path itself, without following a reparse point,
// with the rights to read and replace its owner and access list. While the
// handle is open the entry cannot be renamed or deleted.
func openDir(path string) (syscall.Handle, error) {
	name, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return syscall.InvalidHandle, err
	}
	return syscall.CreateFile(name, readControl|writeDAC|writeOwner|fileReadAttributes,
		syscall.FILE_SHARE_READ|syscall.FILE_SHARE_WRITE, nil, syscall.OPEN_EXISTING,
		syscall.FILE_FLAG_OPEN_REPARSE_POINT|syscall.FILE_FLAG_BACKUP_SEMANTICS, 0)
}

// openPlainDir opens dir with openDir, checks on the handle that it is a
// directory and not a reparse point, and returns the handle with the owner
// and access list read through it in SDDL form.
func openPlainDir(dir string) (syscall.Handle, string, error) {
	h, err := openDir(dir)
	if err != nil {
		return syscall.InvalidHandle, "", fmt.Errorf("open %s: %v", dir, err)
	}
	var info syscall.ByHandleFileInformation
	if err := syscall.GetFileInformationByHandle(h, &info); err != nil {
		syscall.CloseHandle(h)
		return syscall.InvalidHandle, "", fmt.Errorf("read the attributes of %s: %v", dir, err)
	}
	if isReparseAttributes(info.FileAttributes) {
		syscall.CloseHandle(h)
		return syscall.InvalidHandle, "", fmt.Errorf("%s is a reparse point; remove it", dir)
	}
	if !isPlainDirAttributes(info.FileAttributes) {
		syscall.CloseHandle(h)
		return syscall.InvalidHandle, "", fmt.Errorf("%s is not a directory; remove it and restart alcove-agent", dir)
	}
	have, err := handleOwnerAndDACL(h)
	if err != nil {
		syscall.CloseHandle(h)
		return syscall.InvalidHandle, "", err
	}
	return h, have, nil
}

// ownerAccount returns the owner of an open file or directory as
// DOMAIN\name, or fallback when the account cannot be looked up.
func ownerAccount(h syscall.Handle, fallback string) string {
	var sid *syscall.SID
	var sd uintptr
	if r, _, _ := procGetSecurityInfo.Call(uintptr(h), seFileObject, ownerSecurityInfo,
		uintptr(unsafe.Pointer(&sid)), 0, 0, 0, uintptr(unsafe.Pointer(&sd))); r != 0 || sid == nil {
		return fallback
	}
	defer procLocalFree.Call(sd)
	account, domain, _, err := sid.LookupAccount("")
	if err != nil || account == "" {
		return fallback
	}
	if domain == "" {
		return account
	}
	return domain + `\` + account
}

// secureDir makes dir a directory that only Administrators and SYSTEM can read
// or change. A new directory is created that way. An existing one is opened
// without following a reparse point and checked on that handle to be a
// directory and not a reparse point. When its owner, read through the handle,
// is neither Administrators nor SYSTEM, it is renamed to untrustedName and a
// new directory is created in its place. Any other owner or access list is
// replaced by lockedSDDL on the handle. The entries are handled as entryAction
// says; deleting one is tried removeAttempts times, removePause apart. An error
// means the directory is not known to be locked.
func secureDir(dir string, keep, leave map[string]bool) error {
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
	existed := err == errorAlreadyExists
	if err != nil && !existed {
		return fmt.Errorf("create %s: %v", dir, err)
	}
	h, have, err := openPlainDir(dir)
	if err != nil {
		return err
	}
	defer func() { syscall.CloseHandle(h) }()
	if existed && !isTrustedOwner(sddlOwner(have)) {
		owner := ownerAccount(h, sddlOwner(have))
		syscall.CloseHandle(h)
		h = syscall.InvalidHandle
		moved := os.Rename(dir, untrustedName(dir, time.Now()))
		if le, ok := moved.(*os.LinkError); ok {
			moved = le.Err
		}
		if moved == nil {
			moved = syscall.CreateDirectory(name, &sa)
		}
		if moved != nil {
			return fmt.Errorf("%s belongs to %s and could not be moved aside (%v); remove it as an administrator and restart alcove-agent", dir, owner, moved)
		}
		if h, have, err = openPlainDir(dir); err != nil {
			return err
		}
	}
	if !isLockedSDDL(have) {
		if err := setHandleSecurity(h, ownerSecurityInfo|daclSecurityInfo|protectedDaclInfo, d.owner, d.dacl); err != nil {
			return fmt.Errorf("%s: %v", dir, err)
		}
		if have, err = handleOwnerAndDACL(h); err != nil {
			return err
		}
		if !isLockedSDDL(have) {
			return fmt.Errorf("%s still has the access list %s; fix it with icacls and restart alcove-agent", dir, have)
		}
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	emptyACL := [2]uint32{emptyACLRevisionAndLen, 0}
	for _, e := range entries {
		path := filepath.Join(dir, e.Name())
		switch entryAction(e.Name(), fileAttributes(path), keep, leave) {
		case entryRemoveLink:
			if err = os.Remove(path); os.IsNotExist(err) {
				err = nil
			}
		case entryRemove:
			err = removeRetrying(func() error { return os.RemoveAll(path) }, removeAttempts, func() { time.Sleep(removePause) })
		case entryLeave:
			err = nil
		default:
			err = setSecurity(path, ownerSecurityInfo|daclSecurityInfo|unprotectedDaclInfo, d.owner, unsafe.Pointer(&emptyACL))
			runtime.KeepAlive(&emptyACL)
		}
		if err != nil {
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
