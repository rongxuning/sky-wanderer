package user

import "context"

type StoredSession struct {
	UserID    string
	CreatedAt string
	ExpiresAt string
}

type PhoneCode struct {
	Phone     string `json:"phone"`
	CodeHash  string `json:"codeHash"`
	ExpiresAt string `json:"expiresAt"`
	Attempts  int    `json:"attempts"`
	SentAt    string `json:"sentAt"`
}

type NewSession struct {
	Token     string
	UserID    string
	CreatedAt string
	ExpiresAt string
}

// Repository is the account store. InTx runs fn on the same store bound to one
// transaction. A nested InTx joins the outer transaction instead of beginning
// another one.
type Repository interface {
	InTx(ctx context.Context, fn func(Repository) error) error
	Ping(ctx context.Context) error
	FindUser(ctx context.Context, id string) (*User, error)
	InsertUser(ctx context.Context, user User) error
	UpdateUser(ctx context.Context, user User) error
	ListUsers(ctx context.Context) ([]User, error)
	FindIdentity(ctx context.Context, kind, providerSubject string) (*Identity, error)
	InsertIdentity(ctx context.Context, identity Identity) error
	UpdateIdentityUser(ctx context.Context, id, userID string) error
	ListIdentitiesByUser(ctx context.Context, userID string) ([]Identity, error)
	ListIdentities(ctx context.Context) ([]Identity, error)
	DeleteIdentity(ctx context.Context, id string) error
	InsertSession(ctx context.Context, session NewSession) error
	FindSession(ctx context.Context, token string) (*StoredSession, error)
	UpdateSessionUser(ctx context.Context, token, userID string) error
	DeleteSession(ctx context.Context, token string) error
	InsertRecord(ctx context.Context, record OwnedRecord) error
	ListRecords(ctx context.Context) ([]OwnedRecord, error)
	ReassignUserData(ctx context.Context, fromUserID, toUserID string) error
	FindPhoneCode(ctx context.Context, phone string) (*PhoneCode, error)
	SavePhoneCode(ctx context.Context, record PhoneCode) error
	SetPhoneCodeAttempts(ctx context.Context, phone string, attempts int) error
	DeletePhoneCode(ctx context.Context, phone string) error
}
