package uia

import (
	"strconv"
	"strings"
	"time"
)

// lockedSDDL gives Administrators and SYSTEM full control of a directory and
// everything created in it, and nobody else any access; it takes no entries
// from the parent directory.
const lockedSDDL = "O:BAD:P(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)"

// deployRootSDDL gives Administrators and SYSTEM full control of a directory
// and everything created in it and Users read and execute access; it takes no
// entries from the parent directory.
const deployRootSDDL = "O:BAD:P(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)(A;OICI;0x1200a9;;;BU)"

const (
	fileAllAccess   = 0x1f01ff
	fileReadExecute = 0x1200a9
)

// isLockedSDDL reports whether an owner-and-DACL descriptor in SDDL form is
// owned by Administrators or SYSTEM, takes no entries from its parent and
// grants full control to exactly Administrators and SYSTEM, for the
// directory and what is created in it.
func isLockedSDDL(sddl string) bool {
	return hasExactlyACEs(sddl, map[string]uint32{"BA": fileAllAccess, "SY": fileAllAccess})
}

// isDeployLockedSDDL reports whether an owner-and-DACL descriptor in SDDL form
// is owned by Administrators or SYSTEM, takes no entries from its parent and
// grants full control to exactly Administrators and SYSTEM and read and
// execute access to Users, for the directory and what is created in it.
func isDeployLockedSDDL(sddl string) bool {
	return hasExactlyACEs(sddl, map[string]uint32{"BA": fileAllAccess, "SY": fileAllAccess, "BU": fileReadExecute})
}

// hasExactlyACEs reports whether an owner-and-DACL descriptor in SDDL form is
// owned by Administrators or SYSTEM, has a protected DACL and holds one
// allow entry for objects and containers per trustee of want, with the access
// mask want gives it, and no other entry.
func hasExactlyACEs(sddl string, want map[string]uint32) bool {
	dacl := strings.Index(sddl, "D:")
	if dacl < 0 || !isTrustedOwner(sddlOwner(sddl)) {
		return false
	}
	rest := sddl[dacl+2:]
	open := strings.Index(rest, "(")
	if open < 0 {
		return false
	}
	flags, aces := rest[:open], rest[open:]
	if !strings.Contains(flags, "P") {
		return false
	}
	if !strings.HasSuffix(aces, ")") {
		return false
	}
	seen := map[string]bool{}
	for _, ace := range strings.Split(strings.TrimSuffix(strings.TrimPrefix(aces, "("), ")"), ")(") {
		f := strings.Split(ace, ";")
		if len(f) != 6 || f[0] != "A" || f[1] != "OICI" || f[3] != "" || f[4] != "" {
			return false
		}
		mask, known := want[f[5]]
		if !known || seen[f[5]] {
			return false
		}
		if got, ok := sddlRights(f[2]); !ok || got != mask {
			return false
		}
		seen[f[5]] = true
	}
	return len(seen) == len(want)
}

// sddlFileRights holds the SDDL abbreviations of file access rights.
var sddlFileRights = map[string]uint32{"FA": fileAllAccess, "FR": 0x120089, "FW": 0x120116, "FX": 0x1200a0}

// sddlRights returns the access mask of the rights field of an SDDL entry:
// a hexadecimal number or a run of the abbreviations in sddlFileRights.
func sddlRights(field string) (uint32, bool) {
	if len(field) > 2 && strings.EqualFold(field[:2], "0x") {
		v, err := strconv.ParseUint(field[2:], 16, 32)
		return uint32(v), err == nil
	}
	if field == "" || len(field)%2 != 0 {
		return 0, false
	}
	var mask uint32
	for i := 0; i < len(field); i += 2 {
		r, ok := sddlFileRights[field[i:i+2]]
		if !ok {
			return 0, false
		}
		mask |= r
	}
	return mask, true
}

