package user

import (
	"context"
	"embed"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

//go:embed migrations/*.sql
var migrationFiles embed.FS

type sqlRunner interface {
	Exec(ctx context.Context, sql string, arguments ...any) (pgconn.CommandTag, error)
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

func migrateSQL(ctx context.Context, db sqlRunner) error {
	if _, err := db.Exec(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		id text PRIMARY KEY,
		applied_at timestamptz NOT NULL
	)`); err != nil {
		return err
	}
	entries, err := migrationFiles.ReadDir("migrations")
	if err != nil {
		return err
	}
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() && strings.HasSuffix(entry.Name(), ".sql") {
			names = append(names, entry.Name())
		}
	}
	sort.Strings(names)
	for _, name := range names {
		rows, err := db.Query(ctx, "SELECT id FROM schema_migrations WHERE id = $1", name)
		if err != nil {
			return err
		}
		applied := rows.Next()
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
		if applied {
			continue
		}
		script, err := migrationFiles.ReadFile("migrations/" + name)
		if err != nil {
			return err
		}
		if err := runStatements(ctx, db, string(script)); err != nil {
			return err
		}
		if _, err := db.Exec(ctx, "INSERT INTO schema_migrations (id, applied_at) VALUES ($1, now())", name); err != nil {
			return err
		}
	}
	return nil
}

func runStatements(ctx context.Context, db sqlRunner, script string) error {
	lines := strings.Split(script, "\n")
	kept := make([]string, 0, len(lines))
	for _, line := range lines {
		if strings.HasPrefix(strings.TrimSpace(line), "--") {
			continue
		}
		kept = append(kept, line)
	}
	for _, statement := range strings.Split(strings.Join(kept, "\n"), ";") {
		text := strings.TrimSpace(statement)
		if text == "" {
			continue
		}
		if _, err := db.Exec(ctx, text); err != nil {
			return err
		}
	}
	return nil
}
