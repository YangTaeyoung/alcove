//go:build windows

// alcove-fixture is a small Win32 application for UI tests of a Windows guest.
//
//	alcove-fixture [--log FILE] [--url URL]
//
// Its window, titled "Alcove Fixture", holds:
//
//   - an edit control labelled "Message" and a "Send" button: Send appends
//     "You: <message>" to the transcript, then "Bot: " and thirty words that
//     repeat "echo <message>", one word every 80 ms, then "[done]"; the button
//     is disabled while the words arrive, and Enter presses it;
//   - a password edit control labelled "Secret";
//   - a read-only multi-line edit control labelled "Transcript";
//   - the static text "한글 라벨";
//   - "Dialog": a message box titled "Fixture Dialog" with the text "Dialog body";
//   - "Crash": the process ends through RaiseFailFastException, which
//     Windows Error Reporting records;
//   - "Hang": the window thread sleeps for 60 s;
//   - "Fetch": an HTTPS GET of --url on another goroutine that reads the whole
//     body and appends "Fetch: <status code or error>" to the transcript;
//   - "Titles": changes the window title every 50 ms for 5 s and ends with
//     "Alcove Fixture";
//   - two buttons that are both named "Same": each appends "Same 1" or
//     "Same 2" to the transcript.
//
// With --log every action appends one line "<RFC 3339 time> <action> [detail]"
// to the file; a change of Secret is logged as "secret <length>", without the
// text. The process is per-monitor DPI aware.
package main

