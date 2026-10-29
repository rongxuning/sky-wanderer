// Package user is the account system: phone, WeChat, and Google on one user.
// Binding an identity that already belongs to someone else merges into the
// earlier-created account and retires the newer one.
//
// Postgres is the store when DATABASE_URL is set. AUTH_DEMO=1 without a
// database keeps a JSON file for local login. SMS, WeChat, and Google are
// checked here; the HTTP routes are mounted by codes/core.
package user
