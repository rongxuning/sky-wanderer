package user

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

func OpenPostgres(ctx context.Context, queryURL, migrateURL string) (Repository, func(), error) {
	queryURL = strings.TrimSpace(queryURL)
	migrateURL = strings.TrimSpace(migrateURL)
	if migrateURL == "" {
		migrateURL = queryURL
	}
	pool, err := newPool(ctx, queryURL)
	if err != nil {
		return nil, nil, err
	}
	migrator := sqlRunner(pool)
	var extra *pgxpool.Pool
	if migrateURL != queryURL {
		extra, err = newPool(ctx, migrateURL)
		if err != nil {
			pool.Close()
			return nil, nil, err
		}
		migrator = extra
	}
	if err := migrateSQL(ctx, migrator); err != nil {
		if extra != nil {
			extra.Close()
		}
		pool.Close()
		return nil, nil, err
	}
	if extra != nil {
		extra.Close()
	}
	return &pgRepo{pool: pool, q: pool}, pool.Close, nil
}

func newPool(ctx context.Context, rawURL string) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(rawURL)
	if err != nil {
		return nil, err
	}
	// Neon’s pooled endpoint is PgBouncer in transaction mode. Prepared
	// statements do not survive that, so use the simple protocol.
	cfg.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol
	if cfg.MaxConns == 0 || cfg.MaxConns > 4 {
		cfg.MaxConns = 4
	}
	return pgxpool.NewWithConfig(ctx, cfg)
}

