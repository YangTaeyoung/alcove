package mitm

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestCALoadOrCreateIsStable(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "proxy-ca")
	first, err := LoadOrCreateCA(dir)
	if err != nil {
		t.Fatal(err)
	}
	second, err := LoadOrCreateCA(dir)
	if err != nil {
		t.Fatal(err)
	}
	if !first.Certificate().Equal(second.Certificate()) {
		t.Fatal("second load returned a different certificate")
	}
	for _, name := range []string{"ca.pem", "ca.key"} {
		st, err := os.Stat(filepath.Join(dir, name))
		if err != nil {
			t.Fatal(err)
		}
		if st.Mode().Perm() != 0o600 {
			t.Errorf("%s mode %v, want 0600", name, st.Mode().Perm())
		}
	}
	if st, _ := os.Stat(dir); st.Mode().Perm() != 0o700 {
		t.Errorf("directory mode %v, want 0700", st.Mode().Perm())
	}
	cert := first.Certificate()
	if !cert.IsCA || cert.KeyUsage != x509.KeyUsageCertSign|x509.KeyUsageCRLSign {
		t.Errorf("CA flags wrong: IsCA=%v usage=%v", cert.IsCA, cert.KeyUsage)
	}
	if !strings.HasPrefix(cert.Subject.CommonName, "Alcove Proxy CA (") {
		t.Errorf("common name %q", cert.Subject.CommonName)
	}
	if years := cert.NotAfter.Sub(cert.NotBefore).Hours() / 24 / 365; years < 4.9 || years > 5.1 {
		t.Errorf("validity %.2f years", years)
	}
	if first.PEMPath() != filepath.Join(dir, "ca.pem") {
		t.Errorf("PEMPath %q", first.PEMPath())
	}
}

