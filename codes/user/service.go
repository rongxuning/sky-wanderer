package user

import (
	"context"
	"crypto/rand"
	"fmt"
	"math"
	"math/big"
	"strings"
	"time"
)

type LoginInput struct {
	Type              string
	ProviderSubject   string
	DemoCode          *string
	SmsCode           *string
	AuthorizationCode *string
	IDToken           *string
	CodeVerifier      *string
	RedirectURI       *string
	ClientID          *string
	Nonce             *string
	DisplayName       *string
	Email             *string
	Phone             *string
}

type LoginResult struct {
	User    User
	Session Session
	Created bool
}

type BindInput struct {
	LoginInput
	SessionToken string
}

type BindResult struct {
	User    User
	Session Session
	Merged  bool
}

type UnbindInput struct {
	SessionToken    string
	Type            string
	ProviderSubject string
}

type PhoneCodeResult struct {
	Phone            string  `json:"phone"`
	ExpiresInSeconds int     `json:"expiresInSeconds"`
	DemoCode         *string `json:"demoCode,omitempty"`
}

type Service struct {
	repo        Repository
	now         func() time.Time
	newID       func() string
	demo        bool
	sms         SMSSender
	fetch       Fetcher
	pepper      string
	sessionTTL  time.Duration
	codeTTL     time.Duration
	resendAfter time.Duration
	maxAttempts int
	randomCode  func() string
	wechat      *WeChatApp
	google      *googleChecker
}

type ServiceOptions struct {
	Repo               Repository
	Now                func() time.Time
	NewID              func() string
	Demo               bool
	SMS                SMSSender
	Fetch              Fetcher
	CodePepper         string
	SessionTTL         time.Duration
	CodeTTL            time.Duration
	ResendAfter        time.Duration
	MaxAttempts        int
	RandomCode         func() string
	WeChat             *WeChatApp
	GoogleClientIDs    []string
	GoogleClientSecret string
	GoogleRedirectURIs []string
	LoadGoogleCerts    func(context.Context) ([]JWK, error)
}

func NewService(options ServiceOptions) *Service {
	now := options.Now
	if now == nil {
		now = time.Now
	}
	newIdentifier := options.NewID
	if newIdentifier == nil {
		newIdentifier = newID
	}
	fetch := options.Fetch
	if fetch == nil {
		fetch = DefaultFetch
	}
	sessionTTL := options.SessionTTL
	if sessionTTL <= 0 {
		sessionTTL = 30 * 24 * time.Hour
	}
	codeTTL := options.CodeTTL
	if codeTTL <= 0 {
		codeTTL = 5 * time.Minute
	}
	resendAfter := options.ResendAfter
	if resendAfter <= 0 {
		resendAfter = time.Minute
	}
	maxAttempts := options.MaxAttempts
	if maxAttempts <= 0 {
		maxAttempts = 5
	}
	randomCode := options.RandomCode
	if randomCode == nil {
		randomCode = defaultRandomCode
	}
	return &Service{
		repo:        options.Repo,
		now:         now,
		newID:       newIdentifier,
		demo:        options.Demo,
		sms:         options.SMS,
		fetch:       fetch,
		pepper:      options.CodePepper,
		sessionTTL:  sessionTTL,
		codeTTL:     codeTTL,
		resendAfter: resendAfter,
		maxAttempts: maxAttempts,
		randomCode:  randomCode,
		wechat:      options.WeChat,
		google: &googleChecker{
			clientIDs:    options.GoogleClientIDs,
			clientSecret: options.GoogleClientSecret,
			redirectURIs: options.GoogleRedirectURIs,
			fetch:        fetch,
			now:          now,
			loadCerts:    options.LoadGoogleCerts,
		},
	}
}

