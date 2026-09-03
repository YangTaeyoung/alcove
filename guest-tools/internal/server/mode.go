package server

import "math"

// nearestMode picks the offered mode closest to w x h: exact if available,
// otherwise the largest that fits inside the request, otherwise the smallest
// mode overall. Virtio's Windows driver (viogpudo) rejects arbitrary sizes and
// behaves erratically when asked for one, so the agent never asks for a size
// the driver has not offered.
func nearestMode(w, h int, modes [][2]int) (int, int, bool) {
	best, bestScore := [2]int{}, math.MaxFloat64
	for _, m := range modes {
		if m[0] == w && m[1] == h {
			return w, h, true
		}
		// prefer modes that fit inside the request and match its aspect
		dw, dh := float64(m[0]-w), float64(m[1]-h)
		penalty := 0.0
		if m[0] > w || m[1] > h {
			penalty = 400 // overshooting means scrollbars or a cropped view
		}
		aspect := math.Abs(float64(m[0])/float64(m[1]) - float64(w)/float64(h))
		score := math.Sqrt(dw*dw+dh*dh) + penalty + aspect*800
		if score < bestScore {
			best, bestScore = m, score
		}
	}
	if bestScore == math.MaxFloat64 {
		return 0, 0, false
	}
	return best[0], best[1], true
}
