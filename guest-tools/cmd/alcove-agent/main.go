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

	logger := log.Default()
	if *logPath != "" {
		_ = os.MkdirAll(filepath.Dir(*logPath), 0o755)
		if err := refuseReparse(*logPath); err != nil {
			fmt.Fprintln(os.Stderr, "log:", err)
		} else if f, err := os.OpenFile(*logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644); err == nil {
			logger = log.New(f, "", log.LstdFlags)
		}
	}
	if *install {
		if err := installAtLogon(*port, *allowExec); err != nil {
			fmt.Fprintln(os.Stderr, "install failed:", err)
			writeInstallLog("install failed: " + err.Error())
			os.Exit(1)
		}
		fmt.Println("installed")
		writeInstallLog("installed")
		return
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
		base := os.Getenv("ProgramData")
		if base == "" {
			base = os.TempDir()
		}
		alcoveDir := filepath.Join(base, "Alcove")
		uiaDir := filepath.Join(alcoveDir, "uia")
		if err := uia.LockHelperFolders(alcoveDir, uiaDir); err != nil {
			logger.Printf("the helper folders are not locked (%v); the UI helper will not start until they can be locked", err)
		}
		helper := uia.New(uia.DefaultLauncher(uiaDir),
			func(name string, fields map[string]any) { s.HandleUIEvent(name, fields) })
		helper.SetLogger(logger)
		helper.SetLogPath(filepath.Join(uiaDir, "helper.log"))
		ui = helper
	}
	s = server.New(server.Options{Token: *tok, AllowExec: *allowExec, Logger: logger, UI: ui})
	defer s.Close()
	logger.Fatal(s.Serve(l))
}

func mask(t string) string {
	if len(t) < 8 {
		return "(none)"
	}
	return t[:4] + "..." + t[len(t)-4:]
}

// writeInstallLog records the install result where a GUI-subsystem build can be
// inspected afterwards (stdout/stderr are invisible on Windows).
func writeInstallLog(msg string) {
	dir := os.Getenv("ProgramData")
	if dir == "" {
		dir = os.TempDir()
	}
	path := filepath.Join(dir, "Alcove", "install.log")
	_ = os.MkdirAll(filepath.Dir(path), 0o755)
	if refuseReparse(path) != nil {
		return
	}
	if f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644); err == nil {
		fmt.Fprintf(f, "%s %s\n", timeNow(), msg)
		f.Close()
	}
}

func timeNow() string { return time.Now().Format(time.RFC3339) }
