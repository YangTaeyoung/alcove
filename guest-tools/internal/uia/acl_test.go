package uia

import "testing"

func TestIsLockedSDDL(t *testing.T) {
	cases := []struct {
		sddl string
		want bool
	}{
		{"O:BAD:P(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)", true},
		{"O:BAD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)", true},
		{"O:SYG:SYD:P(A;OICI;0x1f01ff;;;BA)(A;OICI;FA;;;SY)", true},
		{lockedSDDL, true},
		{"O:BAD:(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)", false},
		{"O:BAD:AI(A;OICIID;FA;;;BA)(A;OICIID;FA;;;SY)", false},
		{"O:BAD:P(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)(A;OICI;0x1200a9;;;BU)", false},
		{"O:BAD:P(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)(A;OICIIO;GA;;;CO)", false},
		{"O:BAD:P(A;OICI;FA;;;BA)", false},
		{"O:BAD:P(A;OICI;FA;;;BA)(A;OICI;FA;;;BA)", false},
		{"O:BAD:P(A;;FA;;;BA)(A;OICI;FA;;;SY)", false},
		{"O:BAD:P(A;OICI;0x1200a9;;;BA)(A;OICI;FA;;;SY)", false},
		{"O:BAD:P(D;OICI;FA;;;BA)(A;OICI;FA;;;SY)", false},
		{"O:S-1-5-21-1-2-3-1001D:P(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)", false},
		{"O:BAD:P", false},
		{"D:P(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)", false},
		{"", false},
	}
	for _, c := range cases {
		if got := isLockedSDDL(c.sddl); got != c.want {
			t.Errorf("isLockedSDDL(%q) = %v, expected %v", c.sddl, got, c.want)
		}
	}
}
