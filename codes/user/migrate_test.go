package user

import (
	"strings"
	"testing"
)

func TestSplitSQLKeepsDoBlockIntact(t *testing.T) {
	script := strings.Join([]string{
		"ALTER TABLE identities DROP CONSTRAINT IF EXISTS identities_type_check;",
		"DO $$",
		"BEGIN",
		"  PERFORM 1;",
		"END",
		"$$;",
		"ALTER TABLE identities ADD COLUMN IF NOT EXISTS password_hash text;",
	}, "\n")
	parts := splitSQL(script)
	if len(parts) != 3 {
		t.Fatalf("%d %#v", len(parts), parts)
	}
	if !strings.Contains(parts[1], "BEGIN") || !strings.Contains(parts[1], "PERFORM 1;") || strings.Contains(parts[0], "PERFORM") {
		t.Fatalf("%#v", parts)
	}
}

func TestAuthMigrationsSplit(t *testing.T) {
	entries, err := migrationFiles.ReadDir("migrations")
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) < 2 {
		t.Fatalf("migrations %d", len(entries))
	}
	for _, entry := range entries {
		script, err := migrationFiles.ReadFile("migrations/" + entry.Name())
		if err != nil {
			t.Fatal(err)
		}
		parts := splitSQL(string(script))
		if len(parts) == 0 {
			t.Fatalf("%s produced no statements", entry.Name())
		}
		for _, part := range parts {
			if strings.Count(part, "$$")%2 != 0 {
				t.Fatalf("%s unbalanced dollar quote: %s", entry.Name(), part)
			}
		}
	}
	email, err := migrationFiles.ReadFile("migrations/002_email_password.sql")
	if err != nil {
		t.Fatal(err)
	}
	parts := splitSQL(string(email))
	if len(parts) != 3 || !strings.Contains(parts[0], "DROP CONSTRAINT") || !strings.Contains(parts[2], "password_hash") {
		t.Fatalf("%#v", parts)
	}
}