func (s *Service) SendPhoneCode(ctx context.Context, phone string) (PhoneCodeResult, error) {
	subject, err := CanonicalSubject("phone", phone)
	if err != nil {
		return PhoneCodeResult{}, err
	}
	seconds := int(math.Round(s.codeTTL.Seconds()))
	if s.sms == nil {
		if s.demo {
			code := DemoCode
			return PhoneCodeResult{Phone: subject, ExpiresInSeconds: seconds, DemoCode: &code}, nil
		}
		return PhoneCodeResult{}, &AuthError{Code: "sms_not_configured", Message: "SMS is not configured. Set SMS_PROVIDER and its credentials."}
	}
	var existing *PhoneCode
	err = s.repo.InTx(ctx, func(tx Repository) error {
		var findErr error
		existing, findErr = tx.FindPhoneCode(ctx, subject)
		return findErr
	})
	if err != nil {
		return PhoneCodeResult{}, err
	}
	if existing != nil {
		sent, ok := ParseTime(existing.SentAt)
		if ok && sent.Add(s.resendAfter).After(s.now()) {
			return PhoneCodeResult{}, &AuthError{Code: "sms_rate_limited", Message: "Wait before requesting another SMS code"}
		}
	}
	code := s.randomCode()
	if err := s.sms.Send(ctx, subject, code); err != nil {
		return PhoneCodeResult{}, err
	}
	sentAt := FormatTime(s.now())
	err = s.repo.InTx(ctx, func(tx Repository) error {
		return tx.SavePhoneCode(ctx, PhoneCode{
			Phone:     subject,
			CodeHash:  codeHash(s.pepper, code),
			ExpiresAt: FormatTime(s.now().Add(s.codeTTL)),
			Attempts:  0,
			SentAt:    sentAt,
		})
	})
	if err != nil {
		return PhoneCodeResult{}, err
	}
	return PhoneCodeResult{Phone: subject, ExpiresInSeconds: seconds}, nil
}

func (s *Service) LoginOrRegister(ctx context.Context, input LoginInput) (LoginResult, error) {
	prepared, err := s.prepare(ctx, input)
	if err != nil {
		return LoginResult{}, err
	}
	var result LoginResult
	err = s.run(ctx, func(tx Repository) error {
		if err := s.withCode(ctx, tx, prepared); err != nil {
			return err
		}
		var loadErr error
		result, loadErr = s.insertOrLoad(ctx, tx, prepared)
		return loadErr
	})
	return result, err
}

func (s *Service) BindIdentity(ctx context.Context, input BindInput) (BindResult, error) {
	prepared, err := s.prepare(ctx, input.LoginInput)
	if err != nil {
		return BindResult{}, err
	}
	var result BindResult
	err = s.run(ctx, func(tx Repository) error {
		session, err := s.requireSession(ctx, tx, input.SessionToken)
		if err != nil {
			return err
		}
		current, err := s.activeUser(ctx, tx, session.UserID)
		if err != nil {
			return err
		}
		if err := s.withCode(ctx, tx, prepared); err != nil {
			return err
		}
		var bindErr error
		result, bindErr = s.bindPrepared(ctx, tx, input.SessionToken, current, prepared)
		return bindErr
	})
	return result, err
}

func (s *Service) ListIdentities(ctx context.Context, sessionToken string) ([]Identity, error) {
	var identities []Identity
	err := s.repo.InTx(ctx, func(tx Repository) error {
		session, err := s.requireSession(ctx, tx, sessionToken)
		if err != nil {
			return err
		}
		user, err := s.activeUser(ctx, tx, session.UserID)
		if err != nil {
			return err
		}
		identities, err = tx.ListIdentitiesByUser(ctx, user.ID)
		return err
	})
	return identities, err
}

func (s *Service) UnbindIdentity(ctx context.Context, input UnbindInput) error {
	return s.repo.InTx(ctx, func(tx Repository) error {
		session, err := s.requireSession(ctx, tx, input.SessionToken)
		if err != nil {
			return err
		}
		user, err := s.activeUser(ctx, tx, session.UserID)
		if err != nil {
			return err
		}
		subject, err := CanonicalSubject(input.Type, input.ProviderSubject)
		if err != nil {
			return err
		}
		owned, err := tx.ListIdentitiesByUser(ctx, user.ID)
		if err != nil {
			return err
		}
		var target *Identity
		for i := range owned {
			if owned[i].Type == input.Type && owned[i].ProviderSubject == subject {
				target = &owned[i]
				break
			}
		}
		if target == nil {
			return &AuthError{Code: "identity_not_found", Message: "identity is not on this account"}
		}
		if len(owned) <= 1 {
			return &AuthError{Code: "last_identity", Message: "at least one identity must remain on the account"}
		}
		return tx.DeleteIdentity(ctx, target.ID)
	})
}

func (s *Service) Logout(ctx context.Context, sessionToken string) error {
	return s.repo.DeleteSession(ctx, sessionToken)
}

type prepared struct {
	Type        string
	Subject     string
	Email       string
	DisplayName string
	Phone       string
	SmsCode     string
	DemoBypass  bool
}

