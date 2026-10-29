package user

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestAuthMemory(t *testing.T) {
	registerAuthTests(t, func() *backend { return newMemoryBackend() })
}

type clock struct {
	cur time.Time
}

func (c *clock) now() time.Time { return c.cur }

func (c *clock) advance(d time.Duration) { c.cur = c.cur.Add(d) }

func (c *clock) set(iso string) {
	parsed, ok := ParseTime(iso)
	if !ok {
		panic(iso)
	}
	c.cur = parsed
}

type backend struct {
	auth   *Service
	repo   Repository
	data   *MemoryData
	time   *clock
	cursor int
}

func newMemoryBackend() *backend {
	b := &backend{
		data: EmptyMemory(),
		time: &clock{cur: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)},
	}
	b.repo = NewMemoryRepository(b.data)
	b.auth = NewService(ServiceOptions{
		Repo:  b.repo,
		Demo:  true,
		Now:   b.time.now,
		NewID: b.nextID,
	})
	return b
}

func (b *backend) nextID() string {
	id := fmt.Sprintf("id-%d", b.cursor)
	b.cursor++
	return id
}

func (b *backend) reset() {
	b.cursor = 0
	b.time.set("2026-01-01T00:00:00.000Z")
	*b.data = *EmptyMemory()
}

func registerAuthTests(t *testing.T, open func() *backend) {
	t.Helper()
	b := open()
	ctx := context.Background()

	tests := []struct {
		name string
		fn   func(t *testing.T)
	}{
		{"creates a user on first login and returns the same user the next time", func(t *testing.T) {
			first, err := b.auth.LoginOrRegister(ctx, LoginInput{Type: "phone", ProviderSubject: "13800138000", DemoCode: str(DemoCode), DisplayName: str("小林")})
			if err != nil {
				t.Fatal(err)
			}
			second, err := b.auth.LoginOrRegister(ctx, LoginInput{Type: "phone", ProviderSubject: "+86 138-0013-8000", DemoCode: str(DemoCode)})
			if err != nil {
				t.Fatal(err)
			}
			if !first.Created || second.Created || second.User.ID != first.User.ID || second.User.DisplayName != "小林" {
				t.Fatalf("login %#v %#v", first, second)
			}
			identities, err := b.auth.ListIdentities(ctx, second.Session.Token)
			if err != nil {
				t.Fatal(err)
			}
			if len(identities) != 1 || identities[0].ProviderSubject != "+8613800138000" || identities[0].Type != "phone" {
				t.Fatalf("identities %#v", identities)
			}
		}},
		{"accepts the demo code in smsCode the way the iOS client sends it", func(t *testing.T) {
			result, err := b.auth.LoginOrRegister(ctx, LoginInput{Type: "phone", ProviderSubject: "13800138000", SmsCode: str(DemoCode)})
			if err != nil || !result.Created {
				t.Fatalf("smsCode demo login: %v %#v", err, result)
			}
		}},
		{"rejects a phone login whose demo code is not the local stub", func(t *testing.T) {
			_, err := b.auth.LoginOrRegister(ctx, LoginInput{Type: "phone", ProviderSubject: "+8613800138000", DemoCode: str("000000")})
			if !codeIs(err, "invalid_demo_code") {
				t.Fatal(err)
			}
		}},
		{"accepts wechat and google stubs without a real provider token", func(t *testing.T) {
			wechat, err := b.auth.LoginOrRegister(ctx, LoginInput{Type: "wechat", ProviderSubject: "openid-wx-1"})
			if err != nil {
				t.Fatal(err)
			}
			google, err := b.auth.LoginOrRegister(ctx, LoginInput{Type: "google", ProviderSubject: "google-sub-1", Email: str("walker@example.com")})
			if err != nil {
				t.Fatal(err)
			}
			if wechat.User.ID == google.User.ID || google.User.Email != "walker@example.com" || wechat.User.DisplayName != "微信用户" {
				t.Fatalf("wechat %#v google %#v", wechat.User, google.User)
			}
		}},
		{"returns the demo code when SMS is not configured", func(t *testing.T) {
			sent, err := b.auth.SendPhoneCode(ctx, "13800138000")
			if err != nil {
				t.Fatal(err)
			}
			if sent.Phone != "+8613800138000" || sent.DemoCode == nil || *sent.DemoCode != DemoCode {
				t.Fatalf("%#v", sent)
			}
		}},
		{"binds a new identity onto the current user", func(t *testing.T) {
			phone, err := b.auth.LoginOrRegister(ctx, LoginInput{Type: "phone", ProviderSubject: "+8613800138000", DemoCode: str(DemoCode)})
			if err != nil {
				t.Fatal(err)
			}
			bound, err := b.auth.BindIdentity(ctx, BindInput{
				SessionToken: phone.Session.Token,
				LoginInput:   LoginInput{Type: "google", ProviderSubject: "google-sub-9", Email: str("walker@example.com")},
			})
			if err != nil {
				t.Fatal(err)
			}
			if bound.Merged || bound.User.ID != phone.User.ID {
				t.Fatalf("%#v", bound)
			}
			identities, err := b.auth.ListIdentities(ctx, phone.Session.Token)
			if err != nil {
				t.Fatal(err)
			}
			types := map[string]bool{}
			for _, item := range identities {
				types[item.Type] = true
			}
			if len(identities) != 2 || !types["google"] || !types["phone"] {
				t.Fatalf("%#v", identities)
			}
		}},
		{"is a no-op when the identity is already on the current user", func(t *testing.T) {
			phone, err := b.auth.LoginOrRegister(ctx, LoginInput{Type: "phone", ProviderSubject: "+8613800138000", DemoCode: str(DemoCode)})
			if err != nil {
				t.Fatal(err)
			}
			again, err := b.auth.BindIdentity(ctx, BindInput{
				SessionToken: phone.Session.Token,
				LoginInput:   LoginInput{Type: "phone", ProviderSubject: "13800138000", DemoCode: str(DemoCode)},
			})
			if err != nil {
				t.Fatal(err)
			}
			identities, err := b.auth.ListIdentities(ctx, phone.Session.Token)
			if err != nil {
				t.Fatal(err)
			}
			if again.Merged || again.User.ID != phone.User.ID || len(identities) != 1 {
				t.Fatalf("again %#v identities %d", again, len(identities))
			}
		}},
		{"merges into the earlier account when the bound identity belongs to someone else", func(t *testing.T) {
			earlier, err := b.auth.LoginOrRegister(ctx, LoginInput{Type: "wechat", ProviderSubject: "openid-early", DisplayName: str("早的账号")})
			if err != nil {
				t.Fatal(err)
			}
			if err := b.repo.InsertRecord(ctx, OwnedRecord{ID: "record-early", UserID: earlier.User.ID, Kind: "note", Payload: map[string]any{"text": "early"}}); err != nil {
				t.Fatal(err)
			}
			b.time.advance(60 * time.Second)
			later, err := b.auth.LoginOrRegister(ctx, LoginInput{Type: "google", ProviderSubject: "google-late", Email: str("late@example.com"), DisplayName: str("晚的账号")})
			if err != nil {
				t.Fatal(err)
			}
			if err := b.repo.InsertRecord(ctx, OwnedRecord{ID: "record-late", UserID: later.User.ID, Kind: "note", Payload: map[string]any{"text": "late"}}); err != nil {
				t.Fatal(err)
			}
			merged, err := b.auth.BindIdentity(ctx, BindInput{
				SessionToken: later.Session.Token,
				LoginInput:   LoginInput{Type: "wechat", ProviderSubject: "openid-early"},
			})
			if err != nil {
				t.Fatal(err)
			}
			if !merged.Merged || merged.User.ID != earlier.User.ID || merged.User.DisplayName != "早的账号" || merged.User.Email != "late@example.com" {
				t.Fatalf("merged user %#v", merged.User)
			}
			if merged.Session.UserID != earlier.User.ID || merged.Session.Token != later.Session.Token {
				t.Fatalf("session %#v", merged.Session)
			}
			users, err := b.repo.ListUsers(ctx)
			if err != nil {
				t.Fatal(err)
			}
			var loser *User
			var kept *User
			for i := range users {
				if users[i].ID == later.User.ID {
					loser = &users[i]
				}
				if users[i].ID == earlier.User.ID {
					kept = &users[i]
				}
			}
			if loser == nil || loser.RetiredAt == nil || loser.MergedIntoUserID == nil || *loser.MergedIntoUserID != earlier.User.ID {
				t.Fatalf("loser %#v", loser)
			}
			if kept == nil || kept.Email != "late@example.com" {
				t.Fatalf("kept %#v", kept)
			}
			identities, err := b.repo.ListIdentities(ctx)
			if err != nil {
				t.Fatal(err)
			}
			records, err := b.repo.ListRecords(ctx)
			if err != nil {
				t.Fatal(err)
			}
			if len(identities) != 2 || identities[0].UserID != earlier.User.ID || identities[1].UserID != earlier.User.ID {
				t.Fatalf("identities %#v", identities)
			}
			if len(records) != 2 || records[0].UserID != earlier.User.ID || records[1].UserID != earlier.User.ID {
				t.Fatalf("records %#v", records)
			}
			fromWechat, err := b.auth.LoginOrRegister(ctx, LoginInput{Type: "wechat", ProviderSubject: "openid-early"})
			if err != nil {
				t.Fatal(err)
			}
			fromGoogle, err := b.auth.LoginOrRegister(ctx, LoginInput{Type: "google", ProviderSubject: "google-late"})
			if err != nil {
				t.Fatal(err)
			}
			if fromWechat.User.ID != earlier.User.ID || fromGoogle.User.ID != earlier.User.ID || fromGoogle.Created {
				t.Fatalf("relogin %#v %#v", fromWechat, fromGoogle)
			}
		}},
		{"keeps the earlier current user when binding a newer account's identity", func(t *testing.T) {
			b.time.set("2026-03-01T00:00:00.000Z")
			earlier, err := b.auth.LoginOrRegister(ctx, LoginInput{Type: "phone", ProviderSubject: "+8613900139000", DemoCode: str(DemoCode), DisplayName: str("主账号")})
			if err != nil {
				t.Fatal(err)
			}
			b.time.advance(5 * time.Second)
			if _, err := b.auth.LoginOrRegister(ctx, LoginInput{Type: "wechat", ProviderSubject: "openid-new", DisplayName: str("新微信")}); err != nil {
				t.Fatal(err)
			}
			merged, err := b.auth.BindIdentity(ctx, BindInput{
				SessionToken: earlier.Session.Token,
				LoginInput:   LoginInput{Type: "wechat", ProviderSubject: "openid-new"},
			})
			if err != nil {
				t.Fatal(err)
			}
			if !merged.Merged || merged.User.ID != earlier.User.ID || merged.Session.UserID != earlier.User.ID {
				t.Fatalf("%#v", merged)
			}
			users, err := b.repo.ListUsers(ctx)
			if err != nil {
				t.Fatal(err)
			}
			var retired []User
			for _, user := range users {
				if user.RetiredAt != nil {
					retired = append(retired, user)
				}
			}
			if len(retired) != 1 || retired[0].MergedIntoUserID == nil || *retired[0].MergedIntoUserID != earlier.User.ID {
				t.Fatalf("%#v", retired)
			}
			identities, err := b.auth.ListIdentities(ctx, earlier.Session.Token)
			if err != nil {
				t.Fatal(err)
			}
			if len(identities) != 2 {
				t.Fatalf("%#v", identities)
			}
		}},
		{"breaks an identical createdAt tie by the smaller user id", func(t *testing.T) {
			seq := []string{"user-m", "user-a"}
			cursor := 0
			auth := NewService(ServiceOptions{
				Repo: b.repo,
				Demo: true,
				Now:  b.time.now,
				NewID: func() string {
					current := cursor
					cursor++
					if current < len(seq) {
						return seq[current]
					}
					return fmt.Sprintf("id-%d", cursor)
				},
			})
			first, err := auth.LoginOrRegister(ctx, LoginInput{Type: "wechat", ProviderSubject: "openid-m"})
			if err != nil {
				t.Fatal(err)
			}
			second, err := auth.LoginOrRegister(ctx, LoginInput{Type: "google", ProviderSubject: "google-a"})
			if err != nil {
				t.Fatal(err)
			}
			if first.User.CreatedAt != second.User.CreatedAt {
				t.Fatalf("created %s %s", first.User.CreatedAt, second.User.CreatedAt)
			}
			smaller := first.User.ID
			if second.User.ID < smaller {
				smaller = second.User.ID
			}
			merged, err := auth.BindIdentity(ctx, BindInput{
				SessionToken: first.Session.Token,
				LoginInput:   LoginInput{Type: "google", ProviderSubject: "google-a"},
			})
			if err != nil {
				t.Fatal(err)
			}
			if merged.User.ID != smaller {
				t.Fatalf("got %s want %s", merged.User.ID, smaller)
			}
			users, err := b.repo.ListUsers(ctx)
			if err != nil {
				t.Fatal(err)
			}
			var retired *User
			for i := range users {
				if users[i].RetiredAt != nil {
					retired = &users[i]
				}
			}
			if retired == nil || retired.MergedIntoUserID == nil || *retired.MergedIntoUserID != smaller || retired.ID == smaller {
				t.Fatalf("%#v", retired)
			}
		}},
		{"removes an identity only when another one remains", func(t *testing.T) {
			phone, err := b.auth.LoginOrRegister(ctx, LoginInput{Type: "phone", ProviderSubject: "+8613800138000", DemoCode: str(DemoCode)})
			if err != nil {
				t.Fatal(err)
			}
			if _, err := b.auth.BindIdentity(ctx, BindInput{SessionToken: phone.Session.Token, LoginInput: LoginInput{Type: "google", ProviderSubject: "google-sub-2"}}); err != nil {
				t.Fatal(err)
			}
			if err := b.auth.UnbindIdentity(ctx, UnbindInput{SessionToken: phone.Session.Token, Type: "google", ProviderSubject: "google-sub-2"}); err != nil {
				t.Fatal(err)
			}
			identities, err := b.auth.ListIdentities(ctx, phone.Session.Token)
			if err != nil {
				t.Fatal(err)
			}
			if len(identities) != 1 || identities[0].Type != "phone" {
				t.Fatalf("%#v", identities)
			}
			err = b.auth.UnbindIdentity(ctx, UnbindInput{SessionToken: phone.Session.Token, Type: "phone", ProviderSubject: "+8613800138000"})
			if !codeIs(err, "last_identity") {
				t.Fatal(err)
			}
			identities, err = b.auth.ListIdentities(ctx, phone.Session.Token)
			if err != nil || len(identities) != 1 {
				t.Fatal(err, identities)
			}
		}},
		{"does not list or unbind identities for a missing session", func(t *testing.T) {
			if _, err := b.auth.ListIdentities(ctx, "missing"); !codeIs(err, "not_authenticated") {
				t.Fatal(err)
			}
			err := b.auth.UnbindIdentity(ctx, UnbindInput{SessionToken: "missing", Type: "phone", ProviderSubject: "+8613800138000"})
			if !codeIs(err, "not_authenticated") {
				t.Fatal(err)
			}
		}},
		{"drops a session on logout and after it expires", func(t *testing.T) {
			n := 0
			auth := NewService(ServiceOptions{
				Repo:       b.repo,
				Demo:       true,
				Now:        b.time.now,
				NewID:      func() string { n++; return fmt.Sprintf("exp-%d", n) },
				SessionTTL: time.Second,
			})
			phone, err := auth.LoginOrRegister(ctx, LoginInput{Type: "phone", ProviderSubject: "+8613700137000", DemoCode: str(DemoCode)})
			if err != nil {
				t.Fatal(err)
			}
			if err := auth.Logout(ctx, phone.Session.Token); err != nil {
				t.Fatal(err)
			}
			if _, err := auth.ListIdentities(ctx, phone.Session.Token); !codeIs(err, "not_authenticated") {
				t.Fatal(err)
			}
			again, err := auth.LoginOrRegister(ctx, LoginInput{Type: "phone", ProviderSubject: "+8613700137000", DemoCode: str(DemoCode)})
			if err != nil {
				t.Fatal(err)
			}
			b.time.advance(1001 * time.Millisecond)
			if _, err := auth.ListIdentities(ctx, again.Session.Token); !codeIs(err, "not_authenticated") {
				t.Fatal(err)
			}
		}},
		{"uses provider results and ignores client-supplied subjects", func(t *testing.T) {
			productionCases(t, b)
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			b.reset()
			test.fn(t)
		})
	}
}

