package token

import "testing"

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
