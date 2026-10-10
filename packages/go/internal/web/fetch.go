package web

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// FetchInit is what fetch's init says, where it applies.
type FetchInit struct {
	Method  string
	Headers *Headers
	Body    []byte
	// Redirect is follow (the default), manual, which hands back the 3xx answer, or error.
	Redirect string
	// Timeout is the whole request's limit, 30 seconds when zero.
	Timeout time.Duration
	// MaxBytes stops reading past this many bytes of the answer and fails
	// with ErrBodyTooLong, or with Truncate, hands back the first MaxBytes.
	// Zero is DefaultMaxBytes.
	MaxBytes int64
	Truncate bool
	// PublicOnly connects only to addresses on the public internet, checking
	// the address the connection uses, so a name that answers differently a
	// moment later gets nowhere.
	PublicOnly bool
}

// Fetcher makes outgoing requests, the stand-in for fetch(). Everything that
// calls another server (mail services, importers, connected installs, the
// assistant's providers, site icons) goes through one, so tests can pass a
// fake.
type Fetcher interface {
	// Fetch fails with a *FetchError when no answer comes back (refused, timed out, bad TLS).
	Fetch(ctx context.Context, url string, init FetchInit) (*Response, error)
}

// FetchFunc is a function as a Fetcher.
type FetchFunc func(ctx context.Context, url string, init FetchInit) (*Response, error)

// Fetch calls the function.
func (f FetchFunc) Fetch(ctx context.Context, url string, init FetchInit) (*Response, error) {
	return f(ctx, url, init)
}

// FetchError is a request that got no answer: fetch's TypeError, or with
// Timeout set, the timeout's TimeoutError.
type FetchError struct {
	Message string
	Timeout bool
}

func (e *FetchError) Error() string { return e.Message }

// DefaultMaxBytes is the most an answer may weigh when the request names no
// limit, enough for a connected install's largest export, so no server can
// stream an answer into memory without end.
const DefaultMaxBytes = 100 * 1024 * 1024

// ErrBodyTooLong is an answer longer than the reader allows.
var ErrBodyTooLong = errors.New("body too long")

// BodyTooLong is ErrBodyTooLong with the limit in its message.
func BodyTooLong(max int64) error {
	return fmt.Errorf("Body over %d bytes: %w", max, ErrBodyTooLong)
}

// PrivateAddressError is a request refused before anything was fetched,
// because the address is not on the public internet.
type PrivateAddressError struct{ What string }

func (e *PrivateAddressError) Error() string { return e.What + " is not a public address" }

// IsTimeout reports whether err is a request that ran out of time.
func IsTimeout(err error) bool {
	var f *FetchError
	return errors.As(err, &f) && f.Timeout
}

// HTTPFetcher is the Fetcher over net/http.
type HTTPFetcher struct {
	// Client is used for requests that may go anywhere; nil is a client of its own.
	Client *http.Client
}

var (
	plainTransport  = &http.Transport{Proxy: http.ProxyFromEnvironment, ForceAttemptHTTP2: true, MaxIdleConns: 50, IdleConnTimeout: 90 * time.Second, TLSHandshakeTimeout: 10 * time.Second}
	publicTransport = &http.Transport{ForceAttemptHTTP2: true, MaxIdleConns: 20, IdleConnTimeout: 90 * time.Second, TLSHandshakeTimeout: 10 * time.Second,
		DialContext: (&net.Dialer{Timeout: 15 * time.Second, Control: publicOnly}).DialContext}
)

// publicOnly refuses a connection to an address off the public internet.
func publicOnly(network, address string, _ syscall.RawConn) error {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		host = address
	}
	if !PublicAddress(host) {
		return &PrivateAddressError{host}
	}
	return nil
}

// Fetch makes the request.
func (f HTTPFetcher) Fetch(ctx context.Context, url string, init FetchInit) (*Response, error) {
	timeout := init.Timeout
	if timeout <= 0 {
		timeout = 30 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	method := strings.ToUpper(init.Method)
	if method == "" {
		method = "GET"
	}
	var body io.Reader
	if init.Body != nil && method != "GET" && method != "HEAD" {
		body = bytes.NewReader(init.Body)
	}
	req, err := http.NewRequestWithContext(ctx, method, url, body)
	if err != nil {
		return nil, &FetchError{Message: "fetch failed"}
	}
	init.Headers.Each(func(name, value string) {
		if name == "host" {
			req.Host = value
			return
		}
		req.Header.Add(name, value)
	})
	client := f.Client
	if client == nil || init.PublicOnly {
		transport := http.RoundTripper(plainTransport)
		if init.PublicOnly {
			transport = publicTransport
		}
		client = &http.Client{Transport: transport}
	}
	c := *client
	switch init.Redirect {
	case "manual", "error":
		c.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	default:
		c.CheckRedirect = func(_ *http.Request, via []*http.Request) error {
			if len(via) >= 20 {
				return errors.New("redirect count exceeded")
			}
			return nil
		}
	}
	answer, err := c.Do(req)
	if err != nil {
		var private *PrivateAddressError
		if errors.As(err, &private) {
			return nil, private
		}
		if ctx.Err() != nil {
			return nil, &FetchError{Message: "The operation was aborted due to timeout", Timeout: true}
		}
		return nil, &FetchError{Message: "fetch failed"}
	}
	defer answer.Body.Close()
	if init.Redirect == "error" && answer.StatusCode >= 300 && answer.StatusCode < 400 {
		return nil, &FetchError{Message: "fetch failed"}
	}
	out := &Response{Status: answer.StatusCode, Header: &Headers{}, URL: answer.Request.URL.String()}
	for name, values := range answer.Header {
		for _, v := range values {
			out.Header.Append(name, v)
		}
	}
	limit := init.MaxBytes
	if limit <= 0 {
		limit = DefaultMaxBytes
	}
	if n, err := strconv.ParseInt(answer.Header.Get("content-length"), 10, 64); err == nil && n > limit && !init.Truncate {
		return nil, BodyTooLong(limit)
	}
	b, err := io.ReadAll(io.LimitReader(answer.Body, limit+1))
	if int64(len(b)) > limit {
		if !init.Truncate {
			return nil, BodyTooLong(limit)
		}
		b = b[:limit]
	} else if err != nil && !init.Truncate {
		return nil, readError(ctx, err)
	}
	out.Body = b
	return out, nil
}

func readError(ctx context.Context, err error) error {
	if ctx.Err() != nil {
		return &FetchError{Message: "The operation was aborted due to timeout", Timeout: true}
	}
	return &FetchError{Message: "fetch failed"}
}