func TestCARefusesHalfPopulatedDirectory(t *testing.T) {
	old := caSettleTime
	caSettleTime = 50 * time.Millisecond
	t.Cleanup(func() { caSettleTime = old })
	for _, name := range []string{"ca.pem", "ca.key"} {
		dir := t.TempDir()
		if err := os.WriteFile(filepath.Join(dir, name), []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := LoadOrCreateCA(dir); err == nil || !strings.Contains(err.Error(), "holds only one of ca.pem and ca.key") {
			t.Fatalf("only %s: error %v", name, err)
		}
	}
}

func TestLeafMatchesHostAndChainsToCA(t *testing.T) {
	ca, err := LoadOrCreateCA(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AddCert(ca.Certificate())
	for _, host := range []string{"api.example.com", "127.0.0.1", "::1"} {
		leaf, err := ca.Leaf(host)
		if err != nil {
			t.Fatal(err)
		}
		if len(leaf.Certificate) != 2 {
			t.Errorf("%s: chain has %d certificates, want leaf and CA", host, len(leaf.Certificate))
		}
		if _, err := leaf.Leaf.Verify(x509.VerifyOptions{Roots: roots, DNSName: host}); err != nil {
			t.Errorf("%s: verify: %v", host, err)
		}
		if ttl := time.Until(leaf.Leaf.NotAfter); ttl < 6*24*time.Hour || ttl > 8*24*time.Hour {
			t.Errorf("%s: validity left %v", host, ttl)
		}
		again, _ := ca.Leaf(host)
		if again != leaf {
			t.Errorf("%s: leaf not cached", host)
		}
	}
	ip, _ := ca.Leaf("127.0.0.1")
	if len(ip.Leaf.IPAddresses) != 1 || len(ip.Leaf.DNSNames) != 0 {
		t.Errorf("IP host should carry an IP SAN only: %v %v", ip.Leaf.IPAddresses, ip.Leaf.DNSNames)
	}
}

func TestLeafIsReplacedNearExpiry(t *testing.T) {
	ca, _ := LoadOrCreateCA(t.TempDir())
	first, _ := ca.Leaf("a.example")
	stale := *first
	staleLeaf := *first.Leaf
	staleLeaf.NotAfter = time.Now().Add(12 * time.Hour)
	stale.Leaf = &staleLeaf
	ca.leaves["a.example"] = &stale
	next, _ := ca.Leaf("a.example")
	if next == &stale {
		t.Fatal("near-expiry leaf was served from the cache")
	}
}

func TestConcurrentFirstUseCreatesOneMatchingCA(t *testing.T) {
	for round := 0; round < 20; round++ {
		dir := filepath.Join(t.TempDir(), "proxy-ca")
		const n = 8
		cas := make([]*CA, n)
		errs := make([]error, n)
		var wg sync.WaitGroup
		for i := 0; i < n; i++ {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				cas[i], errs[i] = LoadOrCreateCA(dir)
			}(i)
		}
		wg.Wait()
		for i := 0; i < n; i++ {
			if errs[i] != nil {
				t.Fatalf("round %d: load %d: %v", round, i, errs[i])
			}
			if !cas[i].Certificate().Equal(cas[0].Certificate()) {
				t.Fatalf("round %d: load %d returned another certificate", round, i)
			}
		}
		disk, err := LoadOrCreateCA(dir)
		if err != nil {
			t.Fatalf("round %d: reload: %v", round, err)
		}
		if !disk.Certificate().Equal(cas[0].Certificate()) {
			t.Fatalf("round %d: the files hold another certificate", round)
		}
		if _, err := disk.Leaf("example.com"); err != nil {
			t.Fatalf("round %d: leaf from the files: %v", round, err)
		}
		if names, _ := os.ReadDir(dir); len(names) != 2 {
			t.Fatalf("round %d: directory holds %d entries", round, len(names))
		}
	}
}

// writeCAFiles writes ca.pem and ca.key for a self-signed certificate built
// from a CA template changed by edit.
func writeCAFiles(t *testing.T, dir string, edit func(*x509.Certificate)) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(7),
		Subject:               pkix.Name{CommonName: "test CA"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign,
	}
	edit(tmpl)
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, _ := x509.MarshalPKCS8PrivateKey(key)
	if err := os.WriteFile(filepath.Join(dir, "ca.pem"), pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "ca.key"), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestCARefusesUnusableFiles(t *testing.T) {
	mismatched := func(t *testing.T, dir string) {
		writeCAFiles(t, dir, func(*x509.Certificate) {})
		other := t.TempDir()
		writeCAFiles(t, other, func(*x509.Certificate) {})
		key, _ := os.ReadFile(filepath.Join(other, "ca.key"))
		if err := os.WriteFile(filepath.Join(dir, "ca.key"), key, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	for _, c := range []struct {
		name  string
		setup func(t *testing.T, dir string)
		want  string
	}{
		{"key of another certificate", mismatched, "ca.key does not belong to ca.pem"},
		{"expired", func(t *testing.T, dir string) {
			writeCAFiles(t, dir, func(c *x509.Certificate) {
				c.NotBefore = time.Now().Add(-48 * time.Hour)
				c.NotAfter = time.Now().Add(-24 * time.Hour)
			})
		}, "ca.pem expired on "},
		{"not yet valid", func(t *testing.T, dir string) {
			writeCAFiles(t, dir, func(c *x509.Certificate) {
				c.NotBefore = time.Now().Add(24 * time.Hour)
				c.NotAfter = time.Now().Add(48 * time.Hour)
			})
		}, "ca.pem is not valid before "},
		{"not a CA", func(t *testing.T, dir string) {
			writeCAFiles(t, dir, func(c *x509.Certificate) { c.IsCA = false })
		}, "ca.pem is not a CA certificate"},
		{"no signing usage", func(t *testing.T, dir string) {
			writeCAFiles(t, dir, func(c *x509.Certificate) { c.KeyUsage = x509.KeyUsageDigitalSignature })
		}, "ca.pem is not a CA certificate"},
	} {
		t.Run(c.name, func(t *testing.T) {
			dir := t.TempDir()
			c.setup(t, dir)
			_, err := LoadOrCreateCA(dir)
			if err == nil {
				t.Fatal("the files were accepted")
			}
			if !strings.Contains(err.Error(), c.want) || !strings.HasSuffix(err.Error(), "; delete ca.pem and ca.key in "+dir+" to create a new CA") {
				t.Fatalf("error %q", err)
			}
		})
	}
}

func TestCAFilesAreMadePrivateOnLoad(t *testing.T) {
	dir := t.TempDir()
	if _, err := LoadOrCreateCA(dir); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"ca.pem", "ca.key"} {
		if err := os.Chmod(filepath.Join(dir, name), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := LoadOrCreateCA(dir); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"ca.pem", "ca.key"} {
		st, err := os.Stat(filepath.Join(dir, name))
		if err != nil {
			t.Fatal(err)
		}
		if st.Mode().Perm() != 0o600 {
			t.Errorf("%s mode %v, want 0600", name, st.Mode().Perm())
		}
	}
}
