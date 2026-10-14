package mitm

import (
	"bytes"
	"strings"
	"testing"
)

func TestInFlightBodiesShareTheBudget(t *testing.T) {
	s := newStore(10)
	s.budget = 100
	a, b := s.newCapBuf(true), s.newCapBuf(true)
	a.Write(bytes.Repeat([]byte("a"), 60))
	b.Write(bytes.Repeat([]byte("b"), 60))
	b.Write([]byte("0123456789"))
	if s.inflight != 100 {
		t.Fatalf("in flight %d, want 100", s.inflight)
	}
	data, total, truncated := b.snapshot()
	if string(data) != strings.Repeat("b", 40) || total != 70 || !truncated {
		t.Fatalf("second body kept %q of %d, truncated %v", data, total, truncated)
	}
	aData, _, _ := a.snapshot()
	s.add(&Exchange{URL: "http://h/a", ReqBody: aData, held: int64(len(aData))})
	s.add(&Exchange{URL: "http://h/b", ResBody: data, held: int64(len(data))})
	if s.inflight != 0 || s.used != 100 {
		t.Fatalf("in flight %d, used %d", s.inflight, s.used)
	}
}

func TestInFlightBodyDropsTheOldestStoredBodies(t *testing.T) {
	s := newStore(10)
	s.budget = 100
	s.add(&Exchange{URL: "http://h/old", ResBody: bytes.Repeat([]byte("o"), 80)})
	c := s.newCapBuf(true)
	c.Write(bytes.Repeat([]byte("n"), 50))
	if data, _, truncated := c.snapshot(); len(data) != 50 || truncated {
		t.Fatalf("kept %d bytes, truncated %v", len(data), truncated)
	}
	if old, _ := s.get(1); !old.BodyDropped || old.ResBody != nil {
		t.Fatalf("the stored row kept its body: %+v", old)
	}
}

func TestStopKeepingReleasesTheReservation(t *testing.T) {
	s := newStore(10)
	c := s.newCapBuf(true)
	c.Write([]byte("frame"))
	c.stopKeeping()
	c.Write([]byte("more"))
	if s.inflight != 0 || c.count() != 9 {
		t.Fatalf("in flight %d, count %d", s.inflight, c.count())
	}
}

func TestHeadersBeyondTheCapAreLeftOutAndCounted(t *testing.T) {
	env := newEnv(t)
	big := strings.Repeat("v", 40<<10)
	env.proxy.record(&Exchange{Kind: "http", URL: "http://h/", Status: 200,
		ReqHeaders: [][2]string{{"X-A", big}, {"X-B", big}},
		ResHeaders: [][2]string{{"X-C", "small"}}})
	req := env.get(1, "request", nil)
	if req["headersTruncated"] != true || len(req["headers"].([]any)) != 1 || headerMap(req)["X-A"] != big {
		t.Fatalf("request headers %v truncated %v", len(req["headers"].([]any)), req["headersTruncated"])
	}
	if headerMap(env.get(1, "response", nil))["X-C"] != "small" {
		t.Fatal("the response headers were left out")
	}
	if want := int64(len("X-A") + len(big) + len("X-C") + len("small")); env.proxy.store.used != want {
		t.Fatalf("used %d, want %d", env.proxy.store.used, want)
	}
}

func TestWritesAfterSnapshotReserveNothing(t *testing.T) {
	s := newStore(10)
	c := s.newCapBuf(true)
	c.Write([]byte("abc"))
	data, total, truncated := c.snapshot()
	if string(data) != "abc" || total != 3 || truncated {
		t.Fatalf("snapshot %q of %d, truncated %v", data, total, truncated)
	}
	s.add(&Exchange{URL: "http://h/a", ReqBody: data, held: int64(len(data))})
	c.Write([]byte("defgh"))
	if s.inflight != 0 || c.count() != 8 {
		t.Fatalf("in flight %d, count %d", s.inflight, c.count())
	}
}
