package gateway

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"net/url"
	"strings"

	"skywanderer/codes/core/sport"
	"skywanderer/codes/user"
)

type Ready func(context.Context) error

func NewHandler(auth *user.Service, ready Ready) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		if len(path) > 1 && strings.HasSuffix(path, "/") {
			path = path[:len(path)-1]
		}
		defer func() {
			if recovered := recover(); recovered != nil {
				log.Printf("panic: %v", recovered)
				writeError(w, 500, "internal", "internal error")
			}
		}()
		if err := dispatch(auth, ready, path, w, r); err != nil {
			var authErr *user.AuthError
			if errors.As(err, &authErr) {
				writeError(w, statusFor(authErr.Code), authErr.Code, authErr.Message)
				return
			}
			log.Printf("request error: %v", err)
			writeError(w, 500, "internal", "internal error")
		}
	})
}

func dispatch(auth *user.Service, ready Ready, path string, w http.ResponseWriter, r *http.Request) error {
	for _, route := range sport.Routes() {
		if r.Method == route.Method && path == route.Pattern && route.Handler != nil {
			route.Handler.ServeHTTP(w, r)
			return nil
		}
	}
	if r.Method == http.MethodGet && path == "/health" {
		if ready != nil {
			if err := ready(r.Context()); err != nil {
				var authErr *user.AuthError
				if errors.As(err, &authErr) {
					return authErr
				}
				return &user.AuthError{Code: "db_unavailable", Message: "database is unavailable"}
			}
		}
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
		return nil
	}
	if r.Method == http.MethodGet && path == "/v1/auth/wechat/callback" {
		redirectToApp(w, "wechat", callbackQuery(r.URL.Query()))
		return nil
	}
	if r.Method == http.MethodGet && path == "/v1/auth/google/callback" {
		redirectToApp(w, "google", callbackQuery(r.URL.Query()))
		return nil
	}
	if r.Method == http.MethodPost && path == "/v1/auth/phone/send-code" {
		body, err := readBody(r)
		if err != nil {
			return err
		}
		phone, ok := body.Phone.(string)
		if !ok {
			return &user.AuthError{Code: "invalid_phone", Message: "phone must be an E.164 number"}
		}
		result, err := auth.SendPhoneCode(r.Context(), phone)
		if err != nil {
			return err
		}
		writeJSON(w, http.StatusOK, result)
		return nil
	}
	if r.Method == http.MethodPost && path == "/v1/auth/login" {
		body, err := readBody(r)
		if err != nil {
			return err
		}
		input, err := readLogin(body)
		if err != nil {
			return err
		}
		result, err := auth.LoginOrRegister(r.Context(), input)
		if err != nil {
			return err
		}
		identities, err := auth.ListIdentities(r.Context(), result.Session.Token)
		if err != nil {
			return err
		}
		writeJSON(w, http.StatusOK, authPayload{
			User:       result.User,
			Session:    result.Session,
			Created:    result.Created,
			Merged:     false,
			Identities: identities,
		})
		return nil
	}
	token := bearer(r)
	if token == "" {
		return &user.AuthError{Code: "not_authenticated", Message: "session is missing or expired"}
	}
	if r.Method == http.MethodPost && path == "/v1/auth/bind" {
		body, err := readBody(r)
		if err != nil {
			return err
		}
		input, err := readLogin(body)
		if err != nil {
			return err
		}
		result, err := auth.BindIdentity(r.Context(), user.BindInput{LoginInput: input, SessionToken: token})
		if err != nil {
			return err
		}
		identities, err := auth.ListIdentities(r.Context(), result.Session.Token)
		if err != nil {
			return err
		}
		writeJSON(w, http.StatusOK, authPayload{
			User:       result.User,
			Session:    result.Session,
			Created:    false,
			Merged:     result.Merged,
			Identities: identities,
		})
		return nil
	}
	if r.Method == http.MethodGet && path == "/v1/auth/identities" {
		identities, err := auth.ListIdentities(r.Context(), token)
		if err != nil {
			return err
		}
		writeJSON(w, http.StatusOK, map[string]any{"identities": identities})
		return nil
	}
	if r.Method == http.MethodDelete && path == "/v1/auth/identities" {
		body, err := readBody(r)
		if err != nil {
			return err
		}
		input, err := readLogin(body)
		if err != nil {
			return err
		}
		if input.ProviderSubject == "" {
			return &user.AuthError{Code: "invalid_subject", Message: "providerSubject is required"}
		}
		if err := auth.UnbindIdentity(r.Context(), user.UnbindInput{
			SessionToken:    token,
			Type:            input.Type,
			ProviderSubject: input.ProviderSubject,
		}); err != nil {
			return err
		}
		identities, err := auth.ListIdentities(r.Context(), token)
		if err != nil {
			return err
		}
		writeJSON(w, http.StatusOK, map[string]any{"identities": identities})
		return nil
	}
	if r.Method == http.MethodPost && path == "/v1/auth/logout" {
		if err := auth.Logout(r.Context(), token); err != nil {
			return err
		}
		w.Header().Set("cache-control", "no-store")
		w.WriteHeader(http.StatusNoContent)
		return nil
	}
	writeError(w, http.StatusNotFound, "not_found", "not found")
	return nil
}

type authPayload struct {
	User       user.User       `json:"user"`
	Session    user.Session    `json:"session"`
	Created    bool            `json:"created"`
	Merged     bool            `json:"merged"`
	Identities []user.Identity `json:"identities"`
}