import (
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

const (
	windowTitle = "Alcove Fixture"
	className   = "AlcoveFixtureWindow"

	replyWords    = 30
	wordInterval  = 80 // ms
	hangDuration  = 60 * time.Second
	titlesFor     = 5 * time.Second
	fetchTimeout  = 30 * time.Second
	baseDPI       = 96
	windowWidth   = 720
	windowHeight  = 520
	minimumWidth  = 520
	minimumHeight = 400
)

// control identifiers; idSend equals IDOK, the command Enter sends.
const (
	idSend    = 1
	idMessage = 100 + iota
	idSecret
	idTranscript
	idLabel
	idDialog
	idCrash
	idHang
	idFetch
	idTitles
	idSame1
	idSame2
)

const (
	wsOverlappedWindow = 0x00CF0000
	wsVisible          = 0x10000000
	wsChild            = 0x40000000
	wsTabStop          = 0x00010000
	wsVScroll          = 0x00200000
	wsBorder           = 0x00800000
	wsExClientEdge     = 0x00000200
	esMultiline        = 0x0004
	esPassword         = 0x0020
	esAutoVScroll      = 0x0040
	esAutoHScroll      = 0x0080
	esReadOnly         = 0x0800
	bsDefPushButton    = 0x0001

	wmDestroy       = 0x0002
	wmSize          = 0x0005
	wmSetFont       = 0x0030
	wmGetMinMaxInfo = 0x0024
	wmCommand       = 0x0111
	wmTimer         = 0x0113
	wmDPIChanged    = 0x02E0
	wmApp           = 0x8000
	wmFetchDone     = wmApp + 1

	enChange       = 0x0300
	emSetSel       = 0x00B1
	emReplaceSel   = 0x00C2
	emSetLimitText = 0x00C5
	emScrollCaret  = 0x00B7

	cwUseDefault   = 0x80000000
	swShowNormal   = 1
	colorBtnFace   = 15
	idcArrow       = 32512
	mbOK           = 0
	swpNoZOrder    = 0x0004
	swpNoActivate  = 0x0010
	fwNormal       = 400
	defaultCharset = 1
	clearType      = 5
	streamTimer    = 1
	titlesTimer    = 2
	titlesInterval = 50 // ms
)

var (
	user32   = syscall.NewLazyDLL("user32.dll")
	gdi32    = syscall.NewLazyDLL("gdi32.dll")
	kernel32 = syscall.NewLazyDLL("kernel32.dll")

	procRegisterClassEx    = user32.NewProc("RegisterClassExW")
	procCreateWindowEx     = user32.NewProc("CreateWindowExW")
	procDefWindowProc      = user32.NewProc("DefWindowProcW")
	procShowWindow         = user32.NewProc("ShowWindow")
	procUpdateWindow       = user32.NewProc("UpdateWindow")
	procGetMessage         = user32.NewProc("GetMessageW")
	procTranslateMessage   = user32.NewProc("TranslateMessage")
	procDispatchMessage    = user32.NewProc("DispatchMessageW")
	procIsDialogMessage    = user32.NewProc("IsDialogMessageW")
	procPostQuitMessage    = user32.NewProc("PostQuitMessage")
	procPostMessage        = user32.NewProc("PostMessageW")
	procSendMessage        = user32.NewProc("SendMessageW")
	procMessageBox         = user32.NewProc("MessageBoxW")
	procGetWindowText      = user32.NewProc("GetWindowTextW")
	procGetWindowTextLen   = user32.NewProc("GetWindowTextLengthW")
	procSetWindowText      = user32.NewProc("SetWindowTextW")
	procGetClientRect      = user32.NewProc("GetClientRect")
	procMoveWindow         = user32.NewProc("MoveWindow")
	procSetWindowPos       = user32.NewProc("SetWindowPos")
	procEnableWindow       = user32.NewProc("EnableWindow")
	procSetFocus           = user32.NewProc("SetFocus")
	procSetTimer           = user32.NewProc("SetTimer")
	procKillTimer          = user32.NewProc("KillTimer")
	procLoadCursor         = user32.NewProc("LoadCursorW")
	procSetProcessDPIAware = user32.NewProc("SetProcessDPIAware")
	procSetDPIContext      = user32.NewProc("SetProcessDpiAwarenessContext")
	procGetDpiForSystem    = user32.NewProc("GetDpiForSystem")
	procGetDpiForWindow    = user32.NewProc("GetDpiForWindow")
	procCreateFont         = gdi32.NewProc("CreateFontW")
	procDeleteObject       = gdi32.NewProc("DeleteObject")
	procGetModuleHandle    = kernel32.NewProc("GetModuleHandleW")
	procRaiseFailFast      = kernel32.NewProc("RaiseFailFastException")
	procGetErrorMode       = kernel32.NewProc("GetErrorMode")
	procSetErrorMode       = kernel32.NewProc("SetErrorMode")
)

type wndClassEx struct {
	size       uint32
	style      uint32
	wndProc    uintptr
	clsExtra   int32
	wndExtra   int32
	instance   uintptr
	icon       uintptr
	cursor     uintptr
	background uintptr
	menuName   *uint16
	className  *uint16
	iconSm     uintptr
}

type point struct{ x, y int32 }

type rect struct{ left, top, right, bottom int32 }

type msg struct {
	hwnd    uintptr
	message uint32
	wParam  uintptr
	lParam  uintptr
	time    uint32
	pt      point
	private uint32
}

type minMaxInfo struct {
	reserved, maxSize, maxPosition, minTrackSize, maxTrackSize point
}

type app struct {
	url     string
	logFile *os.File

	main, message, secret, transcript, send uintptr
	labels                                  [4]uintptr
	buttons                                 [5]uintptr
	same                                    [2]uintptr
	dpi                                     int
	font                                    uintptr

	words       []string
	wordsSent   int
	titlesTick  int
	titlesSince time.Time

	mu      sync.Mutex
	fetched []string
}

var fixture app

func utf16(s string) *uint16 {
	p, err := syscall.UTF16PtrFromString(s)
	if err != nil {
		p, _ = syscall.UTF16PtrFromString("")
	}
	return p
}

func (a *app) log(action string, detail ...string) {
	if a.logFile == nil {
		return
	}
	line := time.Now().Format(time.RFC3339) + " " + action
	if len(detail) > 0 {
		line += " " + strings.Join(detail, " ")
	}
	a.logFile.WriteString(line + "\n")
}

func (a *app) scale(n int) int32 { return int32(n * a.dpi / baseDPI) }

func sendMessage(hwnd uintptr, message uint32, wParam, lParam uintptr) uintptr {
	r, _, _ := procSendMessage.Call(hwnd, uintptr(message), wParam, lParam)
	return r
}

func windowText(hwnd uintptr) string {
	n, _, _ := procGetWindowTextLen.Call(hwnd)
	buf := make([]uint16, n+1)
	procGetWindowText.Call(hwnd, uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	return syscall.UTF16ToString(buf)
}

// appendTranscript adds text at the end of the transcript and scrolls to it.
func (a *app) appendTranscript(text string) {
	end, _, _ := procGetWindowTextLen.Call(a.transcript)
	sendMessage(a.transcript, emSetSel, end, end)
	added := utf16(text)
	sendMessage(a.transcript, emReplaceSel, 0, uintptr(unsafe.Pointer(added)))
	runtime.KeepAlive(added)
	sendMessage(a.transcript, emScrollCaret, 0, 0)
}

func (a *app) child(class, text string, style uint32, exStyle uint32, id int) uintptr {
	instance, _, _ := procGetModuleHandle.Call(0)
	hwnd, _, _ := procCreateWindowEx.Call(uintptr(exStyle), uintptr(unsafe.Pointer(utf16(class))), uintptr(unsafe.Pointer(utf16(text))),
		uintptr(style|wsChild|wsVisible), 0, 0, 0, 0, a.main, uintptr(id), instance, 0)
	return hwnd
}

// createControls creates the children in tab order; each edit control follows
// the static text that labels it.
func (a *app) createControls() {
	a.labels[0] = a.child("STATIC", "Message", 0, 0, -1)
	a.message = a.child("EDIT", "", wsTabStop|esAutoHScroll, wsExClientEdge, idMessage)
	a.send = a.child("BUTTON", "Send", wsTabStop|bsDefPushButton, 0, idSend)
	a.labels[1] = a.child("STATIC", "Secret", 0, 0, -1)
	a.secret = a.child("EDIT", "", wsTabStop|esAutoHScroll|esPassword, wsExClientEdge, idSecret)
	a.labels[2] = a.child("STATIC", "Transcript", 0, 0, -1)
	a.transcript = a.child("EDIT", "", wsTabStop|wsVScroll|esMultiline|esAutoVScroll|esReadOnly, wsExClientEdge, idTranscript)
	a.labels[3] = a.child("STATIC", "한글 라벨", 0, 0, idLabel)
	for i, b := range []struct {
		text string
		id   int
	}{{"Dialog", idDialog}, {"Crash", idCrash}, {"Hang", idHang}, {"Fetch", idFetch}, {"Titles", idTitles}} {
		a.buttons[i] = a.child("BUTTON", b.text, wsTabStop, 0, b.id)
	}
	a.same[0] = a.child("BUTTON", "Same", wsTabStop, 0, idSame1)
	a.same[1] = a.child("BUTTON", "Same", wsTabStop, 0, idSame2)
	sendMessage(a.transcript, emSetLimitText, 0, 0)
}

func (a *app) children() []uintptr {
	all := []uintptr{a.message, a.send, a.secret, a.transcript}
	all = append(all, a.labels[:]...)
	all = append(all, a.buttons[:]...)
	return append(all, a.same[:]...)
}

// applyFont gives every control a font with Hangul glyphs at the window's DPI.
func (a *app) applyFont() {
	old := a.font
	height := -int32(10 * a.dpi / 72)
	a.font, _, _ = procCreateFont.Call(uintptr(height), 0, 0, 0, fwNormal, 0, 0, 0, defaultCharset, 0, 0, clearType, 0,
		uintptr(unsafe.Pointer(utf16("Malgun Gothic"))))
	for _, c := range a.children() {
		sendMessage(c, wmSetFont, a.font, 1)
	}
	if old != 0 {
		procDeleteObject.Call(old)
	}
}

func move(hwnd uintptr, x, y, w, h int32) {
	procMoveWindow.Call(hwnd, uintptr(x), uintptr(y), uintptr(w), uintptr(h), 1)
}

// layout places the controls in the client area: the two input rows on top,
// the buttons at the bottom, above them the Korean label with the two Same
// buttons to its right, the transcript between.
func (a *app) layout() {
	var client rect
	procGetClientRect.Call(a.main, uintptr(unsafe.Pointer(&client)))
	width, height := client.right, client.bottom
	margin, labelW, rowH, gap := a.scale(16), a.scale(84), a.scale(26), a.scale(8)
	buttonW, buttonH := a.scale(96), a.scale(30)
	editW := width - 2*margin - labelW - gap - buttonW
	if editW < a.scale(80) {
		editW = a.scale(80)
	}
	y := margin
	move(a.labels[0], margin, y+a.scale(4), labelW, rowH-a.scale(4))
	move(a.message, margin+labelW, y, editW, rowH)
	move(a.send, margin+labelW+editW+gap, y-a.scale(1), buttonW, rowH+a.scale(2))
	y += rowH + gap
	move(a.labels[1], margin, y+a.scale(4), labelW, rowH-a.scale(4))
	move(a.secret, margin+labelW, y, editW, rowH)
	y += rowH + gap
	move(a.labels[2], margin, y, width-2*margin, a.scale(20))
	y += a.scale(22)
	bottom := height - margin - buttonH
	labelY := bottom - gap - a.scale(22)
	transcriptH := labelY - gap - y
	if transcriptH < a.scale(40) {
		transcriptH = a.scale(40)
	}
	move(a.transcript, margin, y, width-2*margin, transcriptH)
	sameW := 2*buttonW + gap
	move(a.labels[3], margin, labelY, width-2*margin-sameW-gap, a.scale(22))
	for i, b := range a.same {
		move(b, width-margin-sameW+int32(i)*(buttonW+gap), labelY, buttonW, a.scale(22))
	}
	for i, b := range a.buttons {
		move(b, margin+int32(i)*(buttonW+gap), bottom, buttonW, buttonH)
	}
}

func (a *app) onSend() {
	if a.words != nil {
		return
	}
	message := windowText(a.message)
	a.log("send", message)
	a.appendTranscript("You: " + message + "\r\nBot: ")
	a.words = strings.Fields("echo " + message)
	a.wordsSent = 0
	procEnableWindow.Call(a.send, 0)
	procSetTimer.Call(a.main, streamTimer, wordInterval, 0)
}

func (a *app) onStreamTimer() {
	if a.words == nil {
		return
	}
	a.appendTranscript(a.words[a.wordsSent%len(a.words)] + " ")
	a.wordsSent++
	if a.wordsSent < replyWords {
		return
	}
	procKillTimer.Call(a.main, streamTimer)
	a.words = nil
	a.appendTranscript("\r\n[done]\r\n")
	procEnableWindow.Call(a.send, 1)
	a.log("done")
}

func (a *app) onFetch() {
	a.log("fetch", a.url)
	url, main := a.url, a.main
	go func() {
		result := ""
		client := http.Client{Timeout: fetchTimeout}
		res, err := client.Get(url)
		if err != nil {
			result = err.Error()
		} else {
			_, _ = io.Copy(io.Discard, res.Body)
			res.Body.Close()
			result = fmt.Sprint(res.StatusCode)
		}
		a.mu.Lock()
		a.fetched = append(a.fetched, result)
		a.mu.Unlock()
		procPostMessage.Call(main, wmFetchDone, 0, 0)
	}()
}

func (a *app) onFetchDone() {
	a.mu.Lock()
	results := a.fetched
	a.fetched = nil
	a.mu.Unlock()
	for _, r := range results {
		a.log("fetch-result", r)
		a.appendTranscript("Fetch: " + r + "\r\n")
	}
}

func (a *app) onCommand(id int) {
	switch id {
	case idSend:
		a.onSend()
	case idDialog:
		a.log("dialog")
		procMessageBox.Call(a.main, uintptr(unsafe.Pointer(utf16("Dialog body"))), uintptr(unsafe.Pointer(utf16("Fixture Dialog"))), mbOK)
		a.log("dialog-closed")
	case idCrash:
		a.log("crash")
		failFast()
	case idHang:
		a.log("hang")
		time.Sleep(hangDuration)
		a.log("hang-over")
	case idFetch:
		a.onFetch()
	case idTitles:
		a.onTitles()
	case idSame1:
		a.log("same", "1")
		a.appendTranscript("Same 1\r\n")
	case idSame2:
		a.log("same", "2")
		a.appendTranscript("Same 2\r\n")
	}
}

// onTitles starts changing the window title every 50 ms.
func (a *app) onTitles() {
	if a.titlesTick > 0 {
		return
	}
	a.log("titles")
	a.titlesTick = 1
	a.titlesSince = time.Now()
	setWindowText(a.main, fmt.Sprintf("Alcove Fixture %d", a.titlesTick))
	procSetTimer.Call(a.main, titlesTimer, titlesInterval, 0)
}

// onTitlesTimer changes the title once more: to the next numbered title until
// titlesFor has passed since the button was pressed, then to the base title.
func (a *app) onTitlesTimer() {
	a.titlesTick++
	if time.Since(a.titlesSince) < titlesFor {
		setWindowText(a.main, fmt.Sprintf("Alcove Fixture %d", a.titlesTick))
		return
	}
	procKillTimer.Call(a.main, titlesTimer)
	setWindowText(a.main, windowTitle)
	a.titlesTick = 0
	a.log("titles-done")
}

func setWindowText(hwnd uintptr, text string) {
	procSetWindowText.Call(hwnd, uintptr(unsafe.Pointer(utf16(text))))
}

// failFast clears SEM_NOGPFAULTERRORBOX from the error mode of the process,
// which lets Windows Error Reporting record the fault, and ends the process
// through RaiseFailFastException.
func failFast() {
	const semNoGPFaultErrorBox = 0x0002
	mode, _, _ := procGetErrorMode.Call()
	procSetErrorMode.Call(mode &^ semNoGPFaultErrorBox)
	procRaiseFailFast.Call(0, 0, 0)
}

// pointerAt returns the address a window message carries as a pointer.
func pointerAt(address uintptr) unsafe.Pointer {
	return *(*unsafe.Pointer)(unsafe.Pointer(&address))
}

func wndProc(hwnd, message, wParam, lParam uintptr) uintptr {
	a := &fixture
	switch uint32(message) {
	case wmCommand:
		id, code := int(wParam&0xFFFF), wParam>>16
		if id == idSecret && code == enChange {
			length, _, _ := procGetWindowTextLen.Call(a.secret)
			a.log("secret", fmt.Sprint(length))
		} else if lParam == 0 || code == 0 {
			a.onCommand(id)
		}
		return 0
	case wmTimer:
		if wParam == streamTimer {
			a.onStreamTimer()
		} else if wParam == titlesTimer {
			a.onTitlesTimer()
		}
		return 0
	case wmFetchDone:
		a.onFetchDone()
		return 0
	case wmSize:
		if a.transcript != 0 {
			a.layout()
		}
		return 0
	case wmGetMinMaxInfo:
		info := (*minMaxInfo)(pointerAt(lParam))
		info.minTrackSize = point{a.scale(minimumWidth), a.scale(minimumHeight)}
		return 0
	case wmDPIChanged:
		a.dpi = int(wParam >> 16 & 0xFFFF)
		suggested := (*rect)(pointerAt(lParam))
		procSetWindowPos.Call(hwnd, 0, uintptr(suggested.left), uintptr(suggested.top),
			uintptr(suggested.right-suggested.left), uintptr(suggested.bottom-suggested.top), swpNoZOrder|swpNoActivate)
		a.applyFont()
		a.layout()
		return 0
	case wmDestroy:
		a.log("exit")
		procPostQuitMessage.Call(0)
		return 0
	}
	r, _, _ := procDefWindowProc.Call(hwnd, message, wParam, lParam)
	return r
}

func main() {
	runtime.LockOSThread()
	logPath := flag.String("log", "", "append one line per action to this file")
	url := flag.String("url", "https://example.com/", "the address the Fetch button requests")
	flag.Parse()

	a := &fixture
	a.url = *url
	if *logPath != "" {
		a.logFile, _ = os.OpenFile(*logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	}

	perMonitorV2 := ^uintptr(3) // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 (-4)
	if procSetDPIContext.Find() != nil {
		procSetProcessDPIAware.Call()
	} else if ok, _, _ := procSetDPIContext.Call(perMonitorV2); ok == 0 {
		procSetProcessDPIAware.Call()
	}
	a.dpi = baseDPI
	if procGetDpiForSystem.Find() == nil {
		if dpi, _, _ := procGetDpiForSystem.Call(); dpi != 0 {
			a.dpi = int(dpi)
		}
	}

	instance, _, _ := procGetModuleHandle.Call(0)
	cursor, _, _ := procLoadCursor.Call(0, idcArrow)
	class := wndClassEx{
		wndProc:    syscall.NewCallback(wndProc),
		instance:   instance,
		cursor:     cursor,
		background: colorBtnFace + 1,
		className:  utf16(className),
	}
	class.size = uint32(unsafe.Sizeof(class))
	if atom, _, err := procRegisterClassEx.Call(uintptr(unsafe.Pointer(&class))); atom == 0 {
		a.log("error", "RegisterClassEx:", err.Error())
		os.Exit(1)
	}
	var err error
	a.main, _, err = procCreateWindowEx.Call(0, uintptr(unsafe.Pointer(utf16(className))), uintptr(unsafe.Pointer(utf16(windowTitle))),
		wsOverlappedWindow, cwUseDefault, cwUseDefault, uintptr(a.scale(windowWidth)), uintptr(a.scale(windowHeight)), 0, 0, instance, 0)
	if a.main == 0 {
		a.log("error", "CreateWindowEx:", err.Error())
		os.Exit(1)
	}
	if procGetDpiForWindow.Find() == nil {
		if dpi, _, _ := procGetDpiForWindow.Call(a.main); dpi != 0 && int(dpi) != a.dpi {
			a.dpi = int(dpi)
			procSetWindowPos.Call(a.main, 0, 0, 0, uintptr(a.scale(windowWidth)), uintptr(a.scale(windowHeight)), swpNoZOrder|swpNoActivate|0x0002)
		}
	}
	a.createControls()
	a.applyFont()
	a.layout()
	a.log("start", "pid", fmt.Sprint(os.Getpid()), "dpi", fmt.Sprint(a.dpi))
	procShowWindow.Call(a.main, swShowNormal)
	procUpdateWindow.Call(a.main)
	procSetFocus.Call(a.message)

	var m msg
	for {
		r, _, _ := procGetMessage.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if int32(r) <= 0 {
			break
		}
		if handled, _, _ := procIsDialogMessage.Call(a.main, uintptr(unsafe.Pointer(&m))); handled != 0 {
			continue
		}
		procTranslateMessage.Call(uintptr(unsafe.Pointer(&m)))
		procDispatchMessage.Call(uintptr(unsafe.Pointer(&m)))
	}
	os.Exit(int(m.wParam))
}
