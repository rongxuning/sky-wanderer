package user

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"sync"
	"unicode/utf8"

	"golang.org/x/crypto/bcrypt"
)

// passwordBcryptCost is the work factor for email passwords. bcrypt is used
// instead of argon2id so a serverless process does not need a large memory budget.
const passwordBcryptCost = 12

const minPasswordLength = 8
const maxPasswordBytes = 72

var (
	dummyOnce sync.Once
	dummyHash string
)

func hashPassword(password string) (string, error) {
	hashed, err := bcrypt.GenerateFromPassword([]byte(password), passwordBcryptCost)
	if err != nil {
		return "", err
	}
	return string(hashed), nil
}

func checkPassword(hash, password string) bool {
	if hash == "" {
		hash = placeholderPasswordHash()
	}
	if hash == "" {
		return false
	}
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(password)) == nil
}

func placeholderPasswordHash() string {
	dummyOnce.Do(func() {
		hashed, err := bcrypt.GenerateFromPassword([]byte("sky-wanderer-dummy-password"), passwordBcryptCost)
		if err != nil {
			return
		}
		dummyHash = string(hashed)
	})
	return dummyHash
}

func validatePassword(password string) error {
	if utf8.RuneCountInString(password) < minPasswordLength {
		return &AuthError{Code: "password_too_short", Message: "password must be at least 8 characters"}
	}
	if len(password) > maxPasswordBytes {
		return &AuthError{Code: "password_too_long", Message: "password is too long"}
	}
	return nil
}

func sha256Hex(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}

func hashEqual(left, right string) bool {
	a := []byte(left)
	b := []byte(right)
	if len(a) != len(b) {
		return false
	}
	return subtle.ConstantTimeCompare(a, b) == 1
}

func codeHash(pepper, code string) string {
	return sha256Hex(pepper + "\n" + code)
}
