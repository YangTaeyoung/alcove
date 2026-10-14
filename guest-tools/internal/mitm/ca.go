// Package mitm implements the intercepting HTTP(S) proxy behind alcove-proxy:
// a local certificate authority, request capture and request rules.
package mitm

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	caValidity   = 5 * 365 * 24 * time.Hour
	leafValidity = 7 * 24 * time.Hour
	backdate     = time.Hour
	leafRenewal  = 24 * time.Hour
)

// CA signs per-host leaf certificates.
type CA struct {
	dir    string
	cert   *x509.Certificate
	key    *ecdsa.PrivateKey
	mu     sync.Mutex
	leaves map[string]*tls.Certificate
}

// caSettleTime bounds how long a load waits for ca.pem when ca.key exists
// without it, the state between the two links of a creation in progress.
var caSettleTime = 2 * time.Second

// errCreationLost reports that another creation linked ca.key first.
var errCreationLost = errors.New("another process created the CA first")

// LoadOrCreateCA loads ca.pem and ca.key from dir, creating the directory and
// both files when neither exists. Concurrent creations in the same directory
// end with one pair on disk, which every caller returns. Files readable by
// others are made private (mode 0600).
func LoadOrCreateCA(dir string) (*CA, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("cannot create the CA directory %s: %w", dir, err)
	}
	certPath, keyPath := filepath.Join(dir, "ca.pem"), filepath.Join(dir, "ca.key")
	deadline := time.Now().Add(caSettleTime)
	for {
		certPEM, certErr := os.ReadFile(certPath)
		keyPEM, keyErr := os.ReadFile(keyPath)
		certMissing := errors.Is(certErr, os.ErrNotExist)
		keyMissing := errors.Is(keyErr, os.ErrNotExist)
		switch {
		case certErr == nil && keyErr == nil:
			if err := makePrivate(certPath, keyPath); err != nil {
				return nil, err
			}
			return parseCA(dir, certPEM, keyPEM, time.Now())
		case certMissing && keyMissing:
			ca, err := createCA(dir, certPath, keyPath)
			if errors.Is(err, errCreationLost) {
				continue
			}
			return ca, err
		case certErr != nil && !certMissing:
			return nil, fmt.Errorf("cannot read %s: %w", certPath, certErr)
		case keyErr != nil && !keyMissing:
			return nil, fmt.Errorf("cannot read %s: %w", keyPath, keyErr)
		case certMissing && time.Now().Before(deadline):
			time.Sleep(10 * time.Millisecond)
			continue
		}
		return nil, fmt.Errorf("%s holds only one of ca.pem and ca.key; delete both files to create a new CA", dir)
	}
}

// makePrivate sets mode 0600 on each path that group or others may access.
func makePrivate(paths ...string) error {
	for _, path := range paths {
		st, err := os.Stat(path)
		if err != nil {
			return fmt.Errorf("cannot read %s: %w", path, err)
		}
		if st.Mode().Perm()&0o077 == 0 {
			continue
		}
		if err := os.Chmod(path, 0o600); err != nil {
			return fmt.Errorf("cannot make %s private (%v); run chmod 600 on it", path, err)
		}
	}
	return nil
}

func parseCA(dir string, certPEM, keyPEM []byte, now time.Time) (*CA, error) {
	fix := "; delete ca.pem and ca.key in " + dir + " to create a new CA"
	cb, _ := pem.Decode(certPEM)
	if cb == nil {
		return nil, errors.New("ca.pem is not PEM" + fix)
	}
	cert, err := x509.ParseCertificate(cb.Bytes)
	if err != nil {
		return nil, fmt.Errorf("ca.pem is not a certificate (%v)%s", err, fix)
	}
	kb, _ := pem.Decode(keyPEM)
	if kb == nil {
		return nil, errors.New("ca.key is not PEM" + fix)
	}
	parsed, err := x509.ParsePKCS8PrivateKey(kb.Bytes)
	if err != nil {
		return nil, fmt.Errorf("ca.key is not a PKCS#8 key (%v)%s", err, fix)
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("ca.key is not an ECDSA key" + fix)
	}
	if pub, ok := cert.PublicKey.(*ecdsa.PublicKey); !ok || !pub.Equal(&key.PublicKey) {
		return nil, errors.New("ca.key does not belong to ca.pem" + fix)
	}
	if !cert.IsCA || cert.KeyUsage&x509.KeyUsageCertSign == 0 {
		return nil, errors.New("ca.pem is not a CA certificate" + fix)
	}
	if now.After(cert.NotAfter) {
		return nil, fmt.Errorf("ca.pem expired on %s%s", cert.NotAfter.UTC().Format(time.RFC3339), fix)
	}
	if now.Before(cert.NotBefore) {
		return nil, fmt.Errorf("ca.pem is not valid before %s%s", cert.NotBefore.UTC().Format(time.RFC3339), fix)
	}
	return &CA{dir: dir, cert: cert, key: key, leaves: map[string]*tls.Certificate{}}, nil
}

