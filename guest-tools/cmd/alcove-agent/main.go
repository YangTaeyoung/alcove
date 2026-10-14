// alcove-agent runs inside a guest and serves docs/agent-protocol.md on TCP 7645
// to connections from 10.0.2.2 and from the ranges given with --allow-peer,
// once the host paired with it or proved the stored host key.
//
//	alcove-agent [--port 7645] [--allow-exec] [--allow-peer CIDR]... [--token T]
//	alcove-agent --install   (Windows: scheduled task at logon + firewall rule)
//	alcove-agent --forget-host-key   (removes the stored host key)
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/YangTaeyoung/alcove/guest-tools/internal/server"
	"github.com/YangTaeyoung/alcove/guest-tools/internal/token"
	"github.com/YangTaeyoung/alcove/guest-tools/internal/uia"
)

func main() {
	port := flag.Int("port", 7645, "listen port")
	allowExec := flag.Bool("allow-exec", false, "allow the exec message (test harness)")
	tok := flag.String("token", "", "override the SMBIOS token")
	install := flag.Bool("install", false, "install to start at logon (Windows) and exit")
	logPath := flag.String("log", "", "log file (default: stderr)")
	forget := flag.Bool("forget-host-key", false, "remove the stored host key, so the next host that connects pairs with this agent, and exit (as an administrator or root)")
	var peers peerFlag
	flag.Var(&peers, "allow-peer", "also serve connections from this address or CIDR range (repeatable; 10.0.2.2 is always served)")
	flag.Parse()

	if *forget {
		path, err := forgetHostKeyPath()
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		os.Exit(forgetHostKey(path, os.Stdout, os.Stderr))
	}

	if *install {
		dir, err := lockDataFolder()
		if err != nil {
			fmt.Fprintln(os.Stderr, "install failed:", err)
			os.Exit(1)
		}
		if err := installAtLogon(*port, *allowExec, peers.args(), dir); err != nil {
			fmt.Fprintln(os.Stderr, "install failed:", err)
			writeInstallLog(dir, "install failed: "+err.Error())
			os.Exit(1)
		}
		fmt.Println("installed")
		writeInstallLog(dir, "installed")
		return
	}

	var alcoveDir, uiaDir, movedApps string
	var movedData []string
	var dataErr, lockErr, appsErr error
	if uia.Available() {
		alcoveDir, uiaDir, dataErr = dataFolders(os.Getenv("ProgramData"))
		if dataErr == nil {
			movedData, lockErr = uia.LockHelperFolders(alcoveDir, uiaDir)
		}
		movedApps, appsErr = uia.LockDeployRoot(deployRoot)
	}
	logger := log.Default()
	if *logPath != "" {
		if dataErr != nil {
			fmt.Fprintf(os.Stderr, "log: %s is not opened because %%ProgramData%% is not set\n", *logPath)
		} else if f, err := openLog(*logPath, alcoveDir, lockErr); err != nil {
			fmt.Fprintln(os.Stderr, "log:", err)
		} else {
			logger = log.New(f, "", log.LstdFlags)
		}
	}
	if dataErr != nil {
		logger.Print(dataErr)
	}
	for _, m := range movedData {
		logger.Printf("a data folder of another owner was moved to %s; remove it as an administrator", m)
	}
	if lockErr != nil {
		logger.Printf("the helper folders are not locked (%v); the UI helper will not start until they can be locked", lockErr)
	}
	if movedApps != "" {
		logger.Printf("%s was a link, belonged to another owner or let other users change it; it was moved to %s, which an administrator may remove after checking it", deployRoot, movedApps)
	}
	if appsErr != nil {
		logger.Printf("the deploy root is not locked (%v)", appsErr)
	}
	if *tok == "" {
		*tok = token.Read()
	}
	l, err := net.Listen("tcp", fmt.Sprintf("0.0.0.0:%d", *port))
	if err != nil {
		logger.Fatalf("listen: %v", err)
	}
	allowed := append(append([]netip.Prefix{}, server.DefaultPeers...), peers...)
	logger.Printf("alcove-agent %s listening on %s for %s (token %s, exec %v)", server.AgentVersion, l.Addr(), peerList(allowed).String(), mask(*tok), *allowExec)
	var s *server.Server
	var ui server.UI
	if dataErr != nil {
		ui = noHelper{dataErr}
	} else if uia.Available() {
		helper := uia.New(uia.DefaultLauncher(uiaDir, logger.Printf),
			func(name string, fields map[string]any) { s.HandleUIEvent(name, fields) })
		helper.SetOnStart(func() { s.HandleUIStart() })
		helper.SetLogger(logger)
		helper.SetLogPath(filepath.Join(uiaDir, "helper.log"))
		ui = helper
	}
	s = server.New(server.Options{Token: *tok, AllowExec: *allowExec, Logger: logger, UI: ui, AllowPeers: allowed,
		HostKey: newHostKeyStore(alcoveDir, dataErr, lockErr)})
	err = s.Serve(l)
	s.Close()
	logger.Fatal(err)
}