// keepDeployRoot reports whether an existing deploy root with the given
// attribute bits and owner-and-DACL descriptor stays as it is: a directory
// that is not a reparse point and is locked as deployRootSDDL says. Any other
// entry is moved aside.
func keepDeployRoot(attributes uint32, sddl string) bool {
	return isPlainDirAttributes(attributes) && isDeployLockedSDDL(sddl)
}

// keepHelperDir reports whether an existing helper folder with the given
// attribute bits and owner-and-DACL descriptor stays as it is: a directory
// that is not a reparse point and is already locked as lockedSDDL says. Any
// other folder is moved aside; its access list is not rewritten in place.
func keepHelperDir(attributes uint32, sddl string) bool {
	return isPlainDirAttributes(attributes) && isLockedSDDL(sddl)
}

// sddlOwner returns the owner of a descriptor in SDDL form: an alias such as
// BA or a SID string, or "" when the text does not begin with an owner.
func sddlOwner(sddl string) string {
	if !strings.HasPrefix(sddl, "O:") {
		return ""
	}
	owner := sddl[2:]
	for _, next := range []string{"G:", "D:", "S:"} {
		if i := strings.Index(owner, next); i >= 0 {
			owner = owner[:i]
		}
	}
	return owner
}

// isTrustedOwner reports whether an SDDL owner is Administrators or SYSTEM.
func isTrustedOwner(owner string) bool {
	return owner == "BA" || owner == "SY"
}

// untrustedName returns the path a folder with another owner is renamed to:
// dir followed by ".untrusted-" and the UTC time as yyyyMMddHHmmss.
func untrustedName(dir string, now time.Time) string {
	return dir + ".untrusted-" + now.UTC().Format("20060102150405")
}

const (
	invalidFileAttributes  = 0xFFFFFFFF
	fileAttributeDirectory = 0x00000010
	fileAttributeReparse   = 0x00000400
)

// isReparseAttributes reports whether file attribute bits belong to a reparse
// point (a junction or a symbolic link). Attributes that could not be read
// count as a reparse point.
func isReparseAttributes(a uint32) bool {
	return a == invalidFileAttributes || a&fileAttributeReparse != 0
}

// isPlainDirAttributes reports whether file attribute bits belong to a
// directory that is not a reparse point.
func isPlainDirAttributes(a uint32) bool {
	return a != invalidFileAttributes && a&fileAttributeDirectory != 0 && a&fileAttributeReparse == 0
}

// What the lock does with one entry of a locked directory.
const (
	entryRemoveLink = iota // delete the reparse point itself
	entryRemove            // delete the entry and what is below it
	entryInherit           // give the entry the directory's owner and access list
	entryLeave             // do nothing with the entry
)

// entryAction returns what the lock does with a directory entry of the given
// name and attribute bits. A reparse point is deleted. An entry whose
// lower-cased name is in leave is left as it is. With a non-nil keep, an entry
// whose lower-cased name is not in keep is deleted. Every other entry takes
// its access from the directory.
func entryAction(name string, attributes uint32, keep, leave map[string]bool) int {
	if isReparseAttributes(attributes) {
		return entryRemoveLink
	}
	if leave[strings.ToLower(name)] {
		return entryLeave
	}
	if keep != nil && !keep[strings.ToLower(name)] {
		return entryRemove
	}
	return entryInherit
}

const (
	// removeAttempts is how often the lock tries to delete an entry.
	removeAttempts = 40
	// removePause is the time between two of those tries.
	removePause = 50 * time.Millisecond
)

// removeRetrying calls remove until it returns nil, returns an error for which
// retry is false, or has failed attempts times, running pause between two
// calls, and returns the last error.
func removeRetrying(remove func() error, attempts int, pause func(), retry func(error) bool) error {
	var err error
	for i := 0; i < attempts; i++ {
		if i > 0 {
			pause()
		}
		if err = remove(); err == nil || !retry(err) {
			return err
		}
	}
	return err
}
