package main

import (
	"errors"
	"testing"
)

func TestInstallErrorsNameTheNextStep(t *testing.T) {
	dst := `C:\Program Files\Alcove\alcove-agent.exe`
	cases := []struct {
		got  error
		want string
	}{
		{copyError(dst, errors.New("Access is denied.")),
			`could not write C:\Program Files\Alcove\alcove-agent.exe (Access is denied.); delete C:\Program Files\Alcove\alcove-agent.exe, then run alcove-agent --install again from an elevated prompt`},
		{copyCheckError(dst, 10, 20, nil),
			`the copy at C:\Program Files\Alcove\alcove-agent.exe holds 10 bytes instead of 20; delete C:\Program Files\Alcove\alcove-agent.exe, then run alcove-agent --install again from an elevated prompt`},
		{copyCheckError(dst, 0, 20, errors.New("The system cannot find the file specified.")),
			`the copy at C:\Program Files\Alcove\alcove-agent.exe could not be checked (The system cannot find the file specified.); delete C:\Program Files\Alcove\alcove-agent.exe, then run alcove-agent --install again from an elevated prompt`},
		{taskCreateError(errors.New("exit status 1"), []byte("ERROR: Access is denied.\r\n")),
			`the scheduled task AlcoveAgent could not be created (exit status 1: ERROR: Access is denied.); run alcove-agent --install again from an elevated prompt`},
		{firewallError(7645, errors.New("exit status 1"), []byte("The requested operation requires elevation (Run as administrator).\r\n")),
			`the firewall rule AlcoveAgent for TCP port 7645 could not be added (exit status 1: The requested operation requires elevation (Run as administrator).); run alcove-agent --install again from an elevated prompt`},
		{taskRunError(errors.New("exit status 1"), []byte("ERROR: The task is disabled.\r\n")),
			`the scheduled task AlcoveAgent was created but did not start (exit status 1: ERROR: The task is disabled.); start it with schtasks /Run /TN AlcoveAgent, or sign out and in again`},
		{selfError(errors.New("not found")),
			`the path of this alcove-agent.exe could not be read (not found); run alcove-agent --install again from the folder that holds alcove-agent.exe`},
		{selfReadError(`D:\alcove-agent.exe`, errors.New("The device is not ready.")),
			`D:\alcove-agent.exe could not be read (The device is not ready.); copy alcove-agent.exe to a local folder and run alcove-agent --install from there`},
	}
	for _, c := range cases {
		if c.got == nil || c.got.Error() != c.want {
			t.Errorf("got  %v\nwant %s", c.got, c.want)
		}
	}
}
