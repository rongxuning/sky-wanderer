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
	for _, statement := range splitSQL(strings.Join(kept, "\n")) {
		if _, err := db.Exec(ctx, statement); err != nil {
			return err
		}
	}
	return nil
}

// splitSQL separates statements on semicolons, but keeps a dollar-quoted
// DO block together so its internal semicolons stay in one statement.
func splitSQL(script string) []string {
	var statements []string
	var b strings.Builder
	quoted := false
	for i := 0; i < len(script); i++ {
		if strings.HasPrefix(script[i:], "$$") {
			quoted = !quoted
			b.WriteString("$$")
			i++
			continue
		}
		if !quoted && script[i] == ';' {
			if text := strings.TrimSpace(b.String()); text != "" {
				statements = append(statements, text)
			}
			b.Reset()
			continue
		}
		b.WriteByte(script[i])
	}
	if text := strings.TrimSpace(b.String()); text != "" {
		statements = append(statements, text)
	}
	return statements
}
