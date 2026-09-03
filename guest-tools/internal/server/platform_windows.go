//go:build windows

package server

import (
	"errors"
	"os/exec"
	"syscall"
	"unsafe"
)

var (
	user32                    = syscall.NewLazyDLL("user32.dll")
	procGetSystemMetrics      = user32.NewProc("GetSystemMetrics")
	procChangeDisplaySettings = user32.NewProc("ChangeDisplaySettingsW")
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

func setResolution(w, h int) error {
	if w <= 0 || h <= 0 {
		return errors.New("bad size")
	}
	var dm devMode
	dm.Size = uint16(unsafe.Sizeof(dm))
	dm.Fields = dmPelsWidth | dmPelsHeight
	dm.PelsWidth = uint32(w)
	dm.PelsHeight = uint32(h)
	r, _, _ := procChangeDisplaySettings.Call(uintptr(unsafe.Pointer(&dm)), 0)
	if r != 0 { // DISP_CHANGE_SUCCESSFUL == 0
		return errors.New("ChangeDisplaySettings failed")
	}
	return nil
}
