// Package token finds the per-VM authentication token that the engine passes
// as an SMBIOS type 11 (OEM strings) entry: "alcove-token=<uuid>".
package token

import (
	"strings"
)

const prefix = "alcove-token="

// FromOEMStrings picks the token out of a list of OEM strings.
func FromOEMStrings(strs []string) string {
	for _, s := range strs {
		if strings.HasPrefix(s, prefix) {
			return strings.TrimSpace(strings.TrimPrefix(s, prefix))
		}
	}
	return ""
}

// ParseType11 extracts the strings of an SMBIOS type 11 structure from a raw
// SMBIOS table (the whole table, as returned by GetSystemFirmwareTable or
// /sys/firmware/dmi/tables/DMI).
func ParseType11(table []byte) []string {
	var out []string
	i := 0
	for i+4 <= len(table) {
		typ := table[i]
		length := int(table[i+1])
		if length < 4 || i+length > len(table) {
			break
		}
		// the string set follows the formatted area, terminated by "\0\0"
		j := i + length
		var strs []string
		for j < len(table) {
			end := j
			for end < len(table) && table[end] != 0 {
				end++
			}
			if end == j { // empty string == end of set
				j = end + 1
				break
			}
			strs = append(strs, string(table[j:end]))
			j = end + 1
		}
		if typ == 11 {
			out = append(out, strs...)
		}
		if typ == 127 {
			break
		}
		i = j
	}
	return out
}
