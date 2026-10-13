package uia

import "strings"

// lockedSDDL gives Administrators and SYSTEM full control of a directory and
// everything created in it, and nobody else any access; it takes no entries
// from the parent directory.
const lockedSDDL = "O:BAD:P(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)"

// isLockedSDDL reports whether an owner-and-DACL descriptor in SDDL form is
// owned by Administrators or SYSTEM, takes no entries from its parent and
// grants full control to exactly Administrators and SYSTEM, for the
// directory and what is created in it.
func isLockedSDDL(sddl string) bool {
	dacl := strings.Index(sddl, "D:")
	if !strings.HasPrefix(sddl, "O:") || dacl < 0 {
		return false
	}
	owner := sddl[2:dacl]
	if g := strings.Index(owner, "G:"); g >= 0 {
		owner = owner[:g]
	}
	if owner != "BA" && owner != "SY" {
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
	want := map[string]bool{"BA": false, "SY": false}
	for _, ace := range strings.Split(strings.TrimSuffix(strings.TrimPrefix(aces, "("), ")"), ")(") {
		f := strings.Split(ace, ";")
		if len(f) != 6 || f[0] != "A" || f[1] != "OICI" || (f[2] != "FA" && !strings.EqualFold(f[2], "0x1f01ff")) || f[3] != "" || f[4] != "" {
			return false
		}
		seen, known := want[f[5]]
		if !known || seen {
			return false
		}
		want[f[5]] = true
	}
	return want["BA"] && want["SY"]
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
)

// entryAction returns what the lock does with a directory entry of the given
// name and attribute bits. A reparse point is deleted. With a non-nil keep,
// an entry whose lower-cased name is not in keep is deleted. Every other entry
// takes its access from the directory.
func entryAction(name string, attributes uint32, keep map[string]bool) int {
	if isReparseAttributes(attributes) {
		return entryRemoveLink
	}
	if keep != nil && !keep[strings.ToLower(name)] {
		return entryRemove
	}
	return entryInherit
}
