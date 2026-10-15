//go:build windows

package sysfolder

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"reflect"
	"strings"
	"syscall"
	"testing"
	"unsafe"
)

// TestMain prints MachineVars as JSON and exits when ALCOVE_PRINT_VARS is 1;
// otherwise it runs the tests.
func TestMain(m *testing.M) {
	if os.Getenv("ALCOVE_PRINT_VARS") == "1" {
		vars, err := MachineVars()
		if err != nil {
			fmt.Println("error:", err)
			os.Exit(1)
		}
		out, _ := json.Marshal(vars)
		fmt.Println(string(out))
		os.Exit(0)
	}
	os.Exit(m.Run())
}

// varsOfAProcessWith returns MachineVars of a new process of this test binary
// whose environment adds env.
func varsOfAProcessWith(t *testing.T, env ...string) map[string]string {
	t.Helper()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(self)
	cmd.Env = append(append(os.Environ(), "ALCOVE_PRINT_VARS=1"), env...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	var vars map[string]string
	if err := json.Unmarshal(out, &vars); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	return vars
}

func TestTheMachineVariablesAreNotTakenFromTheEnvironment(t *testing.T) {
	want := varsOfAProcessWith(t)
	if !strings.HasSuffix(strings.ToLower(want["systemroot"]), `\windows`) || want["programfiles"] == "" {
		t.Fatalf("the machine variables are %v", want)
	}
	dir := t.TempDir()
	got := varsOfAProcessWith(t, "SystemRoot="+dir, "windir="+dir, "SystemDrive="+dir, "ProgramFiles="+dir, "ProgramFiles(x86)="+dir)
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("with the variables set to %s: %v; expected %v", dir, got, want)
	}
}

var (
	testAdvapi32         = syscall.NewLazyDLL("advapi32.dll")
	procTestRegCreateKey = testAdvapi32.NewProc("RegCreateKeyExW")
	procTestRegSetValue  = testAdvapi32.NewProc("RegSetValueExW")
	procTestRegDeleteKey = testAdvapi32.NewProc("RegDeleteKeyW")
)

// setUserValue creates the key of HKEY_CURRENT_USER, gives it the REG_SZ
// value name holding data as it is, and deletes the key when the test ends.
func setUserValue(t *testing.T, key, name string, data []byte) {
	t.Helper()
	k, _ := syscall.UTF16PtrFromString(key)
	n, _ := syscall.UTF16PtrFromString(name)
	var h syscall.Handle
	if r, _, _ := procTestRegCreateKey.Call(uintptr(syscall.HKEY_CURRENT_USER), uintptr(unsafe.Pointer(k)), 0, 0, 0,
		uintptr(syscall.KEY_SET_VALUE), 0, uintptr(unsafe.Pointer(&h)), 0); r != 0 {
		t.Fatalf("RegCreateKeyExW: %v", syscall.Errno(r))
	}
	t.Cleanup(func() { procTestRegDeleteKey.Call(uintptr(syscall.HKEY_CURRENT_USER), uintptr(unsafe.Pointer(k))) })
	defer syscall.RegCloseKey(h)
	if r, _, _ := procTestRegSetValue.Call(uintptr(h), uintptr(unsafe.Pointer(n)), 0, uintptr(syscall.REG_SZ),
		uintptr(unsafe.Pointer(&data[0])), uintptr(len(data))); r != 0 {
		t.Fatalf("RegSetValueExW: %v", syscall.Errno(r))
	}
}

func TestAStringValueOfAnOddNumberOfBytesIsReadWhole(t *testing.T) {
	const key = `Software\AlcoveSysfolderTest`
	setUserValue(t, key, "Odd", []byte{'a', 0, 'b', 0, 'c'})
	got, err := queryString(syscall.HKEY_CURRENT_USER, "HKCU", key, "Odd")
	if err != nil || got != "abc" {
		t.Fatalf("the value of 5 bytes reads as %q, %v; expected %q", got, err, "abc")
	}
}

// sessionEnvironmentKey holds the machine's environment variables.
const sessionEnvironmentKey = `SYSTEM\CurrentControlSet\Control\Session Manager\Environment`

func TestMachineValuesListTheStringValuesOfAKey(t *testing.T) {
	values, err := MachineValues(sessionEnvironmentKey)
	if err != nil {
		t.Fatal(err)
	}
	byName := map[string]Value{}
	for _, v := range values {
		byName[strings.ToLower(v.Name)] = v
	}
	path, err := MachineString(sessionEnvironmentKey, "Path")
	if err != nil {
		t.Fatal(err)
	}
	if got := byName["path"]; got.Text != path || !got.Expand {
		t.Fatalf("Path is %+v; expected the REG_EXPAND_SZ text %q", got, path)
	}
	for _, name := range []string{"pathext", "comspec", "os", "number_of_processors", "processor_architecture"} {
		if byName[name].Text == "" {
			t.Errorf("%s is missing from %+v", name, values)
		}
	}
	if _, err := MachineValues(`SOFTWARE\Alcove\NoSuchKey`); err == nil {
		t.Fatal("a missing key gave no error")
	}
}

func TestTheProfileFolderOfTheCurrentAccountIsItsProfileDirectory(t *testing.T) {
	tok, err := syscall.OpenCurrentProcessToken()
	if err != nil {
		t.Fatal(err)
	}
	defer tok.Close()
	tu, err := tok.GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	sid, err := tu.User.Sid.String()
	if err != nil {
		t.Fatal(err)
	}
	want, err := tok.GetUserProfileDirectory()
	if err != nil {
		t.Fatal(err)
	}
	vars, err := MachineVars()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("USERPROFILE", t.TempDir())
	t.Setenv("SystemDrive", "Q:")
	got, err := ProfileFolder(sid, vars)
	if err != nil || !strings.EqualFold(got, want) {
		t.Fatalf("ProfileFolder(%s) = %q, %v; expected %q", sid, got, err, want)
	}
	if _, err := ProfileFolder("S-1-5-21-1-2-3-999999", vars); err == nil {
		t.Fatal("an unknown SID gave no error")
	}
}
