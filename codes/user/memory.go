package user

import (
	"context"
	"encoding/json"
	"sort"
	"sync"
)

type MemorySession struct {
	Token     string `json:"token"`
	UserID    string `json:"userId"`
	CreatedAt string `json:"createdAt"`
	ExpiresAt string `json:"expiresAt"`
}

type MemoryData struct {
	Users      []User          `json:"users"`
	Identities []Identity      `json:"identities"`
	Sessions   []MemorySession `json:"sessions"`
	Records    []OwnedRecord   `json:"records"`
	PhoneCodes []PhoneCode     `json:"phoneCodes"`
}

func EmptyMemory() *MemoryData {
	return &MemoryData{
		Users:      []User{},
		Identities: []Identity{},
		Sessions:   []MemorySession{},
		Records:    []OwnedRecord{},
		PhoneCodes: []PhoneCode{},
	}
}

type memoryRepo struct {
	mu       sync.Mutex
	data     *MemoryData
	depth    int
	onChange func()
}

func NewMemoryRepository(data *MemoryData) Repository {
	if data == nil {
		data = EmptyMemory()
	}
	normalizeMemory(data)
	return &memoryRepo{data: data}
}

func (r *memoryRepo) InTx(ctx context.Context, fn func(Repository) error) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if r.depth > 0 {
		return fn(r)
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	snap := cloneMemory(r.data)
	r.depth++
	err := fn(r)
	r.depth--
	if err != nil {
		*r.data = *snap
		return err
	}
	r.touch()
	return nil
}

func (r *memoryRepo) withLock(fn func()) {
	if r.depth == 0 {
		r.mu.Lock()
		defer r.mu.Unlock()
	}
	fn()
}

func (r *memoryRepo) touch() {
	if r.depth == 0 && r.onChange != nil {
		r.onChange()
	}
}

func (r *memoryRepo) Ping(context.Context) error { return nil }

func (r *memoryRepo) FindUser(_ context.Context, id string) (*User, error) {
	var found *User
	r.withLock(func() {
		for i := range r.data.Users {
			if r.data.Users[i].ID == id {
				user := cloneUser(r.data.Users[i])
				found = &user
				return
			}
		}
	})
	return found, nil
}

func (r *memoryRepo) InsertUser(_ context.Context, user User) error {
	r.withLock(func() {
		r.data.Users = append(r.data.Users, cloneUser(user))
		r.touch()
	})
	return nil
}

func (r *memoryRepo) UpdateUser(_ context.Context, user User) error {
	var missing error
	r.withLock(func() {
		for i := range r.data.Users {
			if r.data.Users[i].ID == user.ID {
				r.data.Users[i] = cloneUser(user)
				r.touch()
				return
			}
		}
		missing = &AuthError{Code: "user_missing", Message: "account does not exist"}
	})
	return missing
}

func (r *memoryRepo) ListUsers(context.Context) ([]User, error) {
	var users []User
	r.withLock(func() {
		users = make([]User, 0, len(r.data.Users))
		for _, user := range r.data.Users {
			users = append(users, cloneUser(user))
		}
	})
	return users, nil
}

func (r *memoryRepo) FindIdentity(_ context.Context, kind, providerSubject string) (*Identity, error) {
	var found *Identity
	r.withLock(func() {
		for i := range r.data.Identities {
			item := r.data.Identities[i]
			if item.Type == kind && item.ProviderSubject == providerSubject {
				copy := cloneIdentity(item)
				found = &copy
				return
			}
		}
	})
	return found, nil
}

func (r *memoryRepo) InsertIdentity(_ context.Context, identity Identity) error {
	var conflict error
	r.withLock(func() {
		for _, item := range r.data.Identities {
			if item.Type == identity.Type && item.ProviderSubject == identity.ProviderSubject {
				conflict = &AuthError{Code: "identity_conflict", Message: "identity already exists"}
				return
			}
		}
		r.data.Identities = append(r.data.Identities, cloneIdentity(identity))
		r.touch()
	})
	return conflict
}

