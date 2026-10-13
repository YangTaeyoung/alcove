package mitm

import (
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestRuleMatchByHostPathMethod(t *testing.T) {
	cases := []struct {
		name               string
		match              ruleMatch
		host, path, method string
		want               bool
	}{
		{"empty matches all", ruleMatch{}, "a.com", "/x", "GET", true},
		{"host glob", ruleMatch{Host: "*.openai.com"}, "api.openai.com", "/v1", "POST", true},
		{"host glob miss", ruleMatch{Host: "*.openai.com"}, "openai.org", "/v1", "POST", false},
		{"host case-insensitive", ruleMatch{Host: "API.example.com"}, "api.EXAMPLE.com", "/", "GET", true},
		{"path star crosses slash", ruleMatch{Path: "/v1/*"}, "h", "/v1/chat/completions", "POST", true},
		{"path exact miss", ruleMatch{Path: "/v1"}, "h", "/v1/x", "GET", false},
		{"path middle star", ruleMatch{Path: "/a/*/c"}, "h", "/a/b/x/c", "GET", true},
		{"method case-insensitive", ruleMatch{Method: "post"}, "h", "/", "POST", true},
		{"method miss", ruleMatch{Method: "POST"}, "h", "/", "GET", false},
		{"all three", ruleMatch{Host: "h", Path: "/p*", Method: "PUT"}, "h", "/pq", "PUT", true},
		{"all three one off", ruleMatch{Host: "h", Path: "/p*", Method: "PUT"}, "h", "/q", "PUT", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := c.match.fits(c.host, c.path, c.method); got != c.want {
				t.Fatalf("fits = %v, want %v", got, c.want)
			}
		})
	}
}

func TestRuleStatusAndBody(t *testing.T) {
	upstreamHits := atomic.Int32{}
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		upstreamHits.Add(1)
	}))
	defer up.Close()
	env := newEnv(t)
	res := env.call("rule.add", map[string]any{
		"match":  map[string]any{"path": "/v1/*"},
		"action": map[string]any{"status": 429, "body": `{"error":"slow down"}`, "headers": map[string]any{"Retry-After": "7"}},
	})
	if int(res["rule"].(float64)) != 1 {
		t.Fatalf("rule id %v", res["rule"])
	}
	resp, err := env.client.Get(up.URL + "/v1/chat")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 429 || string(body) != `{"error":"slow down"}` {
		t.Fatalf("got %d %q", resp.StatusCode, body)
	}
	if resp.Header.Get("Retry-After") != "7" || resp.Header.Get("Content-Type") != "application/json" {
		t.Fatalf("headers %v", resp.Header)
	}
	if upstreamHits.Load() != 0 {
		t.Fatal("the upstream was contacted")
	}
	x := env.waitExchange(func(x map[string]any) bool { return x["rule"] != nil })
	if int(x["rule"].(float64)) != 1 || int(x["status"].(float64)) != 429 {
		t.Fatalf("exchange %v", x)
	}
	resp, err = env.client.Get(up.URL + "/other")
	if err != nil || resp.StatusCode != 200 || upstreamHits.Load() != 1 {
		t.Fatalf("non-matching request: %v %v hits=%d", resp, err, upstreamHits.Load())
	}
	resp.Body.Close()
}

func TestRuleBodyOnlyDefaultsToTextPlain(t *testing.T) {
	up := httptest.NewServer(http.NotFoundHandler())
	defer up.Close()
	env := newEnv(t)
	env.call("rule.add", map[string]any{"action": map[string]any{"body": "hello"}})
	resp, err := env.client.Get(up.URL + "/")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 || resp.Header.Get("Content-Type") != "text/plain; charset=utf-8" {
		t.Fatalf("got %d %v", resp.StatusCode, resp.Header)
	}
}

func TestRuleDelayThenForward(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "real") }))
	defer up.Close()
	env := newEnv(t)
	env.call("rule.add", map[string]any{"action": map[string]any{"delayMs": 300}})
	start := time.Now()
	resp, err := env.client.Get(up.URL + "/")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if string(body) != "real" {
		t.Fatalf("body %q", body)
	}
	if d := time.Since(start); d < 300*time.Millisecond {
		t.Fatalf("answered after %v", d)
	}
}

func TestRuleDrop(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "real") }))
	defer up.Close()
	env := newEnv(t)
	env.call("rule.add", map[string]any{"action": map[string]any{"drop": true}})
	resp, err := env.client.Get(up.URL + "/")
	if err == nil {
		resp.Body.Close()
		t.Fatalf("expected a transport error, got %d", resp.StatusCode)
	}
	x := env.waitExchange(func(x map[string]any) bool { return x["rule"] != nil })
	if int(x["rule"].(float64)) != 1 {
		t.Fatalf("exchange %v", x)
	}
}

func TestRuleTimesIsExactUnderConcurrency(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "real") }))
	defer up.Close()
	env := newEnv(t)
	env.call("rule.add", map[string]any{"action": map[string]any{"status": 418, "times": 1}})
	var wg sync.WaitGroup
	var affected atomic.Int32
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			resp, err := env.client.Get(up.URL + "/")
			if err != nil {
				t.Error(err)
				return
			}
			resp.Body.Close()
			if resp.StatusCode == 418 {
				affected.Add(1)
			}
		}()
	}
	wg.Wait()
	if affected.Load() != 1 {
		t.Fatalf("%d requests were affected, want 1", affected.Load())
	}
	rules := env.call("rule.list", nil)["rules"].([]any)
	row := rules[0].(map[string]any)
	if row["hits"].(float64) != 1 || row["remaining"].(float64) != 0 {
		t.Fatalf("rule row %v", row)
	}
}

func TestRuleRemoveAndClear(t *testing.T) {
	env := newEnv(t)
	a := int(env.call("rule.add", map[string]any{"action": map[string]any{"status": 500}})["rule"].(float64))
	env.call("rule.add", map[string]any{"match": map[string]any{"host": "x"}, "action": map[string]any{"drop": true}})
	if n := len(env.call("rule.list", nil)["rules"].([]any)); n != 2 {
		t.Fatalf("%d rules", n)
	}
	env.call("rule.remove", map[string]any{"rule": a})
	rules := env.call("rule.list", nil)["rules"].([]any)
	if len(rules) != 1 || rules[0].(map[string]any)["id"].(float64) == float64(a) {
		t.Fatalf("rules after remove %v", rules)
	}
	if _, err := env.proxy.Handle("rule.remove", map[string]any{"rule": a}); err == nil {
		t.Fatal("removing a missing rule should fail")
	}
	env.call("rule.clear", nil)
	if n := len(env.call("rule.list", nil)["rules"].([]any)); n != 0 {
		t.Fatalf("%d rules after clear", n)
	}
}

func TestRuleAddValidation(t *testing.T) {
	env := newEnv(t)
	bad := []map[string]any{
		{},
		{"action": map[string]any{}},
		{"action": map[string]any{"status": "x"}},
		{"action": map[string]any{"status": 99}},
		{"action": map[string]any{"status": 100}},
		{"action": map[string]any{"status": 600}},
		{"action": map[string]any{"delayMs": 600001}},
		{"action": map[string]any{"delayMs": -1}},
		{"action": map[string]any{"headers": map[string]any{"a": "b"}}},
		{"action": map[string]any{"drop": true}, "match": "x"},
	}
	for _, p := range bad {
		if _, err := env.proxy.Handle("rule.add", p); err == nil {
			t.Errorf("rule.add(%v) should fail", p)
		}
	}
}
