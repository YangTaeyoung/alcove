package server

import "testing"

func TestNearestMode(t *testing.T) {
	modes := [][2]int{{640, 480}, {800, 600}, {1024, 768}, {1280, 800}, {1440, 900}, {1920, 1080}, {2560, 1440}, {5120, 2160}}
	cases := []struct{ w, h, wantW, wantH int }{
		{1440, 900, 1440, 900},   // exact
		{1450, 910, 1440, 900},   // just above an offered mode
		{1300, 820, 1280, 800},   // between modes, fits inside
		{300, 200, 640, 480},     // below everything: smallest sensible
		{4000, 2000, 2560, 1440}, // large request, no exact mode
	}
	for _, c := range cases {
		w, h, ok := nearestMode(c.w, c.h, modes)
		if !ok || w != c.wantW || h != c.wantH {
			t.Errorf("nearestMode(%d,%d) = %d,%d (ok=%v), want %d,%d", c.w, c.h, w, h, ok, c.wantW, c.wantH)
		}
	}
	if _, _, ok := nearestMode(800, 600, nil); ok {
		t.Error("no modes offered should report failure")
	}
}
