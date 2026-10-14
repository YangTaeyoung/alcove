//go:build linux

package token

import "os"

// OEMStrings returns the SMBIOS type 11 strings of the DMI table, or nil.
func OEMStrings() []string {
	table, err := os.ReadFile("/sys/firmware/dmi/tables/DMI")
	if err != nil {
		return nil
	}
	return ParseType11(table)
}
