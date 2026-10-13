package uia

import (
	"testing"
	"time"
)

func TestIsLockedSDDL(t *testing.T) {
	cases := []struct {
		sddl string
		want bool
	}{
		{"O:BAD:P(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)", true},
		{"O:BAD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)", true},
		{"O:SYG:SYD:P(A;OICI;0x1f01ff;;;BA)(A;OICI;FA;;;SY)", true},
		{lockedSDDL, true},
		{"O:BAD:(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)", false},
		{"O:BAD:AI(A;OICIID;FA;;;BA)(A;OICIID;FA;;;SY)", false},
		{"O:BAD:P(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)(A;OICI;0x1200a9;;;BU)", false},
		{"O:BAD:P(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)(A;OICIIO;GA;;;CO)", false},
		{"O:BAD:P(A;OICI;FA;;;BA)", false},
		{"O:BAD:P(A;OICI;FA;;;BA)(A;OICI;FA;;;BA)", false},
		{"O:BAD:P(A;;FA;;;BA)(A;OICI;FA;;;SY)", false},
		{"O:BAD:P(A;OICI;0x1200a9;;;BA)(A;OICI;FA;;;SY)", false},
		{"O:BAD:P(D;OICI;FA;;;BA)(A;OICI;FA;;;SY)", false},
		{"O:S-1-5-21-1-2-3-1001D:P(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)", false},
		{"O:BAD:P", false},
		{"D:P(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)", false},
		{"", false},
	}
	for _, c := range cases {
		if got := isLockedSDDL(c.sddl); got != c.want {
			t.Errorf("isLockedSDDL(%q) = %v, expected %v", c.sddl, got, c.want)
		}
	}
}

func TestAttributesOfAReparsePointOrAFailedReadCountAsAReparsePoint(t *testing.T) {
	cases := []struct {
		attributes uint32
		want       bool
	}{
		{fileAttributeReparse, true},
		{fileAttributeReparse | fileAttributeDirectory, true},
		{invalidFileAttributes, true},
		{fileAttributeDirectory, false},
		{0x20, false},
		{0, false},
	}
	for _, c := range cases {
		if got := isReparseAttributes(c.attributes); got != c.want {
			t.Errorf("isReparseAttributes(%#x) = %v, expected %v", c.attributes, got, c.want)
		}
	}
}

func TestOnlyADirectoryThatIsNoReparsePointIsAPlainDirectory(t *testing.T) {
	cases := []struct {
		attributes uint32
		want       bool
	}{
		{fileAttributeDirectory, true},
		{fileAttributeDirectory | 0x02 | 0x04, true},
		{fileAttributeDirectory | fileAttributeReparse, false},
		{fileAttributeReparse, false},
		{0x20, false},
		{0, false},
		{invalidFileAttributes, false},
	}
	for _, c := range cases {
		if got := isPlainDirAttributes(c.attributes); got != c.want {
			t.Errorf("isPlainDirAttributes(%#x) = %v, expected %v", c.attributes, got, c.want)
		}
	}
}

func TestEntryAction(t *testing.T) {
	logs := map[string]bool{"helper.log": true, "helper.log.1": true}
	uia := map[string]bool{"uia": true}
	const file, dir = 0x20, fileAttributeDirectory
	cases := []struct {
		what       string
		name       string
		attributes uint32
		keep       map[string]bool
		leave      map[string]bool
		want       int
	}{
		{"a kept log", "helper.log", file, logs, nil, entryInherit},
		{"a kept log in another case", "Helper.LOG.1", file, logs, nil, entryInherit},
		{"a script in a pruned folder", "bootstrap.ps1", file, logs, nil, entryRemove},
		{"a folder in a pruned folder", "tmp", dir, logs, nil, entryRemove},
		{"a name that starts like a kept one", "helper.log.2", file, logs, nil, entryRemove},
		{"a link with a kept name", "helper.log", file | fileAttributeReparse, logs, nil, entryRemoveLink},
		{"a junction in a pruned folder", "tmp", dir | fileAttributeReparse, logs, nil, entryRemoveLink},
		{"a file in a folder that keeps its entries", "agent.log", file, nil, nil, entryInherit},
		{"a folder in a folder that keeps its entries", "uia", dir, nil, nil, entryInherit},
		{"a junction in a folder that keeps its entries", "uia", dir | fileAttributeReparse, nil, nil, entryRemoveLink},
		{"an entry whose attributes were not read", "agent.log", invalidFileAttributes, nil, nil, entryRemoveLink},
		{"with an empty keep set every plain entry", "helper.log", file, map[string]bool{}, nil, entryRemove},
		{"a folder that is left", "uia", dir, nil, uia, entryLeave},
		{"a folder that is left, in another case", "UIA", dir, nil, uia, entryLeave},
		{"a junction with a name that is left", "uia", dir | fileAttributeReparse, nil, uia, entryRemoveLink},
		{"a file beside a folder that is left", "agent.log", file, nil, uia, entryInherit},
		{"a folder moved aside beside a folder that is left", "uia.untrusted-20261014010203", dir, nil, uia, entryInherit},
		{"a left name in a pruned folder", "uia", dir, logs, uia, entryLeave},
	}
	for _, c := range cases {
		if got := entryAction(c.name, c.attributes, c.keep, c.leave); got != c.want {
			t.Errorf("%s: entryAction(%q, %#x) = %d, expected %d", c.what, c.name, c.attributes, got, c.want)
		}
	}
}

func TestSDDLOwner(t *testing.T) {
	cases := []struct{ sddl, want string }{
		{"O:BAD:P(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)", "BA"},
		{"O:SYG:SYD:PAI(A;OICI;FA;;;SY)", "SY"},
		{"O:S-1-5-21-1-2-3-1001D:AI(A;OICIID;FA;;;BA)", "S-1-5-21-1-2-3-1001"},
		{"O:S-1-5-21-1-2-3-1001G:S-1-5-21-1-2-3-513D:(A;;FA;;;BA)", "S-1-5-21-1-2-3-1001"},
		{"O:BUS:(AU;SA;FA;;;WD)", "BU"},
		{"O:LA", "LA"},
		{"D:P(A;OICI;FA;;;BA)", ""},
		{"", ""},
	}
	for _, c := range cases {
		if got := sddlOwner(c.sddl); got != c.want {
			t.Errorf("sddlOwner(%q) = %q, expected %q", c.sddl, got, c.want)
		}
	}
}

func TestOnlyAdministratorsAndSystemAreTrustedOwners(t *testing.T) {
	for owner, want := range map[string]bool{
		"BA": true, "SY": true,
		"BU": false, "LA": false, "AU": false, "WD": false, "": false,
		"S-1-5-21-1-2-3-1001": false, "S-1-5-32-544": false, "ba": false,
	} {
		if got := isTrustedOwner(owner); got != want {
			t.Errorf("isTrustedOwner(%q) = %v, expected %v", owner, got, want)
		}
	}
}

func TestUntrustedNameAppendsTheUTCTime(t *testing.T) {
	zone := time.FixedZone("east", 9*3600)
	now := time.Date(2026, 10, 14, 8, 5, 9, 0, zone)
	got := untrustedName(`C:\ProgramData\Alcove`, now)
	if want := `C:\ProgramData\Alcove.untrusted-20261013230509`; got != want {
		t.Fatalf("untrustedName = %q, expected %q", got, want)
	}
}