type authBody struct {
	Type              any `json:"type"`
	ProviderSubject   any `json:"providerSubject"`
	DemoCode          any `json:"demoCode"`
	SmsCode           any `json:"smsCode"`
	AuthorizationCode any `json:"authorizationCode"`
	IDToken           any `json:"idToken"`
	CodeVerifier      any `json:"codeVerifier"`
	RedirectURI       any `json:"redirectUri"`
	ClientID          any `json:"clientId"`
	Nonce             any `json:"nonce"`
	DisplayName       any `json:"displayName"`
	Email             any `json:"email"`
	Phone             any `json:"phone"`
}

func readLogin(body authBody) (user.LoginInput, error) {
	kind, ok := body.Type.(string)
	if !ok || !user.IsIdentityType(kind) {
		return user.LoginInput{}, &user.AuthError{Code: "invalid_subject", Message: "type must be phone, wechat, or google"}
	}
	return user.LoginInput{
		Type:              kind,
		ProviderSubject:   stringOrEmpty(body.ProviderSubject),
		DemoCode:          stringPtrIfString(body.DemoCode),
		SmsCode:           stringPtrIfString(body.SmsCode),
		AuthorizationCode: stringPtrIfString(body.AuthorizationCode),
		IDToken:           stringPtrIfString(body.IDToken),
		CodeVerifier:      stringPtrIfString(body.CodeVerifier),
		RedirectURI:       stringPtrIfString(body.RedirectURI),
		ClientID:          stringPtrIfString(body.ClientID),
		Nonce:             stringPtrIfString(body.Nonce),
		DisplayName:       stringPtrIfString(body.DisplayName),
		Email:             stringPtrIfString(body.Email),
		Phone:             stringPtrIfString(body.Phone),
	}, nil
}

func stringOrEmpty(value any) string {
	text, _ := value.(string)
	return text
}

func stringPtrIfString(value any) *string {
	text, ok := value.(string)
	if !ok {
		return nil
	}
	return &text
}

func readBody(r *http.Request) (authBody, error) {
	if r.Body == nil {
		return authBody{}, nil
	}
	defer r.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(r.Body, 32_769))
	if err != nil {
		return authBody{}, err
	}
	if len(raw) == 0 {
		return authBody{}, nil
	}
	if len(raw) > 32_768 {
		return authBody{}, &user.AuthError{Code: "invalid_subject", Message: "body is too large"}
	}
	if !json.Valid(raw) {
		return authBody{}, &user.AuthError{Code: "invalid_subject", Message: "body must be JSON"}
	}
	var probe any
	if err := json.Unmarshal(raw, &probe); err != nil {
		return authBody{}, &user.AuthError{Code: "invalid_subject", Message: "body must be JSON"}
	}
	if _, ok := probe.(map[string]any); !ok {
		return authBody{}, &user.AuthError{Code: "invalid_subject", Message: "body must be a JSON object"}
	}
	var body authBody
	if err := json.Unmarshal(raw, &body); err != nil {
		return authBody{}, &user.AuthError{Code: "invalid_subject", Message: "body must be JSON"}
	}
	return body, nil
}

func bearer(r *http.Request) string {
	header := r.Header.Get("Authorization")
	if header == "" {
		return ""
	}
	parts := strings.Split(header, " ")
	if len(parts) < 2 || !strings.EqualFold(parts[0], "bearer") || parts[1] == "" {
		return ""
	}
	return parts[1]
}

func callbackQuery(query url.Values) string {
	code := query.Get("code")
	state := query.Get("state")
	providerError := query.Get("error")
	var parts []string
	if code != "" {
		parts = append(parts, "code="+url.QueryEscape(code))
	}
	if state != "" {
		parts = append(parts, "state="+url.QueryEscape(state))
	}
	if providerError != "" {
		parts = append(parts, "error="+url.QueryEscape(providerError))
	} else if code == "" {
		parts = append(parts, "error=missing_code")
	}
	return strings.Join(parts, "&")
}

func redirectToApp(w http.ResponseWriter, route, rawQuery string) {
	target := &url.URL{Scheme: "skywanderer", Host: "auth", Path: "/" + route}
	if rawQuery != "" {
		target.RawQuery = rawQuery
	}
	w.Header().Set("location", target.String())
	w.Header().Set("cache-control", "no-store")
	w.WriteHeader(http.StatusFound)
}

func statusFor(code string) int {
	switch code {
	case "not_authenticated":
		return http.StatusUnauthorized
	case "last_identity":
		return http.StatusConflict
	case "identity_not_found", "user_missing":
		return http.StatusNotFound
	case "sms_rate_limited":
		return http.StatusTooManyRequests
	case "sms_not_configured", "wechat_not_configured", "google_not_configured", "db_unavailable":
		return http.StatusServiceUnavailable
	case "sms_failed":
		return http.StatusBadGateway
	default:
		return http.StatusBadRequest
	}
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, map[string]any{
		"error": map[string]string{"code": code, "message": message},
	})
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	var buf strings.Builder
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(body); err != nil {
		http.Error(w, `{"error":{"code":"internal","message":"internal error"}}`, http.StatusInternalServerError)
		return
	}
	payload := strings.TrimRight(buf.String(), "\n")
	w.Header().Set("content-type", "application/json; charset=utf-8")
	w.Header().Set("cache-control", "no-store")
	w.WriteHeader(status)
	_, _ = io.WriteString(w, payload)
}
