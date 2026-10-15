//go:build windows

package uia

import (
	"errors"
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
	procSetNamedSecurityInfo = advapi32.NewProc("SetNamedSecurityInfoW")
	procLocalFree            = kernel32.NewProc("LocalFree")
	procGetSystemDirectory   = kernel32.NewProc("GetSystemDirectoryW")
	procGetWindowsDirectory  = kernel32.NewProc("GetSystemWindowsDirectoryW")
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

// lockedDescriptor is a security descriptor in SDDL form converted, with its
// owner and DACL; free releases it.
type lockedDescriptor struct {
	sd    uintptr
	owner uintptr
	dacl  unsafe.Pointer
}

func newLockedDescriptor(sddl string) (*lockedDescriptor, error) {
	text, err := syscall.UTF16PtrFromString(sddl)
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
// only its logs. moved names the paths a folder of another owner was renamed
// to. An error means a folder is not known to be locked.
func LockHelperFolders(parent, dir string) (moved []string, err error) {
	aside, err := secureDir(parent, nil, map[string]bool{strings.ToLower(filepath.Base(dir)): true})
	if aside != "" {
		moved = append(moved, aside)
	}
	if err != nil {
		return moved, err
	}
	aside, err = secureDir(dir, map[string]bool{"helper.log": true, "helper.log.1": true}, nil)
	if aside != "" {
		moved = append(moved, aside)
	}
	return moved, err
}

// LockDeployRoot makes dir a directory that Administrators and SYSTEM control
// and Users can only read and run, as deployRootSDDL says, and returns the
// path an existing entry at dir was renamed to, or "" when none was. A new
// directory is created that way. An existing entry is kept when keepDeployRoot
// says so, read through a handle opened without following a reparse point;
// any other entry, also one that cannot be opened, is renamed to
// untrustedName and a new directory is created in its place. An error means
// the directory is not known to be locked.
func LockDeployRoot(dir string) (moved string, err error) {
	d, err := newLockedDescriptor(deployRootSDDL)
	if err != nil {
		return "", err
	}
	defer d.free()
	name, err := syscall.UTF16PtrFromString(dir)
	if err != nil {
		return "", err
	}
	sa := syscall.SecurityAttributes{SecurityDescriptor: d.sd}
	sa.Length = uint32(unsafe.Sizeof(sa))
	err = syscall.CreateDirectory(name, &sa)
	if err != nil && err != errorAlreadyExists {
		return "", fmt.Errorf("create %s: %v", dir, err)
	}
	if err == errorAlreadyExists {
		if keepExistingDeployRoot(dir) {
			return "", nil
		}
		removeOldAsides(dir)
		moved = untrustedName(dir, time.Now())
		if err := os.Rename(dir, moved); err != nil {
			if le, ok := err.(*os.LinkError); ok {
				err = le.Err
			}
			return "", fmt.Errorf("%s is a link, belongs to another owner or lets other users change it, and could not be moved aside (%v); close the programs that use files in it, remove it as an administrator and restart alcove-agent", dir, err)
		}
		if err := syscall.CreateDirectory(name, &sa); err != nil {
			return moved, fmt.Errorf("create %s: %v", dir, err)
		}
	}
	h, have, err := openPlainDir(dir)
	if err != nil {
		return moved, err
	}
	defer syscall.CloseHandle(h)
	if !isDeployLockedSDDL(have) {
		return moved, fmt.Errorf("%s has the access list %s; remove it as an administrator and restart alcove-agent", dir, have)
	}
	return moved, nil
}

// DeployRootLocked reports whether dir is a directory, not a reparse point,
// locked as deployRootSDDL says, read as keepExistingDeployRoot reads it.
func DeployRootLocked(dir string) bool {
	return keepExistingDeployRoot(dir)
}

// keepExistingDeployRoot reports what keepDeployRoot says of the entry at dir,
// read through a handle opened without following a reparse point; an entry
// that cannot be opened or read is not kept.
func keepExistingDeployRoot(dir string) bool {
	h, err := openDir(dir)
	if err != nil {
		return false
	}
	defer syscall.CloseHandle(h)
	var info syscall.ByHandleFileInformation
	if err := syscall.GetFileInformationByHandle(h, &info); err != nil {
		return false
	}
	have, err := handleOwnerAndDACL(h)
	if err != nil {
		return false
	}
	return keepDeployRoot(info.FileAttributes, have)
}

// isRetriedRemoveError reports whether a deletion failed because the entry or
// something below it is in use or about to be deleted: access denied, a
// sharing violation or a directory that is not empty yet.
func isRetriedRemoveError(err error) bool {
	return errors.Is(err, syscall.ERROR_ACCESS_DENIED) || errors.Is(err, syscall.Errno(32)) || errors.Is(err, syscall.Errno(145))
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

// moveAside renames dir to untrustedName beside it and creates a new directory
// at dir with the given security attributes, after removeOldAsides has removed
// any earlier aside folder. It returns the path dir was renamed to, or "" when
// the rename failed, and the first error of the rename or the create.
func moveAside(dir string, name *uint16, sa *syscall.SecurityAttributes) (string, error) {
	removeOldAsides(dir)
	aside := untrustedName(dir, time.Now())
	failed := os.Rename(dir, aside)
	if le, ok := failed.(*os.LinkError); ok {
		failed = le.Err
	}
	if failed != nil {
		return "", failed
	}
	if err := syscall.CreateDirectory(name, sa); err != nil {
		return aside, err
	}
	return aside, nil
}

// removeOldAsides deletes the <dir>.untrusted-* folders left by earlier moves,
// so at most the one this start makes is kept. A reparse point among them is
// unlinked, never followed. Failures are left for an administrator.
func removeOldAsides(dir string) {
	matches, err := filepath.Glob(dir + ".untrusted-*")
	if err != nil {
		return
	}
	for _, m := range matches {
		if isReparseAttributes(fileAttributes(m)) {
			_ = os.Remove(m)
			continue
		}
		_ = removeRetrying(func() error { return os.RemoveAll(m) }, removeAttempts,
			func() { time.Sleep(removePause) }, isRetriedRemoveError)
	}
}

// secureDir makes dir a directory that only Administrators and SYSTEM can read
// or change and returns the path an existing directory was renamed to, or ""
// when none was. A new directory is created that way. An existing directory is
// opened without following a reparse point and checked on that handle to be a
// directory and not a reparse point. It is kept in place only when it is
// already locked as lockedSDDL says, read through that handle; its access list
// is not rewritten in place. A directory that is anything else is moved aside
// with moveAside and a new, locked one is created in its place. The entries of a kept directory are handled as
// entryAction says; deleting one is tried up to removeAttempts times,
// removePause apart, while isRetriedRemoveError holds for its error. An error
// means the directory is not known to be locked.
func secureDir(dir string, keep, leave map[string]bool) (moved string, err error) {
	d, err := newLockedDescriptor(lockedSDDL)
	if err != nil {
		return "", err
	}
	defer d.free()
	if err := os.MkdirAll(filepath.Dir(dir), 0o755); err != nil {
		return "", err
	}
	name, err := syscall.UTF16PtrFromString(dir)
	if err != nil {
		return "", err
	}
	sa := syscall.SecurityAttributes{SecurityDescriptor: d.sd}
	sa.Length = uint32(unsafe.Sizeof(sa))
	err = syscall.CreateDirectory(name, &sa)
	existed := err == errorAlreadyExists
	if err != nil && !existed {
		return "", fmt.Errorf("create %s: %v", dir, err)
	}
	h, have, err := openPlainDir(dir)
	if err != nil {
		return "", err
	}
	if existed && !keepHelperDir(fileAttributes(dir), have) {
		syscall.CloseHandle(h)
		aside, failed := moveAside(dir, name, &sa)
		moved = aside
		if failed != nil {
			return moved, fmt.Errorf("%s is a link, belongs to another owner or lets other users change it, and could not be moved aside (%v); close the programs that use files in it, remove it as an administrator and restart alcove-agent", dir, failed)
		}
		if h, have, err = openPlainDir(dir); err != nil {
			return moved, err
		}
	}
	syscall.CloseHandle(h)
	if !isLockedSDDL(have) {
		return moved, fmt.Errorf("%s still has the access list %s; fix it with icacls and restart alcove-agent", dir, have)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return moved, err
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
			err = removeRetrying(func() error { return os.RemoveAll(path) }, removeAttempts,
				func() { time.Sleep(removePause) }, isRetriedRemoveError)
		case entryLeave:
			err = nil
		default:
			err = setSecurity(path, ownerSecurityInfo|daclSecurityInfo|unprotectedDaclInfo, d.owner, unsafe.Pointer(&emptyACL))
			runtime.KeepAlive(&emptyACL)
		}
		if err != nil {
			return moved, err
		}
	}
	return moved, nil
}

// systemDirectory returns the Windows system directory.
func systemDirectory() (string, error) {
	return folderOf(procGetSystemDirectory)
}

// windowsDirectory returns the system's Windows directory, the same for every
// user and session.
func windowsDirectory() (string, error) {
	return folderOf(procGetWindowsDirectory)
}

// folderOf calls a kernel32 function that writes a folder name into a buffer
// and returns its length.
func folderOf(proc *syscall.LazyProc) (string, error) {
	buf := make([]uint16, syscall.MAX_PATH)
	n, _, e := proc.Call(uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	if n == 0 || int(n) >= len(buf) {
		return "", fmt.Errorf("%s: %v", proc.Name, e)
	}
	return syscall.UTF16ToString(buf[:n]), nil
}
