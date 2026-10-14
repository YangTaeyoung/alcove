package token

import (
	"encoding/hex"
	"strings"
	"testing"
)

func TestParseType11(t *testing.T) {
	// type 0 (len 4, one string "BIOS"), type 11 (len 5, count 2: "foo", "alcove-token=abc"), type 127
	table := []byte{0, 4, 1, 0, 'B', 'I', 'O', 'S', 0, 0,
		11, 5, 2, 0, 2, 'f', 'o', 'o', 0, 'a', 'l', 'c', 'o', 'v', 'e', '-', 't', 'o', 'k', 'e', 'n', '=', 'a', 'b', 'c', 0, 0,
		127, 4, 3, 0, 0, 0}
	strs := ParseType11(table)
	if len(strs) != 2 || strs[1] != "alcove-token=abc" {
		t.Fatalf("got %v", strs)
	}
	if got := FromOEMStrings(strs); got != "abc" {
		t.Fatalf("token %q", got)
	}
	if FromOEMStrings(nil) != "" {
		t.Fatal("empty")
	}
}

// oemTable is an SMBIOS table with one type 11 structure that holds strs, as
// QEMU builds it from several -smbios type=11 values, and the end structure.
func oemTable(strs ...string) []byte {
	table := []byte{11, 5, 0, 0, byte(len(strs))}
	for _, s := range strs {
		table = append(table, s...)
		table = append(table, 0)
	}
	table = append(table, 0)
	return append(table, 127, 4, 1, 0, 0, 0)
}

func TestTheTokenAndTheHostKeyAreReadFromOneOEMStructure(t *testing.T) {
	key := strings.Repeat("ab", 32)
	strs := ParseType11(oemTable("alcove-token=6f1c", "alcove-hostkey="+key))
	if got := FromOEMStrings(strs); got != "6f1c" {
		t.Fatalf("token %q from %v", got, strs)
	}
	got := HostKeyFromOEMStrings(strs)
	if hex.EncodeToString(got) != key {
		t.Fatalf("host key %x from %v", got, strs)
	}
}

func TestAHostKeyThatIsNot64HexadecimalDigitsIsNone(t *testing.T) {
	for _, value := range []string{"", strings.Repeat("ab", 31), strings.Repeat("ab", 33), strings.Repeat("zz", 32), strings.Repeat("ab", 32) + "x"} {
		if got := HostKeyFromOEMStrings([]string{"alcove-token=t", "alcove-hostkey=" + value}); got != nil {
			t.Errorf("alcove-hostkey=%q gave %x", value, got)
		}
	}
	if got := HostKeyFromOEMStrings([]string{"alcove-token=t"}); got != nil {
		t.Errorf("no alcove-hostkey gave %x", got)
	}
}

func TestAStructureWithoutStringsBeforeTheOEMStructureIsSkipped(t *testing.T) {
	table := []byte{32, 11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
	table = append(table, oemTable("alcove-token=6f1c")...)
	strs := ParseType11(table)
	if got := FromOEMStrings(strs); got != "6f1c" {
		t.Fatalf("token %q from %v", got, strs)
	}
}
