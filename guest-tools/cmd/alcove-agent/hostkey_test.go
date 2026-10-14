package main

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var sampleKey = bytes.Repeat([]byte{0x3C}, 32)

func TestAFileKeyStoreLoadsNothingBeforeASave(t *testing.T) {
	s := fileKeyStore{path: filepath.Join(t.TempDir(), "host.key")}
	key, err := s.Load()
	if key != nil || err != nil {
		t.Fatalf("Load = %x, %v", key, err)
	}
}

func TestAFileKeyStoreSavesOnceAndLoadsTheKey(t *testing.T) {
	path := filepath.Join(t.TempDir(), "host.key")
	s := fileKeyStore{path: path}
	if err := s.Save(sampleKey); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(path); string(got) != strings.Repeat("3c", 32)+"\n" {
		t.Fatalf("file holds %q", got)
	}
	key, err := s.Load()
	if err != nil || !bytes.Equal(key, sampleKey) {
		t.Fatalf("Load = %x, %v", key, err)
	}
	if err := s.Save(bytes.Repeat([]byte{1}, 32)); err == nil {
		t.Fatal("a second Save succeeded")
	}
	if key, _ := s.Load(); !bytes.Equal(key, sampleKey) {
		t.Fatalf("after the second Save the key is %x", key)
	}
}

func TestAFileKeyStoreRefusesAFileThatDoesNotHoldAKey(t *testing.T) {
	path := filepath.Join(t.TempDir(), "host.key")
	for _, content := range []string{"", "abc\n", strings.Repeat("zz", 32) + "\n", strings.Repeat("3c", 33) + "\n"} {
		os.Remove(path)
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		key, err := fileKeyStore{path: path}.Load()
		want := path + " does not hold 64 hexadecimal digits; run alcove-agent --forget-host-key as an administrator and connect again"
		if key != nil || err == nil || err.Error() != want {
			t.Fatalf("content %q: Load = %x, %v", content, key, err)
		}
	}
}

func TestAnUnusableFileKeyStoreAnswersItsReason(t *testing.T) {
	reason := errors.New("the data folder is not locked")
	s := fileKeyStore{path: filepath.Join(t.TempDir(), "host.key"), unusable: reason}
	if _, err := s.Load(); err != reason {
		t.Fatalf("Load error %v", err)
	}
	if err := s.Save(sampleKey); err != reason {
		t.Fatalf("Save error %v", err)
	}
	if _, err := os.Stat(s.path); !os.IsNotExist(err) {
		t.Fatalf("the file exists: %v", err)
	}
}

func TestForgetHostKeyRemovesTheFileAndSaysSo(t *testing.T) {
	path := filepath.Join(t.TempDir(), "host.key")
	if err := (fileKeyStore{path: path}).Save(sampleKey); err != nil {
		t.Fatal(err)
	}
	var out, errOut strings.Builder
	if code := forgetHostKey(path, &out, &errOut); code != 0 || out.String() != "the host key was removed; the next host that connects pairs with this agent\n" || errOut.Len() != 0 {
		t.Fatalf("first forget: %d %q %q", code, out.String(), errOut.String())
	}
	if _, err := os.Lstat(path); !os.IsNotExist(err) {
		t.Fatalf("the file is still there: %v", err)
	}
	out.Reset()
	if code := forgetHostKey(path, &out, &errOut); code != 0 || out.String() != "no host key was stored\n" {
		t.Fatalf("second forget: %d %q %q", code, out.String(), errOut.String())
	}
}

func TestForgetHostKeyThatCannotRemoveTheFileExitsWith1(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "full")
	path := filepath.Join(dir, "host.key")
	if err := os.MkdirAll(path, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(path, "inside"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	var out, errOut strings.Builder
	code := forgetHostKey(path, &out, &errOut)
	if code != 1 || out.Len() != 0 || !strings.HasPrefix(errOut.String(), "cannot remove "+path+" (") ||
		!strings.HasSuffix(errOut.String(), "); run alcove-agent --forget-host-key as an administrator (root on Linux)\n") {
		t.Fatalf("forget: %d %q %q", code, out.String(), errOut.String())
	}
}
