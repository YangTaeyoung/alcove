// alcove-agent runs inside a guest and serves docs/agent-protocol.md on TCP 7645.
//
//	alcove-agent [--port 7645] [--allow-exec] [--token T]
//	alcove-agent --install   (Windows: scheduled task at logon + firewall rule)
package main

import (
	"flag"
	"fmt"
	"log"
	"net"
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
	flag.Parse()

	if *install {
		dir, err := lockDataFolder()
		if err != nil {
			fmt.Fprintln(os.Stderr, "install failed:", err)
			os.Exit(1)
		}
		if err := installAtLogon(*port, *allowExec, dir); err != nil {
			fmt.Fprintln(os.Stderr, "install failed:", err)
			writeInstallLog(dir, "install failed: "+err.Error())
			os.Exit(1)
		}
		fmt.Println("installed")
		writeInstallLog(dir, "installed")
		return
	}

	var alcoveDir, uiaDir string
	var lockErr error
	if uia.Available() {
		base := os.Getenv("ProgramData")
		if base == "" {
			base = os.TempDir()
		}
		alcoveDir = filepath.Join(base, "Alcove")
		uiaDir = filepath.Join(alcoveDir, "uia")
		lockErr = uia.LockHelperFolders(alcoveDir, uiaDir)
	}
	logger := log.Default()
	if *logPath != "" {
		if f, err := openLog(*logPath, alcoveDir, lockErr); err != nil {
			fmt.Fprintln(os.Stderr, "log:", err)
		} else {
			logger = log.New(f, "", log.LstdFlags)
		}
	}
	if lockErr != nil {
		logger.Printf("the helper folders are not locked (%v); the UI helper will not start until they can be locked", lockErr)
	}
	if *tok == "" {
		*tok = token.Read()
	}
	l, err := net.Listen("tcp", fmt.Sprintf("0.0.0.0:%d", *port))
	if err != nil {
		logger.Fatalf("listen: %v", err)
	}
	logger.Printf("alcove-agent %s listening on %s (token %s, exec %v)", server.AgentVersion, l.Addr(), mask(*tok), *allowExec)
	var s *server.Server
	var ui server.UI
	if uia.Available() {
		helper := uia.New(uia.DefaultLauncher(uiaDir),
			func(name string, fields map[string]any) { s.HandleUIEvent(name, fields) })
		helper.SetOnStart(func() { s.HandleUIStart() })
		helper.SetLogger(logger)
		helper.SetLogPath(filepath.Join(uiaDir, "helper.log"))
		ui = helper
	}
	s = server.New(server.Options{Token: *tok, AllowExec: *allowExec, Logger: logger, UI: ui})
	err = s.Serve(l)
	s.Close()
	logger.Fatal(err)
}

// openLog opens the log file for appending after creating its folder. A log
// file inside lockedDir is not opened when locking that folder failed with
// lockErr, and a log file that is a reparse point is not opened.
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
	return os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
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

func mask(t string) string {
	if len(t) < 8 {
		return "(none)"
	}
	return t[:4] + "..." + t[len(t)-4:]
}

// writeInstallLog appends the install result to install.log in dir, where the
// result of a build without a console can be read afterwards. It does nothing
// when the file is a reparse point.
func writeInstallLog(dir, msg string) {
	path := filepath.Join(dir, "install.log")
	_ = os.MkdirAll(dir, 0o755)
	if refuseReparse(path) != nil {
		return
	}
	if f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644); err == nil {
		fmt.Fprintf(f, "%s %s\n", timeNow(), msg)
		f.Close()
	}
}

func timeNow() string { return time.Now().Format(time.RFC3339) }
