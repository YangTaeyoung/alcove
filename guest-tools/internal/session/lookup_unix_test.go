//go:build !windows

package session

import (
	"errors"
	"testing"
	"time"
)

func TestAFailedVersionReadIsRetriedAfterAMinuteAndLoggedOnce(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	reads, logs := 0, 0
	fail := true
	c := &versionCache{
		read: func(string) (string, error) {
			reads++
			if fail {
				return "", errors.New("exit status 1")
			}
			return "systemd 259 (259.5-0ubuntu3.4)\n", nil
		},
		now:  func() time.Time { return now },
		logf: func(string, ...any) { logs++ },
	}
	if v := c.get("/usr/bin/systemd-run"); v != 0 || reads != 1 || logs != 1 {
		t.Fatalf("first read: version %d, %d reads, %d logs", v, reads, logs)
	}
	now = now.Add(30 * time.Second)
	if v := c.get("/usr/bin/systemd-run"); v != 0 || reads != 1 {
		t.Fatalf("within a minute: version %d, %d reads", v, reads)
	}
	now = now.Add(31 * time.Second)
	if v := c.get("/usr/bin/systemd-run"); v != 0 || reads != 2 || logs != 1 {
		t.Fatalf("after a minute: version %d, %d reads, %d logs", v, reads, logs)
	}
	fail = false
	now = now.Add(61 * time.Second)
	if v := c.get("/usr/bin/systemd-run"); v != 259 || reads != 3 {
		t.Fatalf("after the tool works: version %d, %d reads", v, reads)
	}
	now = now.Add(time.Hour)
	if v := c.get("/usr/bin/systemd-run"); v != 259 || reads != 3 {
		t.Fatalf("a read version is kept: version %d, %d reads", v, reads)
	}
}
