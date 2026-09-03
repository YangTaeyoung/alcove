//go:build linux

package token

import "os"

// Read returns the token from the DMI table, or "".
func Read() string {
	table, err := os.ReadFile("/sys/firmware/dmi/tables/DMI")
	if err != nil {
		return ""
	}
	return FromOEMStrings(ParseType11(table))
}
