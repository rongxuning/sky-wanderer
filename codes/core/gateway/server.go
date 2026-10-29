package gateway

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"strconv"

	"skywanderer/codes/user"
)

func ListenAndServe() error {
	cfg, err := user.LoadConfig(os.Getenv)
	if err != nil {
		return err
	}
	ctx := context.Background()
	var repo user.Repository
	var closeRepo func()
	store := "file"
	if cfg.DatabaseURL != "" {
		repo, closeRepo, err = user.OpenPostgres(ctx, cfg.DatabaseURL, cfg.DatabaseURLUnpooled)
		if err != nil {
			return err
		}
		store = "postgres"
	} else {
		repo, err = user.NewFileRepository(cfg.DataFile)
		if err != nil {
			return err
		}
	}
	if closeRepo != nil {
		defer closeRepo()
	}
	sms := user.NewSMSSender(cfg.SMS, nil, nil, nil)
	var wechat *user.WeChatApp
	if cfg.WeChatAppID != "" || cfg.WeChatAppSecret != "" {
		wechat = &user.WeChatApp{AppID: cfg.WeChatAppID, AppSecret: cfg.WeChatAppSecret}
	}
	auth := user.NewService(user.ServiceOptions{
		Repo:               repo,
		Demo:               cfg.Demo,
		SMS:                sms,
		CodePepper:         cfg.CodePepper,
		SessionTTL:         cfg.SessionTTL,
		WeChat:             wechat,
		GoogleClientIDs:    cfg.GoogleClientIDs,
		GoogleClientSecret: cfg.GoogleClientSecret,
		GoogleRedirectURIs: cfg.GoogleRedirectURIs,
	})
	handler := NewHandler(auth, func(ctx context.Context) error {
		if err := repo.Ping(ctx); err != nil {
			return &user.AuthError{Code: "db_unavailable", Message: "database is unavailable"}
		}
		return nil
	})
	smsName := cfg.SMS.Provider
	if smsName == "" {
		smsName = "unset"
	}
	addr := ":" + strconv.Itoa(cfg.Port)
	fmt.Printf("sky auth listening on %d (%s, demo=%t, sms=%s, host=%s)\n", cfg.Port, store, cfg.Demo, smsName, cfg.APIHost)
	return http.ListenAndServe(addr, handler)
}
