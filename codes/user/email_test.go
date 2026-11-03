package user

import (
	"context"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/bcrypt"
)

func TestEmailPassword(t *testing.T) {
	b := newMemoryBackend()
	ctx := context.Background()

	t.Run("register then login opens a session for the same user", func(t *testing.T) {
		b.reset()
		created, err := b.auth.RegisterEmail(ctx, LoginInput{
			Email:       str("Walker@Example.com"),
			Password:    str("correct-horse"),
			DisplayName: str("Walker"),
		})
		if err != nil {
			t.Fatal(err)
		}
		if !created.Created || created.User.Email != "walker@example.com" || created.User.DisplayName != "Walker" || created.Session.Token == "" {
			t.Fatalf("%#v", created)
		}
		stored, err := b.repo.FindIdentity(ctx, "email", "walker@example.com")
		if err != nil || stored == nil {
			t.Fatal(err, stored)
		}
		if stored.PasswordHash == "" || stored.PasswordHash == "correct-horse" || strings.Contains(stored.PasswordHash, "correct-horse") {
			t.Fatalf("password was not hashed: %q", stored.PasswordHash)
		}
		if err := bcrypt.CompareHashAndPassword([]byte(stored.PasswordHash), []byte("correct-horse")); err != nil {
			t.Fatal(err)
		}
		cost, err := bcrypt.Cost([]byte(stored.PasswordHash))
		if err != nil || cost < passwordBcryptCost {
			t.Fatalf("cost %d %v", cost, err)
		}
		listed, err := b.auth.ListIdentities(ctx, created.Session.Token)
		if err != nil {
			t.Fatal(err)
		}
		if len(listed) != 1 || listed[0].Type != "email" || listed[0].ProviderSubject != "walker@example.com" || listed[0].PasswordHash != "" {
			t.Fatalf("listed %#v", listed)
		}

		logged, err := b.auth.LoginOrRegister(ctx, LoginInput{
			Type:     "email",
			Email:    str("  WALKER@example.com "),
			Password: str("correct-horse"),
		})
		if err != nil {
			t.Fatal(err)
		}
		if logged.Created || logged.User.ID != created.User.ID || logged.Session.Token == "" || logged.Session.Token == created.Session.Token {
			t.Fatalf("%#v", logged)
		}
	})

	t.Run("rejects a duplicate email", func(t *testing.T) {
		b.reset()
		if _, err := b.auth.RegisterEmail(ctx, LoginInput{Email: str("walker@example.com"), Password: str("correct-horse"), DisplayName: str("Walker")}); err != nil {
			t.Fatal(err)
		}
		_, err := b.auth.RegisterEmail(ctx, LoginInput{Email: str("Walker@Example.com"), Password: str("another-password"), DisplayName: str("Other")})
		if !codeIs(err, "email_taken") {
			t.Fatal(err)
		}
		users, err := b.repo.ListUsers(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if len(users) != 1 {
			t.Fatalf("users %#v", users)
		}
	})

	t.Run("rejects a wrong password without creating a user", func(t *testing.T) {
		b.reset()
		if _, err := b.auth.RegisterEmail(ctx, LoginInput{Email: str("walker@example.com"), Password: str("correct-horse")}); err != nil {
			t.Fatal(err)
		}
		before, err := b.repo.ListUsers(ctx)
		if err != nil {
			t.Fatal(err)
		}
		_, err = b.auth.LoginOrRegister(ctx, LoginInput{Type: "email", Email: str("walker@example.com"), Password: str("wrong-password")})
		if !codeIs(err, "invalid_password") {
			t.Fatal(err)
		}
		_, err = b.auth.LoginOrRegister(ctx, LoginInput{Type: "email", Email: str("missing@example.com"), Password: str("correct-horse")})
		if !codeIs(err, "email_not_found") {
			t.Fatal(err)
		}
		after, err := b.repo.ListUsers(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if len(after) != len(before) {
			t.Fatalf("users %d -> %d", len(before), len(after))
		}
	})

	t.Run("rejects a short password and a bad email", func(t *testing.T) {
		b.reset()
		if _, err := b.auth.RegisterEmail(ctx, LoginInput{Email: str("walker@example.com"), Password: str("short")}); !codeIs(err, "password_too_short") {
			t.Fatal(err)
		}
		if _, err := b.auth.RegisterEmail(ctx, LoginInput{Email: str("not-an-email"), Password: str("correct-horse")}); !codeIs(err, "invalid_email") {
			t.Fatal(err)
		}
		users, err := b.repo.ListUsers(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if len(users) != 0 {
			t.Fatalf("users %#v", users)
		}
	})

	t.Run("binding an email merges into the earlier account only when the password matches", func(t *testing.T) {
		b.reset()
		email, err := b.auth.RegisterEmail(ctx, LoginInput{Email: str("early@example.com"), Password: str("correct-horse"), DisplayName: str("Early")})
		if err != nil {
			t.Fatal(err)
		}
		b.time.advance(time.Second)
		phone, err := b.auth.LoginOrRegister(ctx, LoginInput{Type: "phone", ProviderSubject: "+8613800138000", DemoCode: str(DemoCode), DisplayName: str("Later")})
		if err != nil {
			t.Fatal(err)
		}
		if phone.User.ID == email.User.ID {
			t.Fatal("expected two users")
		}
		denied, err := b.auth.BindIdentity(ctx, BindInput{
			SessionToken: phone.Session.Token,
			LoginInput:   LoginInput{Type: "email", Email: str("early@example.com"), Password: str("wrong-password")},
		})
		if !codeIs(err, "invalid_password") || denied.Merged {
			t.Fatalf("%v %#v", err, denied)
		}
		if _, err := b.auth.ListIdentities(ctx, phone.Session.Token); err != nil {
			t.Fatal(err)
		}
		merged, err := b.auth.BindIdentity(ctx, BindInput{
			SessionToken: phone.Session.Token,
			LoginInput:   LoginInput{Type: "email", Email: str("early@example.com"), Password: str("correct-horse")},
		})
		if err != nil {
			t.Fatal(err)
		}
		if !merged.Merged || merged.User.ID != email.User.ID {
			t.Fatalf("%#v", merged)
		}
		identities, err := b.auth.ListIdentities(ctx, phone.Session.Token)
		if err != nil {
			t.Fatal(err)
		}
		types := map[string]bool{}
		for _, item := range identities {
			if item.PasswordHash != "" {
				t.Fatalf("hash leaked %#v", item)
			}
			types[item.Type] = true
		}
		if len(identities) != 2 || !types["email"] || !types["phone"] {
			t.Fatalf("%#v", identities)
		}
	})
}

func TestEmailPasswordSurvivesFileReload(t *testing.T) {
	path := t.TempDir() + "/auth-store.json"
	repo, err := NewFileRepository(path)
	if err != nil {
		t.Fatal(err)
	}
	auth := NewService(ServiceOptions{Repo: repo, Demo: true})
	ctx := context.Background()
	created, err := auth.RegisterEmail(ctx, LoginInput{Email: str("walker@example.com"), Password: str("correct-horse"), DisplayName: str("Walker")})
	if err != nil || !created.Created {
		t.Fatal(err, created.Created)
	}
	reloaded, err := NewFileRepository(path)
	if err != nil {
		t.Fatal(err)
	}
	again := NewService(ServiceOptions{Repo: reloaded, Demo: true})
	logged, err := again.LoginOrRegister(ctx, LoginInput{Type: "email", Email: str("walker@example.com"), Password: str("correct-horse")})
	if err != nil || logged.Created || logged.User.ID != created.User.ID {
		t.Fatalf("%v %#v", err, logged)
	}
	raw, err := readMemoryFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, item := range raw.Identities {
		if strings.Contains(item.PasswordHash, "correct-horse") {
			t.Fatal("plaintext password stored")
		}
	}
}
