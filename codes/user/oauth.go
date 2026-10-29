package user

import (
	"context"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

type OAuthProfile struct {
	Subject     string
	Email       string
	DisplayName string
}

type JWK struct {
	Kty string `json:"kty"`
	N   string `json:"n"`
	E   string `json:"e"`
	Kid string `json:"kid"`
	Alg string `json:"alg"`
	Use string `json:"use"`
}

type WeChatApp struct {
	AppID     string
	AppSecret string
}

func exchangeWeChat(ctx context.Context, app WeChatApp, code string, fetch Fetcher) (OAuthProfile, error) {
	if app.AppID == "" || app.AppSecret == "" {
		return OAuthProfile{}, &AuthError{Code: "wechat_not_configured", Message: "Set both WECHAT_APP_ID and WECHAT_APP_SECRET"}
	}
	if fetch == nil {
		fetch = DefaultFetch
	}
	endpoint, err := url.Parse("https://api.weixin.qq.com/sns/oauth2/access_token")
	if err != nil {
		return OAuthProfile{}, err
	}
	query := endpoint.Query()
	query.Set("appid", app.AppID)
	query.Set("secret", app.AppSecret)
	query.Set("code", code)
	query.Set("grant_type", "authorization_code")
	endpoint.RawQuery = query.Encode()
	resp, err := fetch(ctx, endpoint.String(), nil)
	if err != nil {
		return OAuthProfile{}, err
	}
	var body struct {
		OpenID      string `json:"openid"`
		AccessToken string `json:"access_token"`
		ErrCode     *int   `json:"errcode"`
		ErrMsg      string `json:"errmsg"`
	}
	decodeJSON(resp, &body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 || (body.ErrCode != nil && *body.ErrCode != 0) || body.OpenID == "" {
		return OAuthProfile{}, &AuthError{Code: "wechat_exchange_failed", Message: "WeChat did not return an openid for this authorization code"}
	}
	displayName := ""
	if body.AccessToken != "" {
		displayName = wechatNickname(ctx, body.AccessToken, body.OpenID, fetch)
	}
	return OAuthProfile{Subject: body.OpenID, DisplayName: displayName}, nil
}

func wechatNickname(ctx context.Context, accessToken, openID string, fetch Fetcher) (name string) {
	defer func() {
		if recover() != nil {
			name = ""
		}
	}()
	endpoint, err := url.Parse("https://api.weixin.qq.com/sns/userinfo")
	if err != nil {
		return ""
	}
	query := endpoint.Query()
	query.Set("access_token", accessToken)
	query.Set("openid", openID)
	query.Set("lang", "zh_CN")
	endpoint.RawQuery = query.Encode()
	resp, err := fetch(ctx, endpoint.String(), nil)
	if err != nil {
		return ""
	}
	var body struct {
		Nickname string `json:"nickname"`
		ErrCode  *int   `json:"errcode"`
	}
	decodeJSON(resp, &body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 || (body.ErrCode != nil && *body.ErrCode != 0) || strings.TrimSpace(body.Nickname) == "" {
		return ""
	}
	return strings.TrimSpace(body.Nickname)
}

type GoogleCheckInput struct {
	IDToken           string
	AuthorizationCode string
	CodeVerifier      string
	RedirectURI       string
	ClientID          string
	Nonce             string
}

type googleChecker struct {
	clientIDs    []string
	clientSecret string
	redirectURIs []string
	fetch        Fetcher
	now          func() time.Time
	loadCerts    func(context.Context) ([]JWK, error)
	mu           sync.Mutex
	cachedAt     time.Time
	cached       map[string]JWK
	hasCache     bool
}

func (g *googleChecker) check(ctx context.Context, input GoogleCheckInput) (OAuthProfile, error) {
	if len(g.clientIDs) == 0 {
		return OAuthProfile{}, &AuthError{Code: "google_not_configured", Message: "Set GOOGLE_CLIENT_IDS to the allowed Google client ids"}
	}
	idToken := strings.TrimSpace(input.IDToken)
	if idToken == "" && strings.TrimSpace(input.AuthorizationCode) != "" {
		exchanged, err := g.exchangeCode(ctx, input)
		if err != nil {
			return OAuthProfile{}, err
		}
		idToken = exchanged
	}
	if idToken == "" {
		return OAuthProfile{}, &AuthError{Code: "invalid_id_token", Message: "Google ID token is missing"}
	}
	certs, err := g.certs(ctx)
	if err != nil {
		return OAuthProfile{}, err
	}
	claims, err := verifyGoogleIDToken(idToken, certs, g.clientIDs, g.now())
	if err != nil {
		return OAuthProfile{}, err
	}
	if input.Nonce != "" && claims.Nonce != input.Nonce {
		return OAuthProfile{}, &AuthError{Code: "invalid_id_token", Message: "Google ID token nonce does not match"}
	}
	return OAuthProfile{Subject: claims.Sub, Email: claims.Email, DisplayName: claims.Name}, nil
}

func (g *googleChecker) certs(ctx context.Context) (map[string]JWK, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	now := g.now()
	if g.hasCache && now.Sub(g.cachedAt) < time.Hour {
		return g.cached, nil
	}
	var loaded []JWK
	var err error
	if g.loadCerts != nil {
		loaded, err = g.loadCerts(ctx)
	} else {
		loaded, err = fetchGoogleCerts(ctx, g.fetch)
	}
	if err != nil {
		return nil, err
	}
	byKid := map[string]JWK{}
	for _, item := range loaded {
		if item.Kid != "" {
			byKid[item.Kid] = item
		}
	}
	g.cached = byKid
	g.cachedAt = now
	g.hasCache = true
	return byKid, nil
}

func (g *googleChecker) exchangeCode(ctx context.Context, input GoogleCheckInput) (string, error) {
	clientID := strings.TrimSpace(input.ClientID)
	if clientID == "" && len(g.clientIDs) == 1 {
		clientID = g.clientIDs[0]
	}
	redirectURI := strings.TrimSpace(input.RedirectURI)
	verifier := strings.TrimSpace(input.CodeVerifier)
	if clientID == "" || !containsString(g.clientIDs, clientID) {
		return "", &AuthError{Code: "google_not_configured", Message: "Google client id is not in GOOGLE_CLIENT_IDS"}
	}
	if redirectURI == "" || !containsString(g.redirectURIs, redirectURI) {
		return "", &AuthError{Code: "invalid_subject", Message: "Google redirect URI is not allowed"}
	}
	if g.clientSecret == "" && verifier == "" {
		return "", &AuthError{Code: "google_not_configured", Message: "Set GOOGLE_CLIENT_SECRET for the web client, or send a PKCE code verifier"}
	}
	form := url.Values{}
	form.Set("code", strings.TrimSpace(input.AuthorizationCode))
	form.Set("client_id", clientID)
	form.Set("redirect_uri", redirectURI)
	form.Set("grant_type", "authorization_code")
	if g.clientSecret != "" {
		form.Set("client_secret", g.clientSecret)
	}
	if verifier != "" {
		form.Set("code_verifier", verifier)
	}
	header := make(http.Header)
	header.Set("content-type", "application/x-www-form-urlencoded")
	resp, err := g.fetch(ctx, "https://oauth2.googleapis.com/token", &FetchInit{
		Method: http.MethodPost,
		Header: header,
		Body:   form.Encode(),
	})
	if err != nil {
		return "", err
	}
	var payload struct {
		IDToken string `json:"id_token"`
	}
	decodeJSON(resp, &payload)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 || payload.IDToken == "" {
		return "", &AuthError{Code: "invalid_id_token", Message: "Google did not return an ID token for this authorization code"}
	}
	return payload.IDToken, nil
}

func fetchGoogleCerts(ctx context.Context, fetch Fetcher) ([]JWK, error) {
	if fetch == nil {
		fetch = DefaultFetch
	}
	resp, err := fetch(ctx, "https://www.googleapis.com/oauth2/v3/certs", nil)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		resp.Body.Close()
		return nil, &AuthError{Code: "invalid_id_token", Message: "Could not load Google signing keys"}
	}
	var body struct {
		Keys []JWK `json:"keys"`
	}
	decodeJSON(resp, &body)
	out := make([]JWK, 0, len(body.Keys))
	for _, key := range body.Keys {
		if key.Kid != "" {
			out = append(out, key)
		}
	}
	return out, nil
}

type googleClaims struct {
	Sub   string
	Email string
	Name  string
	Nonce string
}

func verifyGoogleIDToken(token string, certs map[string]JWK, clientIDs []string, now time.Time) (googleClaims, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 || parts[0] == "" || parts[1] == "" || parts[2] == "" {
		return googleClaims{}, &AuthError{Code: "invalid_id_token", Message: "Google ID token is malformed"}
	}
	headerRaw, err := decodeBase64URL(parts[0])
	if err != nil {
		return googleClaims{}, &AuthError{Code: "invalid_id_token", Message: "Google ID token is malformed"}
	}
	var header struct {
		Alg string `json:"alg"`
		Kid string `json:"kid"`
	}
	if err := json.Unmarshal(headerRaw, &header); err != nil {
		return googleClaims{}, &AuthError{Code: "invalid_id_token", Message: "Google ID token is malformed"}
	}
	if header.Alg != "RS256" || header.Kid == "" {
		return googleClaims{}, &AuthError{Code: "invalid_id_token", Message: "Google ID token algorithm is not RS256"}
	}
	jwk, ok := certs[header.Kid]
	if !ok {
		return googleClaims{}, &AuthError{Code: "invalid_id_token", Message: "Google signing key was not found"}
	}
	sig, err := decodeBase64URL(parts[2])
	if err != nil {
		return googleClaims{}, &AuthError{Code: "invalid_id_token", Message: "Google ID token signature is invalid"}
	}
	signingInput := []byte(parts[0] + "." + parts[1])
	if err := verifyRS256(jwk, signingInput, sig); err != nil {
		return googleClaims{}, &AuthError{Code: "invalid_id_token", Message: "Google ID token signature is invalid"}
	}
	payloadRaw, err := decodeBase64URL(parts[1])
	if err != nil {
		return googleClaims{}, &AuthError{Code: "invalid_id_token", Message: "Google ID token is malformed"}
	}
	var payload map[string]any
	if err := json.Unmarshal(payloadRaw, &payload); err != nil {
		return googleClaims{}, &AuthError{Code: "invalid_id_token", Message: "Google ID token is malformed"}
	}
	iss, _ := payload["iss"].(string)
	if iss != "https://accounts.google.com" && iss != "accounts.google.com" {
		return googleClaims{}, &AuthError{Code: "invalid_id_token", Message: "Google ID token issuer is not Google"}
	}
	if !audienceAllowed(payload["aud"], clientIDs) {
		return googleClaims{}, &AuthError{Code: "invalid_id_token", Message: "Google ID token audience does not match"}
	}
	exp, ok := asFloat(payload["exp"])
	nowMs := now.UnixMilli()
	if !ok || exp*1000 <= float64(nowMs-60_000) {
		return googleClaims{}, &AuthError{Code: "invalid_id_token", Message: "Google ID token has expired"}
	}
	if nbf, ok := asFloat(payload["nbf"]); ok && nbf*1000 > float64(nowMs+60_000) {
		return googleClaims{}, &AuthError{Code: "invalid_id_token", Message: "Google ID token is not valid yet"}
	}
	sub, _ := payload["sub"].(string)
	if sub == "" {
		return googleClaims{}, &AuthError{Code: "invalid_id_token", Message: "Google ID token is missing sub"}
	}
	email := ""
	if emailVerified(payload["email_verified"]) {
		if value, ok := payload["email"].(string); ok {
			email = value
		}
	}
	name := ""
	if value, ok := payload["name"].(string); ok && strings.TrimSpace(value) != "" {
		name = strings.TrimSpace(value)
	}
	nonce, _ := payload["nonce"].(string)
	return googleClaims{Sub: sub, Email: email, Name: name, Nonce: nonce}, nil
}

func verifyRS256(jwk JWK, signingInput, signature []byte) error {
	pub, err := jwk.publicKey()
	if err != nil {
		return err
	}
	sum := sha256.Sum256(signingInput)
	return rsa.VerifyPKCS1v15(pub, crypto.SHA256, sum[:], signature)
}

func (j JWK) publicKey() (*rsa.PublicKey, error) {
	nBytes, err := decodeBase64URL(j.N)
	if err != nil {
		return nil, err
	}
	eBytes, err := decodeBase64URL(j.E)
	if err != nil {
		return nil, err
	}
	e := 0
	for _, b := range eBytes {
		e = e<<8 | int(b)
	}
	if e == 0 {
		return nil, &AuthError{Code: "invalid_id_token", Message: "Google ID token signature is invalid"}
	}
	return &rsa.PublicKey{N: new(big.Int).SetBytes(nBytes), E: e}, nil
}

func audienceAllowed(raw any, clientIDs []string) bool {
	switch value := raw.(type) {
	case string:
		return containsString(clientIDs, value)
	case []any:
		for _, item := range value {
			text, ok := item.(string)
			if ok && containsString(clientIDs, text) {
				return true
			}
		}
	}
	return false
}

func emailVerified(raw any) bool {
	switch value := raw.(type) {
	case bool:
		return value
	case string:
		return value == "true"
	default:
		return false
	}
}

func asFloat(raw any) (float64, bool) {
	switch value := raw.(type) {
	case float64:
		return value, true
	case json.Number:
		parsed, err := value.Float64()
		return parsed, err == nil
	default:
		return 0, false
	}
}

func containsString(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}

func decodeBase64URL(input string) ([]byte, error) {
	if decoded, err := base64.RawURLEncoding.DecodeString(input); err == nil {
		return decoded, nil
	}
	return base64.URLEncoding.DecodeString(input)
}
