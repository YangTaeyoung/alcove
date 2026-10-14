//go:build windows

package clipboard

import (
	"errors"
	"syscall"
	"time"
	"unicode/utf16"
	"unsafe"
)

var (
	user32                        = syscall.NewLazyDLL("user32.dll")
	kernel32                      = syscall.NewLazyDLL("kernel32.dll")
	procOpenClipboard             = user32.NewProc("OpenClipboard")
	procCloseClipboard            = user32.NewProc("CloseClipboard")
	procEmptyClipboard            = user32.NewProc("EmptyClipboard")
	procGetClipboardData          = user32.NewProc("GetClipboardData")
	procSetClipboardData          = user32.NewProc("SetClipboardData")
	procIsClipboardFormatAvail    = user32.NewProc("IsClipboardFormatAvailable")
	procGetClipboardSequenceNumbr = user32.NewProc("GetClipboardSequenceNumber")
	procGlobalAlloc               = kernel32.NewProc("GlobalAlloc")
	procGlobalFree                = kernel32.NewProc("GlobalFree")
	procGlobalLock                = kernel32.NewProc("GlobalLock")
	procGlobalUnlock              = kernel32.NewProc("GlobalUnlock")
	procGlobalSize                = kernel32.NewProc("GlobalSize")
)

const (
	cfUnicodeText = 13
	gmemMoveable  = 0x0002
)

// pointerAt returns the address a GlobalLock call returns as a pointer; the
// memory belongs to the Windows global heap, not to the Go collector.
func pointerAt(address uintptr) unsafe.Pointer {
	return *(*unsafe.Pointer)(unsafe.Pointer(&address))
}

type windowsClipboard struct{}

// New returns the Windows clipboard of the calling session.
func New() Clipboard { return windowsClipboard{} }

func (windowsClipboard) Available() bool { return true }

func (windowsClipboard) Sequence() uint64 {
	n, _, _ := procGetClipboardSequenceNumbr.Call()
	return uint64(n)
}

// open retries briefly: another process may hold the clipboard.
func open() error {
	for i := 0; i < 10; i++ {
		r, _, _ := procOpenClipboard.Call(0)
		if r != 0 {
			return nil
		}
		time.Sleep(20 * time.Millisecond)
	}
	return errors.New("OpenClipboard failed")
}

// Text reads the text through serial, so the thread that opens the clipboard
// closes it.
func (windowsClipboard) Text() (string, error) { return serial(text) }

func text() (string, error) {
	if r, _, _ := procIsClipboardFormatAvail.Call(cfUnicodeText); r == 0 {
		return "", nil
	}
	if err := open(); err != nil {
		return "", err
	}
	defer procCloseClipboard.Call()
	h, _, _ := procGetClipboardData.Call(cfUnicodeText)
	if h == 0 {
		return "", nil
	}
	p, _, _ := procGlobalLock.Call(h)
	if p == 0 {
		return "", errors.New("GlobalLock failed")
	}
	defer procGlobalUnlock.Call(h)
	size, _, _ := procGlobalSize.Call(h)
	n := int(size / 2)
	u := unsafe.Slice((*uint16)(pointerAt(p)), n)
	end := 0
	for end < n && u[end] != 0 {
		end++
	}
	return string(utf16.Decode(u[:end])), nil
}

// SetText writes the text through serial, so the thread that opens the
// clipboard closes it.
func (windowsClipboard) SetText(s string) error {
	_, err := serial(func() (struct{}, error) { return struct{}{}, setText(s) })
	return err
}

func setText(s string) error {
	u := utf16.Encode([]rune(s))
	u = append(u, 0)
	size := uintptr(len(u) * 2)
	h, _, _ := procGlobalAlloc.Call(gmemMoveable, size)
	if h == 0 {
		return errors.New("GlobalAlloc failed")
	}
	p, _, _ := procGlobalLock.Call(h)
	if p == 0 {
		procGlobalFree.Call(h)
		return errors.New("GlobalLock failed")
	}
	copy(unsafe.Slice((*uint16)(pointerAt(p)), len(u)), u)
	procGlobalUnlock.Call(h)
	if err := open(); err != nil {
		procGlobalFree.Call(h)
		return err
	}
	defer procCloseClipboard.Call()
	procEmptyClipboard.Call()
	if r, _, _ := procSetClipboardData.Call(cfUnicodeText, h); r == 0 {
		procGlobalFree.Call(h)
		return errors.New("SetClipboardData failed")
	}
	return nil // the system owns h now
}