func productionCases(t *testing.T, b *backend) {
	t.Helper()
	ctx := context.Background()
	var sent []struct{ Phone, Code string }
	keys := googleKey(t)
	redirect := "https://api.sky-wanderer.online/v1/auth/google/callback"
	clientID := "sky-ios.apps.googleusercontent.com"
	idToken := signJWT(t, keys.key, map[string]any{
		"iss":            "https://accounts.google.com",
		"aud":            clientID,
		"sub":            "google-real",
		"exp":            2_000_000_000,
		"email":          "walker@example.com",
		"email_verified": true,
		"name":           "Walker",
		"nonce":          "nonce-1",
	})
	n := 0
	auth := NewService(ServiceOptions{
		Repo: b.repo,
		Demo: false,
		Now:  b.time.now,
		NewID: func() string {
			n++
			return fmt.Sprintf("prod-%d", n)
		},
		SMS: smsFunc(func(_ context.Context, phone, code string) error {
			sent = append(sent, struct{ Phone, Code string }{phone, code})
			return nil
		}),
		WeChat:             &WeChatApp{AppID: "wx-app", AppSecret: "wx-secret"},
		GoogleClientIDs:    []string{clientID},
		GoogleClientSecret: "google-secret",
		GoogleRedirectURIs: []string{redirect},
		LoadGoogleCerts:    func(context.Context) ([]JWK, error) { return []JWK{keys.jwk}, nil },
		Fetch: func(_ context.Context, rawURL string, init *FetchInit) (*http.Response, error) {
			if strings.Contains(rawURL, "oauth2.googleapis.com/token") {
				body := ""
				if init != nil {
					body = init.Body
				}
				if !strings.Contains(body, "google-secret") || !strings.Contains(body, "code-from-google") {
					t.Fatalf("token body %s", body)
				}
				return jsonResponse(200, map[string]string{"id_token": idToken}), nil
			}
			if strings.Contains(rawURL, "/sns/oauth2/access_token") {
				if !strings.Contains(rawURL, "code=wechat-code") || !strings.Contains(rawURL, "secret=wx-secret") {
					t.Fatalf("wechat url %s", rawURL)
				}
				return jsonResponse(200, map[string]string{"openid": "openid-from-wechat", "access_token": "at"}), nil
			}
			if strings.Contains(rawURL, "/sns/userinfo") {
				return jsonResponse(200, map[string]string{"nickname": "阿天"}), nil
			}
			return nil, fmt.Errorf("unexpected fetch %s", rawURL)
		},
	})
	if _, err := auth.SendPhoneCode(ctx, "13800138000"); err != nil {
		t.Fatal(err)
	}
	if _, err := auth.SendPhoneCode(ctx, "13800138000"); !codeIs(err, "sms_rate_limited") {
		t.Fatal(err)
	}
	b.time.advance(61 * time.Second)
	issued, err := auth.SendPhoneCode(ctx, "+86 138-0013-8000")
	if err != nil {
		t.Fatal(err)
	}
	if issued.Phone != "+8613800138000" || issued.DemoCode != nil || len(sent) == 0 || sent[len(sent)-1].Phone != "+8613800138000" {
		t.Fatalf("issued %#v sent %#v", issued, sent)
	}
	if _, err := auth.LoginOrRegister(ctx, LoginInput{Type: "phone", ProviderSubject: "13800138000", SmsCode: str("000000")}); !codeIs(err, "invalid_sms_code") {
		t.Fatal(err)
	}
	phone, err := auth.LoginOrRegister(ctx, LoginInput{Type: "phone", ProviderSubject: "13800138000", SmsCode: str(sent[len(sent)-1].Code)})
	if err != nil || !phone.Created {
		t.Fatal(err, phone.Created)
	}
	if _, err := auth.LoginOrRegister(ctx, LoginInput{Type: "phone", ProviderSubject: "+8613800138000", SmsCode: str(sent[len(sent)-1].Code)}); !codeIs(err, "invalid_sms_code") {
		t.Fatal(err)
	}
	if _, err := auth.LoginOrRegister(ctx, LoginInput{Type: "wechat", ProviderSubject: "client-openid"}); !codeIs(err, "invalid_subject") {
		t.Fatal(err)
	}
	wechat, err := auth.LoginOrRegister(ctx, LoginInput{Type: "wechat", ProviderSubject: "client-openid", AuthorizationCode: str("wechat-code"), DisplayName: str("伪造")})
	if err != nil {
		t.Fatal(err)
	}
	if wechat.User.DisplayName != "阿天" {
		t.Fatalf("display %s", wechat.User.DisplayName)
	}
	identities, err := auth.ListIdentities(ctx, wechat.Session.Token)
	if err != nil || len(identities) != 1 || identities[0].ProviderSubject != "openid-from-wechat" {
		t.Fatal(err, identities)
	}
	if _, err := auth.LoginOrRegister(ctx, LoginInput{Type: "google", ProviderSubject: "client-sub"}); !codeIs(err, "invalid_subject") {
		t.Fatal(err)
	}
	google, err := auth.LoginOrRegister(ctx, LoginInput{
		Type:            "google",
		ProviderSubject: "client-sub",
		Email:           str("evil@example.com"),
		IDToken:         str(idToken),
		Nonce:           str("nonce-1"),
	})
	if err != nil {
		t.Fatal(err)
	}
	if google.User.Email != "walker@example.com" || google.User.DisplayName != "Walker" {
		t.Fatalf("%#v", google.User)
	}
	identities, err = auth.ListIdentities(ctx, google.Session.Token)
	if err != nil || identities[0].ProviderSubject != "google-real" {
		t.Fatal(err, identities)
	}
	exchanged, err := auth.LoginOrRegister(ctx, LoginInput{
		Type:              "google",
		AuthorizationCode: str("code-from-google"),
		CodeVerifier:      str("verifier-1"),
		RedirectURI:       str(redirect),
		ClientID:          str(clientID),
		Nonce:             str("nonce-1"),
	})
	if err != nil || exchanged.Created || exchanged.User.ID != google.User.ID {
		t.Fatal(err, exchanged)
	}
	bare := NewService(ServiceOptions{Repo: b.repo, Demo: false, Now: b.time.now})
	if _, err := bare.SendPhoneCode(ctx, "+8613800138000"); !codeIs(err, "sms_not_configured") {
		t.Fatal(err)
	}
}

type smsFunc func(context.Context, string, string) error

func (f smsFunc) Send(ctx context.Context, phone, code string) error { return f(ctx, phone, code) }

func str(value string) *string { return &value }

func codeIs(err error, code string) bool {
	auth, ok := err.(*AuthError)
	return ok && auth.Code == code
}
