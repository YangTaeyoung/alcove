// Package token finds the per-VM token and the host's public key that the
// engine passes as SMBIOS type 11 (OEM strings) entries:
// "alcove-token=<uuid>" and "alcove-hostkey=<64 hexadecimal digits>".
package token

import (
	"encoding/hex"
	"strings"
)

const (
	prefix        = "alcove-token="
	hostKeyPrefix = "alcove-hostkey="
)

// HostKeySize is the length in bytes of the host's Ed25519 public key.
const HostKeySize = 32

// FromOEMStrings picks the token out of a list of OEM strings.
func FromOEMStrings(strs []string) string {
	for _, s := range strs {
		if strings.HasPrefix(s, prefix) {
			return strings.TrimSpace(strings.TrimPrefix(s, prefix))
		}
	}
	return ""
}

// HostKeyFromOEMStrings returns the HostKeySize bytes the first
// "alcove-hostkey=" string encodes as 64 hexadecimal digits, or nil when
// there is no such string or it holds anything else.
func HostKeyFromOEMStrings(strs []string) []byte {
	for _, s := range strs {
		if !strings.HasPrefix(s, hostKeyPrefix) {
			continue
		}
		text := strings.TrimPrefix(s, hostKeyPrefix)
		if len(text) != 2*HostKeySize {
			return nil
		}
		key, err := hex.DecodeString(text)
		if err != nil {
			return nil
		}
		return key
	}
	return nil
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
