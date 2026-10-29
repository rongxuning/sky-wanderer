package user

import (
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"
)

type SMSSender interface {
	Send(ctx context.Context, phone, code string) error
}

func NewSMSSender(config SMSConfig, fetch Fetcher, now func() time.Time, nonce func() string) SMSSender {
	if fetch == nil {
		fetch = DefaultFetch
	}
	if now == nil {
		now = time.Now
	}
	if nonce == nil {
		nonce = newID
	}
	provider := strings.ToLower(strings.TrimSpace(config.Provider))
	if provider == "" {
		return nil
	}
	if provider == "http" {
		if config.HTTPURL == "" {
			return newFailingSMS("SMS_HTTP_URL is required when SMS_PROVIDER=http")
		}
		return httpSMS{config: config, fetch: fetch}
	}
	if provider == "aliyun" {
		if config.AliyunAccessKeyID == "" || config.AliyunAccessKeySecret == "" || config.AliyunSignName == "" || config.AliyunTemplateCode == "" {
			return newFailingSMS("Aliyun SMS needs ALIYUN_SMS_ACCESS_KEY_ID, ALIYUN_SMS_ACCESS_KEY_SECRET, ALIYUN_SMS_SIGN_NAME, and ALIYUN_SMS_TEMPLATE_CODE")
		}
		return aliyunSMS{
			accessKeyID:     config.AliyunAccessKeyID,
			accessKeySecret: config.AliyunAccessKeySecret,
			signName:        config.AliyunSignName,
			templateCode:    config.AliyunTemplateCode,
			fetch:           fetch,
			now:             now,
			nonce:           nonce,
		}
	}
	return newFailingSMS(fmt.Sprintf("Unknown SMS_PROVIDER %q. Use http or aliyun.", config.Provider))
}

type failingSMS struct{ message string }

func newFailingSMS(message string) SMSSender { return failingSMS{message: message} }

func (s failingSMS) Send(context.Context, string, string) error {
	return &AuthError{Code: "sms_not_configured", Message: s.message}
}

type httpSMS struct {
	config SMSConfig
	fetch  Fetcher
}

func (s httpSMS) Send(ctx context.Context, phone, code string) error {
	raw, err := json.Marshal(orderedSMSPayload(phone, code, s.config.AliyunSignName, s.config.AliyunTemplateCode))
	if err != nil {
		return err
	}
	header := make(http.Header)
	header.Set("content-type", "application/json")
	if s.config.HTTPToken != "" {
		header.Set("authorization", "Bearer "+s.config.HTTPToken)
	}
	resp, err := s.fetch(ctx, s.config.HTTPURL, &FetchInit{Method: http.MethodPost, Header: header, Body: string(raw)})
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return &AuthError{Code: "sms_failed", Message: fmt.Sprintf("SMS provider rejected the message (%d)", resp.StatusCode)}
	}
	return nil
}

type smsJSON struct {
	Phone        string `json:"phone"`
	Code         string `json:"code"`
	SignName     string `json:"signName,omitempty"`
	TemplateCode string `json:"templateCode,omitempty"`
}

func orderedSMSPayload(phone, code, signName, template string) smsJSON {
	return smsJSON{Phone: phone, Code: code, SignName: signName, TemplateCode: template}
}

type aliyunSMS struct {
	accessKeyID     string
	accessKeySecret string
	signName        string
	templateCode    string
	fetch           Fetcher
	now             func() time.Time
	nonce           func() string
}

func (s aliyunSMS) Send(ctx context.Context, phone, code string) error {
	template, err := json.Marshal(struct {
		Code string `json:"code"`
	}{Code: code})
	if err != nil {
		return err
	}
	params := map[string]string{
		"AccessKeyId":      s.accessKeyID,
		"Action":           "SendSms",
		"Format":           "JSON",
		"PhoneNumbers":     phone,
		"RegionId":         "cn-hangzhou",
		"SignName":         s.signName,
		"SignatureMethod":  "HMAC-SHA1",
		"SignatureNonce":   s.nonce(),
		"SignatureVersion": "1.0",
		"TemplateCode":     s.templateCode,
		"TemplateParam":    string(template),
		"Timestamp":        s.now().UTC().Format("2006-01-02T15:04:05Z"),
		"Version":          "2017-05-25",
	}
	params["Signature"] = aliyunSign(params, s.accessKeySecret)
	form := url.Values{}
	for key, value := range params {
		form.Set(key, value)
	}
	header := make(http.Header)
	header.Set("content-type", "application/x-www-form-urlencoded; charset=UTF-8")
	resp, err := s.fetch(ctx, "https://dysmsapi.aliyuncs.com/", &FetchInit{
		Method: http.MethodPost,
		Header: header,
		Body:   form.Encode(),
	})
	if err != nil {
		return err
	}
	var payload struct {
		Code    string `json:"Code"`
		Message string `json:"Message"`
	}
	decodeJSON(resp, &payload)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 || payload.Code != "OK" {
		return &AuthError{Code: "sms_failed", Message: "Aliyun SMS rejected the message"}
	}
	return nil
}

func aliyunSign(params map[string]string, secret string) string {
	keys := make([]string, 0, len(params))
	for key := range params {
		if key == "Signature" {
			continue
		}
		keys = append(keys, key)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, key := range keys {
		parts = append(parts, aliyunEncode(key)+"="+aliyunEncode(params[key]))
	}
	canonical := strings.Join(parts, "&")
	stringToSign := "POST&" + aliyunEncode("/") + "&" + aliyunEncode(canonical)
	mac := hmac.New(sha1.New, []byte(secret+"&"))
	_, _ = mac.Write([]byte(stringToSign))
	return base64.StdEncoding.EncodeToString(mac.Sum(nil))
}

func aliyunEncode(value string) string {
	var b strings.Builder
	for i := 0; i < len(value); i++ {
		c := value[i]
		if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~' {
			b.WriteByte(c)
			continue
		}
		fmt.Fprintf(&b, "%%%02X", c)
	}
	return b.String()
}