func (r *memoryRepo) UpdateIdentityUser(_ context.Context, id, userID string) error {
	var missing error
	r.withLock(func() {
		for i := range r.data.Identities {
			if r.data.Identities[i].ID == id {
				r.data.Identities[i].UserID = userID
				r.touch()
				return
			}
		}
		missing = &AuthError{Code: "identity_not_found", Message: "identity is not on this account"}
	})
	return missing
}

func (r *memoryRepo) ListIdentitiesByUser(_ context.Context, userID string) ([]Identity, error) {
	var items []Identity
	r.withLock(func() {
		for _, item := range r.data.Identities {
			if item.UserID == userID {
				items = append(items, cloneIdentity(item))
			}
		}
		sortIdentities(items)
	})
	if items == nil {
		items = []Identity{}
	}
	return items, nil
}

func (r *memoryRepo) ListIdentities(context.Context) ([]Identity, error) {
	var items []Identity
	r.withLock(func() {
		items = make([]Identity, 0, len(r.data.Identities))
		for _, item := range r.data.Identities {
			items = append(items, cloneIdentity(item))
		}
		sortIdentities(items)
	})
	return items, nil
}

func (r *memoryRepo) DeleteIdentity(_ context.Context, id string) error {
	r.withLock(func() {
		for i := range r.data.Identities {
			if r.data.Identities[i].ID == id {
				r.data.Identities = append(r.data.Identities[:i], r.data.Identities[i+1:]...)
				r.touch()
				return
			}
		}
	})
	return nil
}

func (r *memoryRepo) InsertSession(_ context.Context, session NewSession) error {
	r.withLock(func() {
		r.data.Sessions = append(r.data.Sessions, MemorySession{
			Token:     session.Token,
			UserID:    session.UserID,
			CreatedAt: session.CreatedAt,
			ExpiresAt: session.ExpiresAt,
		})
		r.touch()
	})
	return nil
}

func (r *memoryRepo) FindSession(_ context.Context, token string) (*StoredSession, error) {
	var found *StoredSession
	r.withLock(func() {
		for _, session := range r.data.Sessions {
			if session.Token == token {
				found = &StoredSession{
					UserID:    session.UserID,
					CreatedAt: session.CreatedAt,
					ExpiresAt: session.ExpiresAt,
				}
				return
			}
		}
	})
	return found, nil
}

func (r *memoryRepo) UpdateSessionUser(_ context.Context, token, userID string) error {
	r.withLock(func() {
		for i := range r.data.Sessions {
			if r.data.Sessions[i].Token == token {
				r.data.Sessions[i].UserID = userID
				r.touch()
				return
			}
		}
	})
	return nil
}

func (r *memoryRepo) DeleteSession(_ context.Context, token string) error {
	r.withLock(func() {
		for i := range r.data.Sessions {
			if r.data.Sessions[i].Token == token {
				r.data.Sessions = append(r.data.Sessions[:i], r.data.Sessions[i+1:]...)
				r.touch()
				return
			}
		}
	})
	return nil
}

func (r *memoryRepo) InsertRecord(_ context.Context, record OwnedRecord) error {
	r.withLock(func() {
		record.Payload = clonePayload(record.Payload)
		r.data.Records = append(r.data.Records, record)
		r.touch()
	})
	return nil
}

func (r *memoryRepo) ListRecords(context.Context) ([]OwnedRecord, error) {
	var records []OwnedRecord
	r.withLock(func() {
		records = make([]OwnedRecord, 0, len(r.data.Records))
		for _, record := range r.data.Records {
			record.Payload = clonePayload(record.Payload)
			records = append(records, record)
		}
	})
	return records, nil
}