func (s *Service) prepare(ctx context.Context, input LoginInput) (prepared, error) {
	if input.Type == "phone" {
		subject, err := CanonicalSubject("phone", input.ProviderSubject)
		if err != nil {
			return prepared{}, err
		}
		smsCode := strings.TrimSpace(coalesce(input.SmsCode, input.DemoCode))
		return prepared{
			Type:        "phone",
			Subject:     subject,
			Email:       deref(input.Email),
			DisplayName: deref(input.DisplayName),
			Phone:       subject,
			SmsCode:     smsCode,
			DemoBypass:  s.demo && smsCode == DemoCode,
		}, nil
	}
	if input.Type == "wechat" {
		code := ""
		if input.AuthorizationCode != nil {
			code = strings.TrimSpace(*input.AuthorizationCode)
		}
		if code != "" {
			app := WeChatApp{}
			if s.wechat != nil {
				app = *s.wechat
			}
			profile, err := exchangeWeChat(ctx, app, code, s.fetch)
			if err != nil {
				return prepared{}, err
			}
			subject, err := CanonicalSubject("wechat", profile.Subject)
			if err != nil {
				return prepared{}, err
			}
			return prepared{Type: "wechat", Subject: subject, DisplayName: profile.DisplayName}, nil
		}
		if s.demo && strings.TrimSpace(input.ProviderSubject) != "" {
			subject, err := CanonicalSubject("wechat", input.ProviderSubject)
			if err != nil {
				return prepared{}, err
			}
			return prepared{
				Type:        "wechat",
				Subject:     subject,
				DisplayName: deref(input.DisplayName),
				Email:       deref(input.Email),
				Phone:       deref(input.Phone),
			}, nil
		}
		message := "WeChat login requires an authorization code"
		if s.demo {
			message = "provider subject is required"
		}
		return prepared{}, &AuthError{Code: "invalid_subject", Message: message}
	}
	googleInput := GoogleCheckInput{
		IDToken:           deref(input.IDToken),
		AuthorizationCode: deref(input.AuthorizationCode),
		CodeVerifier:      deref(input.CodeVerifier),
		RedirectURI:       deref(input.RedirectURI),
		ClientID:          deref(input.ClientID),
		Nonce:             deref(input.Nonce),
	}
	if strings.TrimSpace(googleInput.IDToken) != "" || strings.TrimSpace(googleInput.AuthorizationCode) != "" {
		profile, err := s.google.check(ctx, googleInput)
		if err != nil {
			return prepared{}, err
		}
		subject, err := CanonicalSubject("google", profile.Subject)
		if err != nil {
			return prepared{}, err
		}
		return prepared{Type: "google", Subject: subject, Email: profile.Email, DisplayName: profile.DisplayName}, nil
	}
	if s.demo && strings.TrimSpace(input.ProviderSubject) != "" {
		subject, err := CanonicalSubject("google", input.ProviderSubject)
		if err != nil {
			return prepared{}, err
		}
		return prepared{
			Type:        "google",
			Subject:     subject,
			DisplayName: deref(input.DisplayName),
			Email:       deref(input.Email),
			Phone:       deref(input.Phone),
		}, nil
	}
	message := "Google login requires an ID token"
	if s.demo {
		message = "provider subject is required"
	}
	return prepared{}, &AuthError{Code: "invalid_subject", Message: message}
}

func (s *Service) withCode(ctx context.Context, store Repository, item prepared) error {
	if item.Type == "phone" && !item.DemoBypass {
		return s.consumeCode(ctx, store, item.Subject, item.SmsCode)
	}
	return nil
}

func (s *Service) consumeCode(ctx context.Context, store Repository, phone, code string) error {
	hashed := codeHash(s.pepper, code)
	row, err := store.FindPhoneCode(ctx, phone)
	if err != nil {
		return err
	}
	if row == nil {
		if s.demo {
			return &AuthError{Code: "invalid_demo_code", Message: "phone demo code must be SKY-LOCAL"}
		}
		return &AuthError{Code: "invalid_sms_code", Message: "SMS code is incorrect"}
	}
	if expiredAt(row.ExpiresAt, s.now()) {
		if err := store.DeletePhoneCode(ctx, phone); err != nil {
			return err
		}
		return &AuthError{Code: "sms_expired", Message: "SMS code has expired"}
	}
	match := hashEqual(row.CodeHash, hashed)
	if row.Attempts >= s.maxAttempts || !match {
		attempts := row.Attempts
		if !match {
			attempts++
		}
		if attempts >= s.maxAttempts {
			if err := store.DeletePhoneCode(ctx, phone); err != nil {
				return err
			}
		} else if err := store.SetPhoneCodeAttempts(ctx, phone, attempts); err != nil {
			return err
		}
		return &AuthError{Code: "invalid_sms_code", Message: "SMS code is incorrect"}
	}
	return store.DeletePhoneCode(ctx, phone)
}

