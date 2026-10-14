package clipboard

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestSerialCallsDoNotOverlap(t *testing.T) {
	var running, most atomic.Int32
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			got, err := serial(func() (int, error) {
				n := running.Add(1)
				for {
					m := most.Load()
					if n <= m || most.CompareAndSwap(m, n) {
						break
					}
				}
				time.Sleep(2 * time.Millisecond)
				running.Add(-1)
				return i, nil
			})
			if err != nil || got != i {
				t.Errorf("call %d returned %d, %v", i, got, err)
			}
		}(i)
	}
	wg.Wait()
	if most.Load() != 1 {
		t.Fatalf("%d calls ran at once", most.Load())
	}
}