func (r *memoryRepo) ReassignUserData(_ context.Context, fromUserID, toUserID string) error {
	r.withLock(func() {
		for i := range r.data.Identities {
			if r.data.Identities[i].UserID == fromUserID {
				r.data.Identities[i].UserID = toUserID
			}
		}
		for i := range r.data.Records {
			if r.data.Records[i].UserID == fromUserID {
				r.data.Records[i].UserID = toUserID
			}
		}
		for i := range r.data.Sessions {
			if r.data.Sessions[i].UserID == fromUserID {
				r.data.Sessions[i].UserID = toUserID
			}
		}
		r.touch()
	})
	return nil
}

func (r *memoryRepo) FindPhoneCode(_ context.Context, phone string) (*PhoneCode, error) {
	var found *PhoneCode
	r.withLock(func() {
		for i := range r.data.PhoneCodes {
			if r.data.PhoneCodes[i].Phone == phone {
				copy := r.data.PhoneCodes[i]
				found = &copy
				return
			}
		}
	})
	return found, nil
}

func (r *memoryRepo) SavePhoneCode(_ context.Context, record PhoneCode) error {
	r.withLock(func() {
		for i := range r.data.PhoneCodes {
			if r.data.PhoneCodes[i].Phone == record.Phone {
				r.data.PhoneCodes[i] = record
				r.touch()
				return
			}
		}
		r.data.PhoneCodes = append(r.data.PhoneCodes, record)
		r.touch()
	})
	return nil
}

func (r *memoryRepo) SetPhoneCodeAttempts(_ context.Context, phone string, attempts int) error {
	r.withLock(func() {
		for i := range r.data.PhoneCodes {
			if r.data.PhoneCodes[i].Phone == phone {
				r.data.PhoneCodes[i].Attempts = attempts
				r.touch()
				return
			}
		}
	})
	return nil
}

func (r *memoryRepo) DeletePhoneCode(_ context.Context, phone string) error {
	r.withLock(func() {
		for i := range r.data.PhoneCodes {
			if r.data.PhoneCodes[i].Phone == phone {
				r.data.PhoneCodes = append(r.data.PhoneCodes[:i], r.data.PhoneCodes[i+1:]...)
				r.touch()
				return
			}
		}
	})
	return nil
}

func sortIdentities(items []Identity) {
	sort.Slice(items, func(i, j int) bool {
		if items[i].CreatedAt == items[j].CreatedAt {
			return items[i].ID < items[j].ID
		}
		return items[i].CreatedAt < items[j].CreatedAt
	})
}

func cloneIdentity(item Identity) Identity {
	item.Email = cloneStringPtr(item.Email)
	item.Phone = cloneStringPtr(item.Phone)
	return item
}

func cloneMemory(data *MemoryData) *MemoryData {
	out := EmptyMemory()
	for _, user := range data.Users {
		out.Users = append(out.Users, cloneUser(user))
	}
	for _, item := range data.Identities {
		out.Identities = append(out.Identities, cloneIdentity(item))
	}
	out.Sessions = append([]MemorySession{}, data.Sessions...)
	for _, record := range data.Records {
		record.Payload = clonePayload(record.Payload)
		out.Records = append(out.Records, record)
	}
	out.PhoneCodes = append([]PhoneCode{}, data.PhoneCodes...)
	return out
}

func clonePayload(payload map[string]any) map[string]any {
	if payload == nil {
		return map[string]any{}
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return map[string]any{}
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil || out == nil {
		return map[string]any{}
	}
	return out
}

func normalizeMemory(data *MemoryData) {
	if data.Users == nil {
		data.Users = []User{}
	}
	if data.Identities == nil {
		data.Identities = []Identity{}
	}
	if data.Sessions == nil {
		data.Sessions = []MemorySession{}
	}
	if data.Records == nil {
		data.Records = []OwnedRecord{}
	}
	if data.PhoneCodes == nil {
		data.PhoneCodes = []PhoneCode{}
	}
	for i := range data.Users {
		if data.Users[i].MergedFromUserIDs == nil {
			data.Users[i].MergedFromUserIDs = []string{}
		}
	}
}