func (s *Service) insertOrLoad(ctx context.Context, store Repository, item prepared) (LoginResult, error) {
	existing, err := store.FindIdentity(ctx, item.Type, item.Subject)
	if err != nil {
		return LoginResult{}, err
	}
	if existing != nil {
		user, err := s.activeUser(ctx, store, existing.UserID)
		if err != nil {
			return LoginResult{}, err
		}
		if existing.UserID != user.ID {
			if err := store.UpdateIdentityUser(ctx, existing.ID, user.ID); err != nil {
				return LoginResult{}, err
			}
		}
		session, err := s.openSession(ctx, store, user.ID)
		if err != nil {
			return LoginResult{}, err
		}
		return LoginResult{User: user, Session: session, Created: false}, nil
	}
	createdAt := FormatTime(s.now())
	email := NormalizeEmail(item.Email)
	user := User{
		ID:                s.newID(),
		CreatedAt:         createdAt,
		DisplayName:       displayNameFor(item, email),
		Email:             email,
		MergedFromUserIDs: []string{},
	}
	identity := Identity{
		ID:              s.newID(),
		Type:            item.Type,
		ProviderSubject: item.Subject,
		Email:           stringPtr(email),
		Phone:           identityPhone(item),
		UserID:          user.ID,
		CreatedAt:       createdAt,
	}
	if err := store.InsertUser(ctx, user); err != nil {
		return LoginResult{}, err
	}
	if err := store.InsertIdentity(ctx, identity); err != nil {
		return LoginResult{}, err
	}
	session, err := s.openSession(ctx, store, user.ID)
	if err != nil {
		return LoginResult{}, err
	}
	return LoginResult{User: user, Session: session, Created: true}, nil
}

func (s *Service) bindPrepared(ctx context.Context, store Repository, token string, current User, item prepared) (BindResult, error) {
	existing, err := store.FindIdentity(ctx, item.Type, item.Subject)
	if err != nil {
		return BindResult{}, err
	}
	if existing != nil {
		owner, err := s.activeUser(ctx, store, existing.UserID)
		if err != nil {
			return BindResult{}, err
		}
		if existing.UserID != owner.ID {
			if err := store.UpdateIdentityUser(ctx, existing.ID, owner.ID); err != nil {
				return BindResult{}, err
			}
		}
		if owner.ID == current.ID {
			session, err := s.requireSession(ctx, store, token)
			if err != nil {
				return BindResult{}, err
			}
			if session.UserID != current.ID {
				if err := store.UpdateSessionUser(ctx, token, current.ID); err != nil {
					return BindResult{}, err
				}
				session.UserID = current.ID
			}
			return BindResult{User: current, Session: session, Merged: false}, nil
		}
		master, err := s.mergeUsers(ctx, store, current.ID, owner.ID)
		if err != nil {
			return BindResult{}, err
		}
		live, err := s.requireSession(ctx, store, token)
		if err != nil {
			return BindResult{}, err
		}
		return BindResult{User: master, Session: live, Merged: true}, nil
	}
	email := NormalizeEmail(item.Email)
	if err := store.InsertIdentity(ctx, Identity{
		ID:              s.newID(),
		Type:            item.Type,
		ProviderSubject: item.Subject,
		Email:           stringPtr(email),
		Phone:           identityPhone(item),
		UserID:          current.ID,
		CreatedAt:       FormatTime(s.now()),
	}); err != nil {
		return BindResult{}, err
	}
	if email != "" && strings.TrimSpace(current.Email) == "" {
		current.Email = email
		if err := store.UpdateUser(ctx, current); err != nil {
			return BindResult{}, err
		}
	}
	session, err := s.requireSession(ctx, store, token)
	if err != nil {
		return BindResult{}, err
	}
	return BindResult{User: current, Session: session, Merged: false}, nil
}

