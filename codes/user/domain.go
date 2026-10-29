package user

import (
	"strings"
	"time"
	"unicode"
)

const DemoCode = "SKY-LOCAL"

type User struct {
	ID                string   `json:"id"`
	CreatedAt         string   `json:"createdAt"`
	DisplayName       string   `json:"displayName"`
	Email             string   `json:"email"`
	RetiredAt         *string  `json:"retiredAt"`
	MergedIntoUserID  *string  `json:"mergedIntoUserId"`
	MergedFromUserIDs []string `json:"mergedFromUserIds"`
}

type Identity struct {
	ID              string  `json:"id"`
	Type            string  `json:"type"`
	ProviderSubject string  `json:"providerSubject"`
	Email           *string `json:"email"`
	Phone           *string `json:"phone"`
	UserID          string  `json:"userId"`
	CreatedAt       string  `json:"createdAt"`
}

type Session struct {
	Token     string `json:"token"`
	UserID    string `json:"userId"`
	CreatedAt string `json:"createdAt"`
}

type OwnedRecord struct {
	ID      string         `json:"id"`
	UserID  string         `json:"userId"`
	Kind    string         `json:"kind"`
	Payload map[string]any `json:"payload"`
}

type AuthError struct {
	Code    string
	Message string
}

func (e *AuthError) Error() string {
	if e == nil {
		return ""
	}
	return e.Message
}

func IsIdentityType(value string) bool {
	return value == "phone" || value == "wechat" || value == "google"
}

func IsConflict(err error) bool {
	auth, ok := err.(*AuthError)
	return ok && auth != nil && auth.Code == "identity_conflict"
}

func CanonicalSubject(kind, raw string) (string, error) {
	trimmed := strings.TrimSpace(raw)
	if kind != "phone" {
		if trimmed == "" {
			return "", &AuthError{Code: "invalid_subject", Message: "provider subject is required"}
		}
		return trimmed, nil
	}

	compact := stripPhoneSeparators(trimmed)
	if strings.HasPrefix(compact, "+") {
		digits := digitsOnly(compact[1:])
		if len(digits) < 8 || len(digits) > 15 {
			return "", &AuthError{Code: "invalid_phone", Message: "phone must be an E.164 number"}
		}
		return "+" + digits, nil
	}

	digits := digitsOnly(compact)
	if len(digits) == 11 && digits[0] == '1' {
		return "+86" + digits, nil
	}
	if strings.HasPrefix(digits, "86") && len(digits) == 13 {
		return "+" + digits, nil
	}
	if len(digits) >= 8 && len(digits) <= 15 {
		return "+" + digits, nil
	}
	return "", &AuthError{Code: "invalid_phone", Message: "phone must be an E.164 number"}
}

func NormalizeEmail(email string) string {
	return strings.ToLower(strings.TrimSpace(email))
}

func FormatTime(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05.000Z")
}

func ParseTime(value string) (time.Time, bool) {
	if value == "" {
		return time.Time{}, false
	}
	for _, layout := range []string{
		"2006-01-02T15:04:05.000Z07:00",
		"2006-01-02T15:04:05.000Z",
		time.RFC3339Nano,
		time.RFC3339,
	} {
		if parsed, err := time.Parse(layout, value); err == nil {
			return parsed, true
		}
	}
	return time.Time{}, false
}

func expiredAt(value string, now time.Time) bool {
	parsed, ok := ParseTime(value)
	if !ok {
		// Date.parse(invalid) is NaN, and NaN <= now is false in the old service.
		return false
	}
	return !parsed.After(now)
}

func stripPhoneSeparators(value string) string {
	return strings.Map(func(r rune) rune {
		switch r {
		case ' ', '\t', '\n', '\r', '(', ')', '.', '-':
			return -1
		default:
			if unicode.IsSpace(r) {
				return -1
			}
			return r
		}
	}, value)
}

func digitsOnly(value string) string {
	return strings.Map(func(r rune) rune {
		if r >= '0' && r <= '9' {
			return r
		}
		return -1
	}, value)
}

func cloneStringSlice(values []string) []string {
	if len(values) == 0 {
		return []string{}
	}
	return append([]string{}, values...)
}

func cloneUser(user User) User {
	user.MergedFromUserIDs = cloneStringSlice(user.MergedFromUserIDs)
	user.RetiredAt = cloneStringPtr(user.RetiredAt)
	user.MergedIntoUserID = cloneStringPtr(user.MergedIntoUserID)
	return user
}

func cloneStringPtr(value *string) *string {
	if value == nil {
		return nil
	}
	copy := *value
	return &copy
}

func stringPtr(value string) *string {
	if value == "" {
		return nil
	}
	return &value
}