func createCA(dir, certPath, keyPath string) (*CA, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	serial, err := newSerial()
	if err != nil {
		return nil, err
	}
	name, _ := os.Hostname()
	if name == "" {
		name = "unknown host"
	}
	now := time.Now()
	tmpl := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: "Alcove Proxy CA (" + name + ")"},
		NotBefore:             now.Add(-backdate),
		NotAfter:              now.Add(caValidity),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return nil, err
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, err
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return nil, err
	}
	keyTmp, err := writeTemp(dir, keyPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}))
	if err != nil {
		return nil, err
	}
	defer os.Remove(keyTmp)
	certTmp, err := writeTemp(dir, certPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
	if err != nil {
		return nil, err
	}
	defer os.Remove(certTmp)
	if err := os.Link(keyTmp, keyPath); err != nil {
		if errors.Is(err, os.ErrExist) {
			return nil, errCreationLost
		}
		return nil, fmt.Errorf("cannot write %s: %w", keyPath, err)
	}
	if err := os.Link(certTmp, certPath); err != nil {
		return nil, fmt.Errorf("cannot write %s (%v); delete ca.pem and ca.key in %s to create a new CA", certPath, err, dir)
	}
	return &CA{dir: dir, cert: cert, key: key, leaves: map[string]*tls.Certificate{}}, nil
}

// writeTemp writes data to a new file of mode 0600 in dir and returns its
// path; target names the file the data is meant for.
func writeTemp(dir, target string, data []byte) (string, error) {
	f, err := os.CreateTemp(dir, "."+filepath.Base(target)+"-*")
	if err != nil {
		return "", fmt.Errorf("cannot write %s: %w", target, err)
	}
	_, werr := f.Write(data)
	cerr := f.Close()
	if werr == nil {
		werr = cerr
	}
	if werr == nil {
		werr = os.Chmod(f.Name(), 0o600)
	}
	if werr != nil {
		os.Remove(f.Name())
		return "", fmt.Errorf("cannot write %s: %w", target, werr)
	}
	return f.Name(), nil
}

func newSerial() (*big.Int, error) {
	return rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 127))
}

// PEMPath is the path of the CA certificate the guest must trust.
func (c *CA) PEMPath() string { return filepath.Join(c.dir, "ca.pem") }

// Certificate is the CA certificate.
func (c *CA) Certificate() *x509.Certificate { return c.cert }

// Leaf returns a certificate for host signed by the CA. Results are cached per
// host and replaced when they are within a day of expiry.
func (c *CA) Leaf(host string) (*tls.Certificate, error) {
	host = strings.ToLower(strings.TrimSuffix(host, "."))
	if host == "" {
		return nil, errors.New("cannot issue a certificate for an empty host name")
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if cached, ok := c.leaves[host]; ok && time.Until(cached.Leaf.NotAfter) > leafRenewal {
		return cached, nil
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	serial, err := newSerial()
	if err != nil {
		return nil, err
	}
	now := time.Now()
	tmpl := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: host},
		NotBefore:             now.Add(-backdate),
		NotAfter:              now.Add(leafValidity),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
	}
	if ip := net.ParseIP(host); ip != nil {
		tmpl.IPAddresses = []net.IP{ip}
	} else {
		tmpl.DNSNames = []string{host}
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, c.cert, &key.PublicKey, c.key)
	if err != nil {
		return nil, err
	}
	leaf, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, err
	}
	out := &tls.Certificate{Certificate: [][]byte{der, c.cert.Raw}, PrivateKey: key, Leaf: leaf}
	c.leaves[host] = out
	return out, nil
}