func (s *Service) mergeUsers(ctx context.Context, store Repository, leftID, rightID string) (User, error) {
	left, err := s.activeUser(ctx, store, leftID)
	if err != nil {
		return User{}, err
	}
	right, err := s.activeUser(ctx, store, rightID)
	if err != nil {
		return User{}, err
	}
	if left.ID == right.ID {
		return left, nil
	}
	leftTime, leftOK := ParseTime(left.CreatedAt)
	rightTime, rightOK := ParseTime(right.CreatedAt)
	rightEarlier := false
	if leftOK && rightOK {
		rightEarlier = rightTime.Before(leftTime) || (rightTime.Equal(leftTime) && right.ID < left.ID)
	}
	master, loser := left, right
	if rightEarlier {
		master, loser = right, left
	}
	if err := store.ReassignUserData(ctx, loser.ID, master.ID); err != nil {
		return User{}, err
	}
	if strings.TrimSpace(master.DisplayName) == "" && strings.TrimSpace(loser.DisplayName) != "" {
		master.DisplayName = loser.DisplayName
	}
	if strings.TrimSpace(master.Email) == "" && strings.TrimSpace(loser.Email) != "" {
		master.Email = loser.Email
	}
	merged := append(cloneStringSlice(master.MergedFromUserIDs), loser.ID)
	merged = append(merged, loser.MergedFromUserIDs...)
	master.MergedFromUserIDs = merged
	retired := FormatTime(s.now())
	masterID := master.ID
	loser.RetiredAt = &retired
	loser.MergedIntoUserID = &masterID
	if err := store.UpdateUser(ctx, master); err != nil {
		return User{}, err
	}
	if err := store.UpdateUser(ctx, loser); err != nil {
		return User{}, err
	}
	return master, nil
}

func (s *Service) requireSession(ctx context.Context, store Repository, token string) (Session, error) {
	found, err := store.FindSession(ctx, token)
	if err != nil {
		return Session{}, err
	}
	if found == nil || expiredAt(found.ExpiresAt, s.now()) {
		return Session{}, &AuthError{Code: "not_authenticated", Message: "session is missing or expired"}
	}
	return Session{Token: token, UserID: found.UserID, CreatedAt: found.CreatedAt}, nil
}

func (s *Service) activeUser(ctx context.Context, store Repository, userID string) (User, error) {
	seen := map[string]struct{}{}
	current := userID
	for {
		user, err := store.FindUser(ctx, current)
		if err != nil {
			return User{}, err
		}
		if user == nil {
			return User{}, &AuthError{Code: "user_missing", Message: "account does not exist"}
		}
		if user.RetiredAt == nil || *user.RetiredAt == "" {
			if user.MergedFromUserIDs == nil {
				user.MergedFromUserIDs = []string{}
			}
			return *user, nil
		}
		if user.MergedIntoUserID == nil || *user.MergedIntoUserID == "" {
			return User{}, &AuthError{Code: "user_missing", Message: "account does not exist"}
		}
		if _, ok := seen[user.ID]; ok {
			return User{}, &AuthError{Code: "user_missing", Message: "account does not exist"}
		}
		seen[user.ID] = struct{}{}
		current = *user.MergedIntoUserID
	}
}

func (s *Service) openSession(ctx context.Context, store Repository, userID string) (Session, error) {
	createdAt := FormatTime(s.now())
	session := Session{Token: s.newID(), UserID: userID, CreatedAt: createdAt}
	err := store.InsertSession(ctx, NewSession{
		Token:     session.Token,
		UserID:    userID,
		CreatedAt: createdAt,
		ExpiresAt: FormatTime(s.now().Add(s.sessionTTL)),
	})
	if err != nil {
		return Session{}, err
	}
	return session, nil
}

func (s *Service) run(ctx context.Context, fn func(Repository) error) error {
	err := s.repo.InTx(ctx, fn)
	if err == nil || !IsConflict(err) {
		return err
	}
	return s.repo.InTx(ctx, fn)
}

func displayNameFor(item prepared, email string) string {
	if given := strings.TrimSpace(item.DisplayName); given != "" {
		return given
	}
	switch item.Type {
	case "wechat":
		return "微信用户"
	case "google":
		local := email
		if i := strings.IndexByte(email, '@'); i >= 0 {
			local = email[:i]
		}
		if local != "" {
			return local
		}
		return "Google 用户"
	default:
		tail := item.Subject
		if len(tail) > 4 {
			tail = tail[len(tail)-4:]
		}
		return "手机 " + tail
	}
}

func identityPhone(item prepared) *string {
	if item.Type == "phone" {
		return stringPtr(item.Subject)
	}
	return stringPtr(strings.TrimSpace(item.Phone))
}

func coalesce(primary, fallback *string) string {
	if primary != nil {
		return *primary
	}
	if fallback != nil {
		return *fallback
	}
	return ""
}

func deref(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}

func newID() string {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return fmt.Sprintf("id-%d", time.Now().UnixNano())
	}
	raw[6] = (raw[6] & 0x0f) | 0x40
	raw[8] = (raw[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", raw[0:4], raw[4:6], raw[6:8], raw[8:10], raw[10:])
}

func defaultRandomCode() string {
	n, err := rand.Int(rand.Reader, big.NewInt(1_000_000))
	if err != nil {
		return "000000"
	}
	return fmt.Sprintf("%06d", n.Int64())
}
