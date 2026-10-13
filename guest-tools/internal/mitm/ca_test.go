package mitm

import (
	"crypto/x509"
	"os"
	"path/filepath"
	"strings"
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
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "ca.pem"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadOrCreateCA(dir); err == nil {
		t.Fatal("expected an error for a directory with only ca.pem")
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
