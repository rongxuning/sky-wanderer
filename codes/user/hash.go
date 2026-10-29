package user

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
)

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
