package main

import (
	"fmt"
	"strings"
)

// elevatedRerun is the next step of an --install failure that an elevated
// prompt resolves.
const elevatedRerun = "run alcove-agent --install again from an elevated prompt"

// selfError is the error of --install when the path of the running program
// cannot be read.
func selfError(err error) error {
	return fmt.Errorf("the path of this alcove-agent.exe could not be read (%v); run alcove-agent --install again from the folder that holds alcove-agent.exe", err)
}

// selfReadError is the error of --install when the running program at path
// cannot be read for the copy.
func selfReadError(path string, err error) error {
	return fmt.Errorf("%s could not be read (%v); copy alcove-agent.exe to a local folder and run alcove-agent --install from there", path, err)
}

// copyError is the error of --install when the program cannot be written to
// dst.
func copyError(dst string, err error) error {
	return fmt.Errorf("could not write %s (%v); delete %s, then %s", dst, err, dst, elevatedRerun)
}

// copyCheckError is the error of --install when the copy at dst holds size
// bytes instead of want, or statErr kept it from being checked.
func copyCheckError(dst string, size, want int64, statErr error) error {
	what := fmt.Sprintf("the copy at %s holds %d bytes instead of %d", dst, size, want)
	if statErr != nil {
		what = fmt.Sprintf("the copy at %s could not be checked (%v)", dst, statErr)
	}
	return fmt.Errorf("%s; delete %s, then %s", what, dst, elevatedRerun)
}

// taskCreateError is the error of --install when schtasks /Create failed
// with err and printed out.
func taskCreateError(err error, out []byte) error {
	return commandError("the scheduled task AlcoveAgent could not be created", err, out, elevatedRerun)
}

// firewallError is the error of --install when netsh failed to add the rule
// for port with err and printed out.
func firewallError(port int, err error, out []byte) error {
	return commandError(fmt.Sprintf("the firewall rule AlcoveAgent for TCP port %d could not be added", port), err, out, elevatedRerun)
}

// taskRunError is the error of --install when schtasks /Run failed with err
// and printed out.
func taskRunError(err error, out []byte) error {
	return commandError("the scheduled task AlcoveAgent was created but did not start", err, out, "start it with schtasks /Run /TN AlcoveAgent, or sign out and in again")
}

// commandError is what failed, the command's error and output, and next.
func commandError(what string, err error, out []byte, next string) error {
	return fmt.Errorf("%s (%v: %s); %s", what, err, strings.TrimSpace(string(out)), next)
}
