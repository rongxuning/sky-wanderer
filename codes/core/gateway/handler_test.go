package gateway

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"skywanderer/codes/user"
)

func TestAuthHTTP(t *testing.T) {
	repo := user.NewMemoryRepository(nil)
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	auth := user.NewService(user.ServiceOptions{
		Repo: repo,
		Demo: true,
		Now:  func() time.Time { return now },
	})
	handler := NewHandler(auth, func(context.Context) error { return repo.Ping(context.Background()) })

	t.Run("health", func(t *testing.T) {
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/health", nil))
		if rec.Code != 200 || strings.TrimSpace(rec.Body.String()) != `{"ok":true}` {
			t.Fatalf("%d %s", rec.Code, rec.Body.String())
		}
	})

	t.Run("demo code merge logout", func(t *testing.T) {
		sent := postJSON(t, handler, "/v1/auth/phone/send-code", map[string]any{"phone": "13800138000"}, "")
		if sent.Code != 200 || sent.JSON["phone"] != "+8613800138000" || sent.JSON["demoCode"] != user.DemoCode {
			t.Fatalf("%d %#v", sent.Code, sent.JSON)
		}
		earlier := postJSON(t, handler, "/v1/auth/login", map[string]any{
			"type": "wechat", "providerSubject": "openid-http-early", "displayName": "HTTP 早",
		}, "")
		if earlier.Code != 200 {
			t.Fatal(earlier.Body)
		}
		if !strings.Contains(earlier.Body, `"retiredAt":null`) || !strings.Contains(earlier.Body, `"mergedFromUserIds":[]`) {
			t.Fatalf("user json %s", earlier.Body)
		}
		earlierUser := earlier.JSON["user"].(map[string]any)
		now = now.Add(time.Second)
		later := postJSON(t, handler, "/v1/auth/login", map[string]any{
			"type": "phone", "providerSubject": "13800138000", "demoCode": user.DemoCode, "displayName": "HTTP 晚",
		}, "")
		laterSession := later.JSON["session"].(map[string]any)
		token := laterSession["token"].(string)
		merged := postJSON(t, handler, "/v1/auth/bind", map[string]any{
			"type": "wechat", "providerSubject": "openid-http-early",
		}, token)
		if merged.Code != 200 || merged.JSON["merged"] != true {
			t.Fatalf("%d %#v", merged.Code, merged.JSON)
		}
		if merged.JSON["user"].(map[string]any)["id"] != earlierUser["id"] {
			t.Fatalf("user %#v", merged.JSON["user"])
		}
		if len(merged.JSON["identities"].([]any)) != 2 {
			t.Fatalf("identities %#v", merged.JSON["identities"])
		}
		removed := doJSON(t, handler, http.MethodDelete, "/v1/auth/identities", map[string]any{
			"type": "phone", "providerSubject": "+8613800138000",
		}, token)
		if removed.Code != 200 {
			t.Fatalf("%d %s", removed.Code, removed.Body)
		}
		blocked := doJSON(t, handler, http.MethodDelete, "/v1/auth/identities", map[string]any{
			"type": "wechat", "providerSubject": "openid-http-early",
		}, token)
		if blocked.Code != 409 || blocked.JSON["error"].(map[string]any)["code"] != "last_identity" {
			t.Fatalf("%d %#v", blocked.Code, blocked.JSON)
		}
		loggedOut := doJSON(t, handler, http.MethodPost, "/v1/auth/logout", nil, token)
		if loggedOut.Code != 204 || loggedOut.Body != "" {
			t.Fatalf("%d %q", loggedOut.Code, loggedOut.Body)
		}
		after := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, "/v1/auth/identities", nil)
		req.Header.Set("authorization", "Bearer "+token)
		handler.ServeHTTP(after, req)
		if after.Code != 401 {
			t.Fatalf("%d %s", after.Code, after.Body.String())
		}
	})

	t.Run("bad demo code", func(t *testing.T) {
		response := postJSON(t, handler, "/v1/auth/login", map[string]any{
			"type": "phone", "providerSubject": "+8613900139000", "demoCode": "nope",
		}, "")
		if response.Code != 400 || response.JSON["error"].(map[string]any)["code"] != "invalid_demo_code" {
			t.Fatalf("%d %#v", response.Code, response.JSON)
		}
	})

	t.Run("callbacks", func(t *testing.T) {
		wechat := httptest.NewRecorder()
		handler.ServeHTTP(wechat, httptest.NewRequest(http.MethodGet, "/v1/auth/wechat/callback?code=abc&state=s1", nil))
		if wechat.Code != 302 || wechat.Header().Get("location") != "skywanderer://auth/wechat?code=abc&state=s1" {
			t.Fatalf("%d %s", wechat.Code, wechat.Header().Get("location"))
		}
		google := httptest.NewRecorder()
		handler.ServeHTTP(google, httptest.NewRequest(http.MethodGet, "/v1/auth/google/callback?error=access_denied&state=s2", nil))
		location := google.Header().Get("location")
		if google.Code != 302 || !strings.HasPrefix(location, "skywanderer://auth/google?") || !strings.Contains(location, "error=access_denied") || !strings.Contains(location, "state=s2") {
			t.Fatalf("%d %s", google.Code, location)
		}
	})

	t.Run("production rejects client openid", func(t *testing.T) {
		before, err := repo.ListUsers(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		strict := NewHandler(user.NewService(user.ServiceOptions{Repo: repo, Demo: false}), nil)
		response := postJSON(t, strict, "/v1/auth/login", map[string]any{"type": "wechat", "providerSubject": "client-openid"}, "")
		if response.Code != 400 || response.JSON["error"].(map[string]any)["code"] != "invalid_subject" {
			t.Fatalf("%d %#v", response.Code, response.JSON)
		}
		after, err := repo.ListUsers(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		if len(after) != len(before) {
			t.Fatalf("users %d -> %d", len(before), len(after))
		}
	})
}

func TestHealthUnavailable(t *testing.T) {
	auth := user.NewService(user.ServiceOptions{Repo: user.NewMemoryRepository(nil), Demo: true})
	handler := NewHandler(auth, func(context.Context) error {
		return &user.AuthError{Code: "db_unavailable", Message: "database is unavailable"}
	})
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/health", nil))
	if rec.Code != 503 || !strings.Contains(rec.Body.String(), `"db_unavailable"`) {
		t.Fatalf("%d %s", rec.Code, rec.Body.String())
	}
}

type recorded struct {
	Code int
	Body string
	JSON map[string]any
}

func postJSON(t *testing.T, handler http.Handler, path string, body map[string]any, token string) recorded {
	t.Helper()
	return doJSON(t, handler, http.MethodPost, path, body, token)
}

func doJSON(t *testing.T, handler http.Handler, method, path string, body map[string]any, token string) recorded {
	t.Helper()
	var reader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		reader = bytes.NewReader(raw)
	}
	req := httptest.NewRequest(method, path, reader)
	if body != nil {
		req.Header.Set("content-type", "application/json")
	}
	if token != "" {
		req.Header.Set("authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	out := recorded{Code: rec.Code, Body: rec.Body.String()}
	if out.Body != "" {
		_ = json.Unmarshal([]byte(out.Body), &out.JSON)
	}
	return out
}
