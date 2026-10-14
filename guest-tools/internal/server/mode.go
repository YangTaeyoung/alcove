package server

import "math"

// nearestMode picks the offered mode closest to w x h: exact if available,
// otherwise the one with the lowest score of distance, a penalty for a mode
// larger than the request in either dimension, and aspect difference. It
// answers false when no mode is offered.
func nearestMode(w, h int, modes [][2]int) (int, int, bool) {
	best, bestScore := [2]int{}, math.MaxFloat64
	for _, m := range modes {
		if m[0] == w && m[1] == h {
			return w, h, true
		}
		dw, dh := float64(m[0]-w), float64(m[1]-h)
		penalty := 0.0
		if m[0] > w || m[1] > h {
			penalty = 400
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
