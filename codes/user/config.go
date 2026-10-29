package user

import (
	"fmt"
	"math"
	"os"
	"strconv"
	"strings"
	"time"
)

type SMSConfig struct {
	Provider              string
	HTTPURL               string
	HTTPToken             string
	AliyunAccessKeyID     string
	AliyunAccessKeySecret string
	AliyunSignName        string
	AliyunTemplateCode    string
}

type Config struct {
	Demo                bool
	DatabaseURL         string
	DatabaseURLUnpooled string
	Port                int
	DataFile            string
	APIHost             string
	CodePepper          string
	SessionTTL          time.Duration
	SMS                 SMSConfig
	WeChatAppID         string
	WeChatAppSecret     string
	GoogleClientIDs     []string
	GoogleClientSecret  string
	GoogleRedirectURIs  []string
}

func LoadConfig(getenv func(string) string) (Config, error) {
	if getenv == nil {
		getenv = os.Getenv
	}
	demo := getenv("AUTH_DEMO") == "1"
	databaseURL := strings.TrimSpace(getenv("DATABASE_URL"))
	if !demo && databaseURL == "" {
		return Config{}, fmt.Errorf("DATABASE_URL is required unless AUTH_DEMO=1")
	}
	apiHost := strings.TrimSpace(getenv("SKY_API_HOST"))
	if apiHost == "" {
		apiHost = "api.sky-wanderer.online"
	}
	redirectRaw := strings.TrimSpace(getenv("GOOGLE_REDIRECT_URIS"))
	var redirects []string
	if redirectRaw == "" {
		redirects = []string{"https://" + apiHost + "/v1/auth/google/callback"}
	} else {
		redirects = splitList(redirectRaw)
	}
	dataFile := strings.TrimSpace(getenv("DATA_FILE"))
	if dataFile == "" {
		dataFile = "data/auth-store.json"
	}
	return Config{
		Demo:                demo,
		DatabaseURL:         databaseURL,
		DatabaseURLUnpooled: strings.TrimSpace(getenv("DATABASE_URL_UNPOOLED")),
		Port:                portFrom(getenv("PORT")),
		DataFile:            dataFile,
		APIHost:             apiHost,
		CodePepper:          strings.TrimSpace(getenv("AUTH_CODE_PEPPER")),
		SessionTTL:          sessionTTL(getenv("SESSION_TTL_DAYS")),
		SMS: SMSConfig{
			Provider:              strings.TrimSpace(getenv("SMS_PROVIDER")),
			HTTPURL:               strings.TrimSpace(getenv("SMS_HTTP_URL")),
			HTTPToken:             strings.TrimSpace(getenv("SMS_HTTP_TOKEN")),
			AliyunAccessKeyID:     strings.TrimSpace(getenv("ALIYUN_SMS_ACCESS_KEY_ID")),
			AliyunAccessKeySecret: strings.TrimSpace(getenv("ALIYUN_SMS_ACCESS_KEY_SECRET")),
			AliyunSignName:        strings.TrimSpace(getenv("ALIYUN_SMS_SIGN_NAME")),
			AliyunTemplateCode:    strings.TrimSpace(getenv("ALIYUN_SMS_TEMPLATE_CODE")),
		},
		WeChatAppID:        strings.TrimSpace(getenv("WECHAT_APP_ID")),
		WeChatAppSecret:    strings.TrimSpace(getenv("WECHAT_APP_SECRET")),
		GoogleClientIDs:    splitList(getenv("GOOGLE_CLIENT_IDS")),
		GoogleClientSecret: strings.TrimSpace(getenv("GOOGLE_CLIENT_SECRET")),
		GoogleRedirectURIs: redirects,
	}, nil
}

func portFrom(raw string) int {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return 8787
	}
	port, err := strconv.Atoi(raw)
	if err != nil || port < 0 {
		return 8787
	}
	return port
}

func sessionTTL(raw string) time.Duration {
	days := 30.0
	raw = strings.TrimSpace(raw)
	if raw != "" {
		parsed, err := strconv.ParseFloat(raw, 64)
		if err == nil && !math.IsNaN(parsed) && !math.IsInf(parsed, 0) && parsed > 0 {
			days = parsed
		}
	}
	return time.Duration(days * float64(24*time.Hour))
}

func splitList(value string) []string {
	parts := strings.Split(value, ",")
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part != "" {
			out = append(out, part)
		}
	}
	return out
}
