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

// LoadOrCreateCA loads ca.pem and ca.key from dir, creating the directory and
// both files when neither exists.
func LoadOrCreateCA(dir string) (*CA, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("cannot create the CA directory %s: %w", dir, err)
	}
	certPath, keyPath := filepath.Join(dir, "ca.pem"), filepath.Join(dir, "ca.key")
	certPEM, certErr := os.ReadFile(certPath)
	keyPEM, keyErr := os.ReadFile(keyPath)
	certMissing := errors.Is(certErr, os.ErrNotExist)
	keyMissing := errors.Is(keyErr, os.ErrNotExist)
	switch {
	case certErr == nil && keyErr == nil:
		return parseCA(dir, certPEM, keyPEM)
	case certMissing && keyMissing:
		return createCA(dir, certPath, keyPath)
	case certErr != nil && !certMissing:
		return nil, fmt.Errorf("cannot read %s: %w", certPath, certErr)
	case keyErr != nil && !keyMissing:
		return nil, fmt.Errorf("cannot read %s: %w", keyPath, keyErr)
	}
	return nil, fmt.Errorf("%s holds only one of ca.pem and ca.key; delete both files to create a new CA", dir)
}

func parseCA(dir string, certPEM, keyPEM []byte) (*CA, error) {
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
	if err := writeSecret(keyPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER})); err != nil {
		return nil, err
	}
	if err := writeSecret(certPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})); err != nil {
		return nil, err
	}
	return &CA{dir: dir, cert: cert, key: key, leaves: map[string]*tls.Certificate{}}, nil
}

func writeSecret(path string, data []byte) error {
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return fmt.Errorf("cannot write %s: %w", path, err)
	}
	return os.Chmod(path, 0o600)
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
