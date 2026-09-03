//go:build windows

package server

import (
	"errors"
	"fmt"
	"os/exec"
	"syscall"
	"unsafe"
)

var (
	user32                    = syscall.NewLazyDLL("user32.dll")
	procGetSystemMetrics      = user32.NewProc("GetSystemMetrics")
	procChangeDisplaySettings = user32.NewProc("ChangeDisplaySettingsW")
	procEnumDisplaySettings   = user32.NewProc("EnumDisplaySettingsW")
)

func platformShutdown() error {
	return exec.Command("shutdown.exe", "/s", "/t", "0").Run()
}

func currentResolution() (int, int, bool) {
	w, _, _ := procGetSystemMetrics.Call(0) // SM_CXSCREEN
	h, _, _ := procGetSystemMetrics.Call(1) // SM_CYSCREEN
	return int(w), int(h), w > 0 && h > 0
}

// devMode mirrors DEVMODEW (only the fields we set).
type devMode struct {
	DeviceName    [32]uint16
	SpecVersion   uint16
	DriverVersion uint16
	Size          uint16
	DriverExtra   uint16
	Fields        uint32
	Position      [2]int32
	Orientation   uint32
	FixedOutput   uint32
	Color         int16
	Duplex        int16
	YResolution   int16
	TTOption      int16
	Collate       int16
	FormName      [32]uint16
	LogPixels     uint16
	BitsPerPel    uint32
	PelsWidth     uint32
	PelsHeight    uint32
	DisplayFlags  uint32
	Frequency     uint32
	ICMMethod     uint32
	ICMIntent     uint32
	MediaType     uint32
	DitherType    uint32
	Reserved1     uint32
	Reserved2     uint32
	PanningWidth  uint32
	PanningHeight uint32
}

const (
	dmPelsWidth  = 0x00080000
	dmPelsHeight = 0x00100000
)

// enumModes lists the display modes the driver offers for the primary adapter.
func enumModes() [][2]int {
	var modes [][2]int
	var dm devMode
	dm.Size = uint16(unsafe.Sizeof(dm))
	for i := 0; ; i++ {
		r, _, _ := procEnumDisplaySettings.Call(0, uintptr(uint32(i)), uintptr(unsafe.Pointer(&dm)))
		if r == 0 {
			break
		}
		if dm.BitsPerPel >= 24 {
			modes = append(modes, [2]int{int(dm.PelsWidth), int(dm.PelsHeight)})
		}
	}
	return modes
}

func setResolution(w, h int) error {
	if w <= 0 || h <= 0 {
		return errors.New("bad size")
	}
	modes := enumModes()
	if len(modes) > 0 {
		mw, mh, ok := nearestMode(w, h, modes)
		if !ok {
			return fmt.Errorf("no display mode offered for %dx%d", w, h)
		}
		w, h = mw, mh
	}
	var dm devMode
	dm.Size = uint16(unsafe.Sizeof(dm))
	dm.Fields = dmPelsWidth | dmPelsHeight
	dm.PelsWidth = uint32(w)
	dm.PelsHeight = uint32(h)
	r, _, _ := procChangeDisplaySettings.Call(uintptr(unsafe.Pointer(&dm)), 0)
	if r != 0 { // DISP_CHANGE_SUCCESSFUL == 0
		return fmt.Errorf("ChangeDisplaySettings(%dx%d) returned %s", w, h, dispChangeName(int32(r)))
	}
	return nil
}

// dispChangeName names the DISP_CHANGE_* results of ChangeDisplaySettings.
func dispChangeName(code int32) string {
	switch code {
	case 1:
		return "DISP_CHANGE_RESTART"
	case -1:
		return "DISP_CHANGE_FAILED"
	case -2:
		return "DISP_CHANGE_BADMODE (the driver does not offer this mode)"
	case -3:
		return "DISP_CHANGE_NOTUPDATED"
	case -4:
		return "DISP_CHANGE_BADFLAGS"
	case -5:
		return "DISP_CHANGE_BADPARAM"
	case -6:
		return "DISP_CHANGE_BADDUALVIEW"
	default:
		return fmt.Sprintf("code %d", code)
	}
}
