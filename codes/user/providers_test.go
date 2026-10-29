package user

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"math/big"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"
)

func TestLoadConfigRequiresDatabaseUnlessDemo(t *testing.T) {
	_, err := LoadConfig(func(string) string { return "" })
	if err == nil || !strings.Contains(err.Error(), "DATABASE_URL is required unless AUTH_DEMO=1") {
		t.Fatal(err)
	}
	cfg, err := LoadConfig(func(key string) string {
		if key == "AUTH_DEMO" {
			return "1"
		}
		return ""
	})
	if err != nil {
		t.Fatal(err)
	}
	if cfg.APIHost != "api.sky-wanderer.online" || !cfg.Demo || cfg.DatabaseURL != "" {
		t.Fatalf("%#v", cfg)
	}
	if len(cfg.GoogleRedirectURIs) != 1 || cfg.GoogleRedirectURIs[0] != "https://api.sky-wanderer.online/v1/auth/google/callback" {
		t.Fatalf("%#v", cfg.GoogleRedirectURIs)
	}
}

func TestAliyunSMSSignature(t *testing.T) {
	var bodies []string
	sender := NewSMSSender(SMSConfig{
		Provider:              "aliyun",
		AliyunAccessKeyID:     "testid",
		AliyunAccessKeySecret: "testsecret",
		AliyunSignName:        "Sky",
		AliyunTemplateCode:    "SMS_1",
	}, func(_ context.Context, rawURL string, init *FetchInit) (*http.Response, error) {
		if rawURL != "https://dysmsapi.aliyuncs.com/" {
			t.Fatalf("url %s", rawURL)
		}
		if init != nil {
			bodies = append(bodies, init.Body)
		}
		return jsonResponse(200, map[string]string{"Code": "OK"}), nil
	}, func() time.Time { return time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC) }, func() string { return "nonce-fixed" })
	if err := sender.Send(context.Background(), "+8613800138000", "123456"); err != nil {
		t.Fatal(err)
	}
	params, err := url.ParseQuery(bodies[0])
	if err != nil {
		t.Fatal(err)
	}
	if params.Get("Action") != "SendSms" || params.Get("PhoneNumbers") != "+8613800138000" || params.Get("TemplateParam") != `{"code":"123456"}` {
		t.Fatalf("%v", params)
	}
	if params.Get("Signature") != "yVp1wrLrs7j9JPJBF/iTAHOM1Og=" {
		t.Fatalf("signature %s", params.Get("Signature"))
	}
	missing := NewSMSSender(SMSConfig{Provider: "http"}, DefaultFetch, nil, nil)
	if missing == nil {
		t.Fatal("expected failing sender")
	}
	if err := missing.Send(context.Background(), "+8613800138000", "123456"); !codeIs(err, "sms_not_configured") {
		t.Fatal(err)
	}
	if NewSMSSender(SMSConfig{}, DefaultFetch, nil, nil) != nil {
		t.Fatal("empty provider should not send")
	}
}

func TestVerifyGoogleIDToken(t *testing.T) {
	keys := googleKey(t)
	certs := map[string]JWK{keys.jwk.Kid: keys.jwk}
	token := signJWT(t, keys.key, map[string]any{
		"iss":            "https://accounts.google.com",
		"aud":            "client.apps.googleusercontent.com",
		"sub":            "sub-1",
		"exp":            2_000_000_000,
		"email":          "walker@example.com",
		"email_verified": true,
	})
	claims, err := verifyGoogleIDToken(token, certs, []string{"client.apps.googleusercontent.com"}, time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	if claims.Sub != "sub-1" || claims.Email != "walker@example.com" {
		t.Fatalf("%#v", claims)
	}
	parts := strings.Split(token, ".")
	tampered := parts[0] + "." + base64.RawURLEncoding.EncodeToString([]byte("{}")) + "." + parts[2]
	_, err = verifyGoogleIDToken(tampered, certs, []string{"client.apps.googleusercontent.com"}, time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC))
	if !codeIs(err, "invalid_id_token") {
		t.Fatal(err)
	}
}

type testKey struct {
	key *rsa.PrivateKey
	jwk JWK
}

func googleKey(t *testing.T) testKey {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	return testKey{key: key, jwk: publicJWK(&key.PublicKey)}
}

func publicJWK(pub *rsa.PublicKey) JWK {
	return JWK{
		Kty: "RSA",
		N:   base64.RawURLEncoding.EncodeToString(pub.N.Bytes()),
		E:   base64.RawURLEncoding.EncodeToString(big.NewInt(int64(pub.E)).Bytes()),
		Kid: "test-key",
		Alg: "RS256",
		Use: "sig",
	}
}

func signJWT(t *testing.T, key *rsa.PrivateKey, payload map[string]any) string {
	t.Helper()
	header, err := json.Marshal(map[string]string{"alg": "RS256", "typ": "JWT", "kid": "test-key"})
	if err != nil {
		t.Fatal(err)
	}
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	encoded := base64.RawURLEncoding.EncodeToString(header) + "." + base64.RawURLEncoding.EncodeToString(body)
	sum := sha256.Sum256([]byte(encoded))
	sig, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, sum[:])
	if err != nil {
		t.Fatal(err)
	}
	return encoded + "." + base64.RawURLEncoding.EncodeToString(sig)
}

func jsonResponse(status int, body any) *http.Response {
	raw, _ := json.Marshal(body)
	return &http.Response{
		StatusCode: status,
		Status:     http.StatusText(status),
		Body:       io.NopCloser(strings.NewReader(string(raw))),
		Header:     make(http.Header),
	}
}