type pgQuery interface {
	Exec(ctx context.Context, sql string, arguments ...any) (pgconn.CommandTag, error)
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

type pgRepo struct {
	pool *pgxpool.Pool
	q    pgQuery
}

func (r *pgRepo) InTx(ctx context.Context, fn func(Repository) error) error {
	if r.pool == nil {
		return fn(r)
	}
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if err := fn(&pgRepo{q: tx}); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (r *pgRepo) Ping(ctx context.Context) error {
	if r.pool != nil {
		return r.pool.Ping(ctx)
	}
	_, err := r.q.Exec(ctx, "SELECT 1")
	return err
}

func (r *pgRepo) FindUser(ctx context.Context, id string) (*User, error) {
	row := r.q.QueryRow(ctx, `SELECT id, created_at, display_name, email, retired_at, merged_into_user_id, merged_from_user_ids
		FROM users WHERE id = $1`, id)
	user, err := scanUser(row)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &user, nil
}

func (r *pgRepo) InsertUser(ctx context.Context, user User) error {
	_, err := r.q.Exec(ctx, `INSERT INTO users (
		id, created_at, display_name, email, retired_at, merged_into_user_id, merged_from_user_ids
	) VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb)`,
		user.ID,
		mustTime(user.CreatedAt),
		user.DisplayName,
		user.Email,
		nullableTime(user.RetiredAt),
		nullableString(user.MergedIntoUserID),
		mustJSON(user.MergedFromUserIDs),
	)
	return err
}

func (r *pgRepo) UpdateUser(ctx context.Context, user User) error {
	tag, err := r.q.Exec(ctx, `UPDATE users SET
		display_name = $2,
		email = $3,
		retired_at = $4,
		merged_into_user_id = $5,
		merged_from_user_ids = $6::jsonb
		WHERE id = $1`,
		user.ID,
		user.DisplayName,
		user.Email,
		nullableTime(user.RetiredAt),
		nullableString(user.MergedIntoUserID),
		mustJSON(user.MergedFromUserIDs),
	)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return &AuthError{Code: "user_missing", Message: "account does not exist"}
	}
	return nil
}

func (r *pgRepo) ListUsers(ctx context.Context) ([]User, error) {
	rows, err := r.q.Query(ctx, `SELECT id, created_at, display_name, email, retired_at, merged_into_user_id, merged_from_user_ids
		FROM users ORDER BY created_at, id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	users := []User{}
	for rows.Next() {
		user, err := scanUser(rows)
		if err != nil {
			return nil, err
		}
		users = append(users, user)
	}
	return users, rows.Err()
}

func (r *pgRepo) FindIdentity(ctx context.Context, kind, providerSubject string) (*Identity, error) {
	row := r.q.QueryRow(ctx, `SELECT id, type, provider_subject, email, phone, user_id, created_at
		FROM identities WHERE type = $1 AND provider_subject = $2`, kind, providerSubject)
	item, err := scanIdentity(row)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &item, nil
}

func (r *pgRepo) InsertIdentity(ctx context.Context, identity Identity) error {
	_, err := r.q.Exec(ctx, `INSERT INTO identities (id, type, provider_subject, email, phone, user_id, created_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7)`,
		identity.ID,
		identity.Type,
		identity.ProviderSubject,
		nullableString(identity.Email),
		nullableString(identity.Phone),
		identity.UserID,
		mustTime(identity.CreatedAt),
	)
	if isUnique(err) {
		return &AuthError{Code: "identity_conflict", Message: "identity already exists"}
	}
	return err
}

func (r *pgRepo) UpdateIdentityUser(ctx context.Context, id, userID string) error {
	_, err := r.q.Exec(ctx, "UPDATE identities SET user_id = $2 WHERE id = $1", id, userID)
	return err
}

func (r *pgRepo) ListIdentitiesByUser(ctx context.Context, userID string) ([]Identity, error) {
	return r.listIdentities(ctx, "SELECT id, type, provider_subject, email, phone, user_id, created_at FROM identities WHERE user_id = $1 ORDER BY created_at, id", userID)
}

func (r *pgRepo) ListIdentities(ctx context.Context) ([]Identity, error) {
	return r.listIdentities(ctx, "SELECT id, type, provider_subject, email, phone, user_id, created_at FROM identities ORDER BY created_at, id")
}

func (r *pgRepo) listIdentities(ctx context.Context, query string, args ...any) ([]Identity, error) {
	rows, err := r.q.Query(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []Identity{}
	for rows.Next() {
		item, err := scanIdentity(rows)
		if err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

func (r *pgRepo) DeleteIdentity(ctx context.Context, id string) error {
	_, err := r.q.Exec(ctx, "DELETE FROM identities WHERE id = $1", id)
	return err
}

func (r *pgRepo) InsertSession(ctx context.Context, session NewSession) error {
	_, err := r.q.Exec(ctx, `INSERT INTO sessions (token_hash, user_id, created_at, expires_at) VALUES ($1, $2, $3, $4)`,
		sha256Hex(session.Token), session.UserID, mustTime(session.CreatedAt), mustTime(session.ExpiresAt))
	return err
}

func (r *pgRepo) FindSession(ctx context.Context, token string) (*StoredSession, error) {
	var userID string
	var created, expires time.Time
	err := r.q.QueryRow(ctx, "SELECT user_id, created_at, expires_at FROM sessions WHERE token_hash = $1", sha256Hex(token)).Scan(&userID, &created, &expires)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &StoredSession{UserID: userID, CreatedAt: FormatTime(created), ExpiresAt: FormatTime(expires)}, nil
}

func (r *pgRepo) UpdateSessionUser(ctx context.Context, token, userID string) error {
	_, err := r.q.Exec(ctx, "UPDATE sessions SET user_id = $2 WHERE token_hash = $1", sha256Hex(token), userID)
	return err
}

func (r *pgRepo) DeleteSession(ctx context.Context, token string) error {
	_, err := r.q.Exec(ctx, "DELETE FROM sessions WHERE token_hash = $1", sha256Hex(token))
	return err
}

func (r *pgRepo) InsertRecord(ctx context.Context, record OwnedRecord) error {
	_, err := r.q.Exec(ctx, "INSERT INTO owned_records (id, user_id, kind, payload) VALUES ($1, $2, $3, $4::jsonb)",
		record.ID, record.UserID, record.Kind, mustJSON(record.Payload))
	return err
}

func (r *pgRepo) ListRecords(ctx context.Context) ([]OwnedRecord, error) {
	rows, err := r.q.Query(ctx, "SELECT id, user_id, kind, payload FROM owned_records ORDER BY id")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	records := []OwnedRecord{}
	for rows.Next() {
		var record OwnedRecord
		var payload rawJSON
		if err := rows.Scan(&record.ID, &record.UserID, &record.Kind, &payload); err != nil {
			return nil, err
		}
		record.Payload = map[string]any{}
		if len(payload) > 0 {
			_ = json.Unmarshal(payload, &record.Payload)
			if record.Payload == nil {
				record.Payload = map[string]any{}
			}
		}
		records = append(records, record)
	}
	return records, rows.Err()
}

func (r *pgRepo) ReassignUserData(ctx context.Context, fromUserID, toUserID string) error {
	if _, err := r.q.Exec(ctx, "UPDATE identities SET user_id = $2 WHERE user_id = $1", fromUserID, toUserID); err != nil {
		return err
	}
	if _, err := r.q.Exec(ctx, "UPDATE owned_records SET user_id = $2 WHERE user_id = $1", fromUserID, toUserID); err != nil {
		return err
	}
	_, err := r.q.Exec(ctx, "UPDATE sessions SET user_id = $2 WHERE user_id = $1", fromUserID, toUserID)
	return err
}

func (r *pgRepo) FindPhoneCode(ctx context.Context, phone string) (*PhoneCode, error) {
	var record PhoneCode
	var expires, sent time.Time
	err := r.q.QueryRow(ctx, "SELECT phone, code_hash, expires_at, attempts, sent_at FROM phone_codes WHERE phone = $1 FOR UPDATE", phone).
		Scan(&record.Phone, &record.CodeHash, &expires, &record.Attempts, &sent)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	record.ExpiresAt = FormatTime(expires)
	record.SentAt = FormatTime(sent)
	return &record, nil
}

func (r *pgRepo) SavePhoneCode(ctx context.Context, record PhoneCode) error {
	_, err := r.q.Exec(ctx, `INSERT INTO phone_codes (phone, code_hash, expires_at, attempts, sent_at)
		VALUES ($1, $2, $3, $4, $5)
		ON CONFLICT (phone) DO UPDATE SET
			code_hash = EXCLUDED.code_hash,
			expires_at = EXCLUDED.expires_at,
			attempts = EXCLUDED.attempts,
			sent_at = EXCLUDED.sent_at`,
		record.Phone, record.CodeHash, mustTime(record.ExpiresAt), record.Attempts, mustTime(record.SentAt))
	return err
}

func (r *pgRepo) SetPhoneCodeAttempts(ctx context.Context, phone string, attempts int) error {
	_, err := r.q.Exec(ctx, "UPDATE phone_codes SET attempts = $2 WHERE phone = $1", phone, attempts)
	return err
}

func (r *pgRepo) DeletePhoneCode(ctx context.Context, phone string) error {
	_, err := r.q.Exec(ctx, "DELETE FROM phone_codes WHERE phone = $1", phone)
	return err
}

type rowScanner interface {
	Scan(dest ...any) error
}

func scanUser(row rowScanner) (User, error) {
	var user User
	var created time.Time
	var retired *time.Time
	var mergedInto *string
	var mergedFrom rawJSON
	if err := row.Scan(&user.ID, &created, &user.DisplayName, &user.Email, &retired, &mergedInto, &mergedFrom); err != nil {
		return User{}, err
	}
	user.CreatedAt = FormatTime(created)
	if retired != nil {
		value := FormatTime(*retired)
		user.RetiredAt = &value
	}
	user.MergedIntoUserID = mergedInto
	user.MergedFromUserIDs = []string{}
	if len(mergedFrom) > 0 {
		_ = json.Unmarshal(mergedFrom, &user.MergedFromUserIDs)
		if user.MergedFromUserIDs == nil {
			user.MergedFromUserIDs = []string{}
		}
	}
	return user, nil
}

func scanIdentity(row rowScanner) (Identity, error) {
	var item Identity
	var created time.Time
	if err := row.Scan(&item.ID, &item.Type, &item.ProviderSubject, &item.Email, &item.Phone, &item.UserID, &created); err != nil {
		return Identity{}, err
	}
	item.CreatedAt = FormatTime(created)
	return item, nil
}

type rawJSON []byte

func (r *rawJSON) Scan(src any) error {
	switch value := src.(type) {
	case nil:
		*r = nil
		return nil
	case []byte:
		*r = append([]byte(nil), value...)
		return nil
	case string:
		*r = []byte(value)
		return nil
	default:
		raw, err := json.Marshal(value)
		if err != nil {
			return err
		}
		*r = raw
		return nil
	}
}

func mustTime(value string) time.Time {
	parsed, ok := ParseTime(value)
	if !ok {
		return time.Unix(0, 0).UTC()
	}
	return parsed
}

func nullableTime(value *string) any {
	if value == nil || *value == "" {
		return nil
	}
	return mustTime(*value)
}

func nullableString(value *string) any {
	if value == nil {
		return nil
	}
	return *value
}

func mustJSON(value any) string {
	if value == nil {
		return "[]"
	}
	raw, err := json.Marshal(value)
	if err != nil {
		return "[]"
	}
	return string(raw)
}

func isUnique(err error) bool {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" {
		return true
	}
	if err == nil {
		return false
	}
	message := err.Error()
	return strings.Contains(strings.ToLower(message), "duplicate key") || strings.Contains(strings.ToLower(message), "unique constraint")
}
