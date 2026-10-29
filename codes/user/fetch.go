package user

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"
)

type FetchInit struct {
	Method string
	Header http.Header
	Body   string
}

type Fetcher func(ctx context.Context, rawURL string, init *FetchInit) (*http.Response, error)

func DefaultFetch(ctx context.Context, rawURL string, init *FetchInit) (*http.Response, error) {
	method := http.MethodGet
	var body io.Reader
	header := http.Header{}
	if init != nil {
		if init.Method != "" {
			method = init.Method
		}
		if init.Body != "" {
			body = strings.NewReader(init.Body)
		}
		if init.Header != nil {
			header = init.Header.Clone()
		}
	}
	req, err := http.NewRequestWithContext(ctx, method, rawURL, body)
	if err != nil {
		return nil, err
	}
	req.Header = header
	client := &http.Client{
		Timeout: 20 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return errors.New("redirects are not allowed")
		},
	}
	return client.Do(req)
}

func decodeJSON(resp *http.Response, dest any) {
	if resp == nil || resp.Body == nil {
		return
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil || len(raw) == 0 {
		return
	}
	_ = json.Unmarshal(raw, dest)
}