// deployRoot is the default folder of the apps vm.deploy copies into a
// Windows guest.
const deployRoot = `C:\alcove-apps`

// errNoProgramData is the answer of every UI operation of an agent that was
// started without %ProgramData%.
const errNoProgramData = "the UI helper cannot start because %ProgramData% is not set; start alcove-agent through its scheduled task"

// dataFolders returns the Alcove folder under programData and the uia folder
// inside it. An empty programData is an error and names no folder.
func dataFolders(programData string) (alcoveDir, uiaDir string, err error) {
	if programData == "" {
		return "", "", errors.New(errNoProgramData)
	}
	alcoveDir = filepath.Join(programData, "Alcove")
	return alcoveDir, filepath.Join(alcoveDir, "uia"), nil
}

// noHelper answers every UI operation with its error and starts no process.
type noHelper struct{ err error }

func (n noHelper) CallContext(context.Context, string, map[string]any, time.Duration) (map[string]any, error) {
	return nil, n.err
}

// openLog opens the log file for appending after creating its folder. A log
// file inside lockedDir is not opened when locking that folder failed with
// lockErr, and a log file that is a reparse point or a symbolic link is not opened.
func openLog(path, lockedDir string, lockErr error) (*os.File, error) {
	if lockErr != nil && insideDir(lockedDir, path) {
		return nil, fmt.Errorf("%s is not opened because its folder is not locked (%v)", path, lockErr)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	if err := refuseReparse(path); err != nil {
		return nil, err
	}
	return os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY|openNoFollow, 0o644)
}

// insideDir reports whether path lies in dir or below it; names are compared
// without regard to case.
func insideDir(dir, path string) bool {
	if dir == "" {
		return false
	}
	rel, err := filepath.Rel(strings.ToLower(filepath.Clean(dir)), strings.ToLower(filepath.Clean(path)))
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

// peerFlag collects the --allow-peer values.
type peerFlag []netip.Prefix

// peerList prints address ranges separated by commas.
type peerList []netip.Prefix

func (p peerList) String() string {
	parts := make([]string, len(p))
	for i, r := range p {
		parts[i] = r.String()
	}
	return strings.Join(parts, ",")
}

func (p *peerFlag) String() string { return peerList(*p).String() }

// Set adds a CIDR range, or a single address as a range of that address only.
// A range with bits set after its prefix length is refused.
func (p *peerFlag) Set(v string) error {
	bad := fmt.Errorf("--allow-peer %q is not an address such as 10.0.2.2 or a range such as 192.168.64.0/24; pass one of those", v)
	if a, err := netip.ParseAddr(v); err == nil && a.Zone() == "" {
		*p = append(*p, netip.PrefixFrom(a, a.BitLen()))
		return nil
	}
	r, err := netip.ParsePrefix(v)
	if err != nil || r != r.Masked() {
		return bad
	}
	*p = append(*p, r)
	return nil
}

// args returns the command-line arguments that pass the same ranges again.
func (p peerFlag) args() []string {
	var out []string
	for _, r := range p {
		out = append(out, "--allow-peer", r.String())
	}
	return out
}

func mask(t string) string {
	if len(t) < 8 {
		return "(none)"
	}
	return t[:4] + "..." + t[len(t)-4:]
}

// writeInstallLog appends the install result to install.log in dir, where the
// result of a build without a console can be read afterwards. It does nothing
// when the file is a reparse point or a symbolic link.
func writeInstallLog(dir, msg string) {
	path := filepath.Join(dir, "install.log")
	_ = os.MkdirAll(dir, 0o755)
	if refuseReparse(path) != nil {
		return
	}
	if f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY|openNoFollow, 0o644); err == nil {
		fmt.Fprintf(f, "%s %s\n", timeNow(), msg)
		f.Close()
	}
}

func timeNow() string { return time.Now().Format(time.RFC3339) }
