package mail

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"testing"

	"runlight.sh/go/internal/fixture"
	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/web"
	"runlight.sh/go/internal/whatwg"
)

// Ports mail.test.ts by way of the PHP port's MailTest, and replays
// packages/php/tests/fixtures/outbound.json: every service sends the
// TypeScript SDK's exact requests.

var message = Message{
	To: "jon@example.com", From: "reports@example.com", FromName: "Runlight", Subject: "Hello", HTML: "<p>Hi</p>", Text: "Hi",
	Headers: js.NewObject("List-Unsubscribe", "<https://x/u>"),
}

// recorder is a Fetcher that records every request, as the TS fixtures record them: lowercase
// header names in order, as iterating Fetch Headers gives them.
type recorder struct {
	requests []any
	answer   func() (*web.Response, error)
}

func (r *recorder) Fetch(_ context.Context, url string, init web.FetchInit) (*web.Response, error) {
	headers := js.NewObject()
	init.Headers.Each(func(name, value string) { headers.Set(name, value) })
	r.requests = append(r.requests, js.NewObject("method", init.Method, "url", url, "headers", headers, "body", string(init.Body)))
	return r.answer()
}

func capture(status int) *recorder {
	body := "{}"
	if status != 200 {
		body = "nope"
	}
	return &recorder{answer: func() (*web.Response, error) { return web.NewResponse(status, []byte(body)), nil }}
}

func (r *recorder) request(i int) *js.Object { return r.requests[i].(*js.Object) }

func (r *recorder) header(i int, name string) string {
	return js.Str(js.Dig(r.request(i), "headers", name))
}

func (r *recorder) body(i int) string { return js.Str(js.Dig(r.request(i), "body")) }

// counting is a UUID stand-in that counts from 1, as the fixture script's does.
func counting() func() string {
	n := 0
	return func() string {
		n++
		return fmt.Sprintf("00000000-0000-4000-8000-%012d", n)
	}
}

func outbound(t *testing.T) *js.Object { return js.Obj(fixture.PHP(t, "outbound.json")) }

func messageFrom(v any) Message {
	o := js.Obj(v)
	m := Message{
		To: js.Str(js.Dig(o, "to")), From: js.Str(js.Dig(o, "from")), FromName: js.Str(js.Dig(o, "fromName")),
		Subject: js.Str(js.Dig(o, "subject")), HTML: js.Str(js.Dig(o, "html")), Text: js.Str(js.Dig(o, "text")),
	}
	if h, ok := o.Get("headers"); ok {
		m.Headers = js.Obj(h)
	}
	return m
}

func configFrom(v any) Config {
	c := Config{}
	js.Obj(v).Each(func(k string, v any) { c[k] = js.Str(v) })
	return c
}

func errorValue(err error) any {
	if err == nil {
		return nil
	}
	var e *MailError
	if !errors.As(err, &e) {
		return "not a MailError: " + err.Error()
	}
	return js.NewObject("message", e.Message, "code", e.Code, "params", e.Params)
}

func mustMatch(t *testing.T, pattern string, err error) {
	t.Helper()
	var e *MailError
	if !errors.As(err, &e) {
		t.Fatalf("expected a MailError matching %s, got %v", pattern, err)
	}
	if !regexp.MustCompile(pattern).MatchString(e.Message) {
		t.Fatalf("%q does not match %s", e.Message, pattern)
	}
}

func TestSealedKeysOpenOnlyWithTheSameSecret(t *testing.T) {
	sealed := Seal(`{"apiKey":"re_123"}`, "server secret")
	if !strings.HasPrefix(sealed, "v1:") || strings.Contains(sealed, "re_123") {
		t.Fatal(sealed)
	}
	if v, ok := Unseal(sealed, "server secret"); !ok || v != `{"apiKey":"re_123"}` {
		t.Fatal(v, ok)
	}
	if _, ok := Unseal(sealed, "another secret"); ok {
		t.Fatal("opened with another secret")
	}
	if v, ok := Unseal(Seal("x", ""), ""); !ok || v != "x" {
		t.Fatal("with no secret the value is kept as typed", v, ok)
	}
	for _, bad := range []string{"v1:AAAA:AAAA", "v2:a:b", "v1::abc", "v1:abc", "v1:!!!!:AAAA"} {
		if _, ok := Unseal(bad, "server secret"); ok {
			t.Fatal("damaged opened:", bad)
		}
	}
	if _, ok := Unseal(sealed, ""); ok {
		t.Fatal("opened with no secret")
	}
}

func TestKeysSealedByTypeScriptOpenHere(t *testing.T) {
	cases := js.Arr(outbound(t).Value("sealed"))
	for _, c := range cases {
		secret, sealed := js.Str(js.Dig(c, "secret")), js.Str(js.Dig(c, "sealed"))
		// A value of null is one TypeScript refuses to open.
		if js.Dig(c, "value") == nil {
			if v, ok := Unseal(sealed, secret); ok {
				t.Errorf("%q opened as %q", sealed, v)
			}
			continue
		}
		value := js.Str(js.Dig(c, "value"))
		if v, ok := Unseal(sealed, secret); !ok || v != value {
			t.Errorf("unseal %q: %q %v", sealed, v, ok)
		}
		if _, ok := Unseal(sealed, secret+"!"); ok {
			t.Errorf("%q opened with the wrong secret", sealed)
		}
		if v, ok := Unseal(Seal(value, secret), secret); !ok || v != value {
			t.Errorf("round trip of %q: %q %v", value, v, ok)
		}
	}
	if len(cases) != 5 {
		t.Fatalf("%d sealed cases", len(cases))
	}
}

func TestUnsealReadsBase64AsAtobDoes(t *testing.T) {
	sealed := Seal("hello", "s")
	parts := strings.Split(sealed, ":")
	spaced := "v1: " + parts[1] + "\n:" + strings.TrimRight(parts[2], "=") + ":extra"
	if v, ok := Unseal(spaced, "s"); !ok || v != "hello" {
		t.Fatal("whitespace, missing padding, and a fourth part are all fine to atob and split", v, ok)
	}
	// Web Crypto refuses an IV under 12 bytes, so a short one never opens.
	short := "v1:" + base64.StdEncoding.EncodeToString(make([]byte, 8)) + ":" + parts[2]
	if _, ok := Unseal(short, "s"); ok {
		t.Fatal("an 8 byte IV opened")
	}
}

func TestSigV4MatchesAWSPublishedExample(t *testing.T) {
	// https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html (the IAM ListUsers example)
	headers, err := SignV4(SignInput{
		Method: "GET", URL: whatwg.MustParse("https://iam.amazonaws.com/?Action=ListUsers&Version=2010-05-08"), Body: "",
		Region: "us-east-1", Service: "iam", AccessKeyID: "AKIDEXAMPLE", SecretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
		Now: js.DateUTC(2015, 7, 30, 12, 36, 0, 0), Headers: js.NewObject("content-type", "application/x-www-form-urlencoded; charset=utf-8"),
	})
	if err != nil {
		t.Fatal(err)
	}
	want := "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/iam/aws4_request, SignedHeaders=content-type;host;x-amz-date, Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7"
	if got := js.Str(headers.Value("authorization")); got != want {
		t.Fatal(got)
	}
}

func TestSigV4MatchesTypeScript(t *testing.T) {
	for _, c := range js.Arr(outbound(t).Value("signatures")) {
		in := js.Obj(js.Dig(c, "input"))
		url, err := whatwg.Parse(js.Str(in.Value("url")))
		if err != nil {
			t.Fatal(err)
		}
		headers, err := SignV4(SignInput{
			Method: js.Str(in.Value("method")), URL: url, Body: js.Str(in.Value("body")), Region: js.Str(in.Value("region")),
			Service: js.Str(in.Value("service")), AccessKeyID: js.Str(in.Value("accessKeyId")), SecretAccessKey: js.Str(in.Value("secretAccessKey")),
			Now: int64(js.Num(in.Value("now"))), Headers: js.Obj(in.Value("headers")),
		})
		if err != nil {
			t.Fatal(err)
		}
		if got, want := js.Stringify(headers), js.Stringify(js.Dig(c, "headers")); got != want {
			t.Errorf("%s\n got %s\nwant %s", in.Value("url"), got, want)
		}
	}
}

func TestSigV4FailsOnABrokenEscapeAsDecodeURIComponentDoes(t *testing.T) {
	_, err := SignV4(SignInput{Method: "GET", URL: whatwg.MustParse("https://example.com/a%E0%A4%A"), Now: 0})
	if err == nil || err.Error() != "URI malformed" {
		t.Fatal(err)
	}
}

func TestEachServiceGetsTheRequestItDocuments(t *testing.T) {
	ctx := context.Background()
	calls := capture(200)
	if err := Send(ctx, calls, Config{"service": "resend", "apiKey": "re_1"}, message); err != nil {
		t.Fatal(err)
	}
	if js.Str(js.Dig(calls.request(0), "url")) != "https://api.resend.com/emails" || calls.header(0, "authorization") != "Bearer re_1" {
		t.Fatal(js.Stringify(calls.requests))
	}
	body, _ := js.Parse(calls.body(0))
	if js.Stringify(js.Dig(body, "to")) != `["jon@example.com"]` || js.Str(js.Dig(body, "from")) != "Runlight <reports@example.com>" {
		t.Fatal(calls.body(0))
	}

	calls = capture(200)
	if err := Send(ctx, calls, Config{"service": "postmark", "serverToken": "pm"}, message); err != nil {
		t.Fatal(err)
	}
	body, _ = js.Parse(calls.body(0))
	if calls.header(0, "x-postmark-server-token") != "pm" || js.Str(js.Dig(body, "MessageStream")) != "outbound" {
		t.Fatal(js.Stringify(calls.requests))
	}

	calls = capture(200)
	if err := Send(ctx, calls, Config{"service": "mailgun", "apiKey": "key", "domain": "mg.example.com", "region": "eu"}, message); err != nil {
		t.Fatal(err)
	}
	if js.Str(js.Dig(calls.request(0), "url")) != "https://api.eu.mailgun.net/v3/mg.example.com/messages" ||
		calls.header(0, "authorization") != "Basic "+base64.StdEncoding.EncodeToString([]byte("api:key")) ||
		whatwg.ParseQuery(calls.body(0)).Value("h:List-Unsubscribe") != "<https://x/u>" {
		t.Fatal(js.Stringify(calls.requests))
	}

	calls = capture(200)
	if err := Send(ctx, calls, Config{"service": "ses", "region": "eu-west-1", "accessKeyId": "AKID", "secretAccessKey": "secret"}, message); err != nil {
		t.Fatal(err)
	}
	if js.Str(js.Dig(calls.request(0), "url")) != "https://email.eu-west-1.amazonaws.com/v2/email/outbound-emails" ||
		!regexp.MustCompile(`^AWS4-HMAC-SHA256 Credential=AKID/\d{8}/eu-west-1/ses/aws4_request`).MatchString(calls.header(0, "authorization")) {
		t.Fatal(js.Stringify(calls.requests))
	}

	calls = capture(200)
	if err := Send(ctx, calls, Config{"service": "webhook", "url": "https://hooks.example.com/mail", "secret": "s"}, message); err != nil {
		t.Fatal(err)
	}
	if !regexp.MustCompile(`^sha256=[a-f0-9]{64}$`).MatchString(calls.header(0, "x-runlight-signature")) {
		t.Fatal(js.Stringify(calls.requests))
	}

	refused := capture(401)
	mustMatch(t, `api.sendgrid.com answered 401`, Send(ctx, refused, Config{"service": "sendgrid", "apiKey": "bad"}, message))
	mustMatch(t, `must use https`, Send(ctx, refused, Config{"service": "webhook", "url": "http://example.com/x"}, message))
	mustMatch(t, `Enter the api key`, Send(ctx, refused, Config{"service": "resend"}, message))
}

func TestEveryServiceSendsTheTypeScriptRequestsExactly(t *testing.T) {
	f := outbound(t)
	now := int64(js.Num(f.Value("now")))
	cases := js.Arr(f.Value("mail"))
	for i, c := range cases {
		answer := js.Dig(c, "answer")
		fetcher := &recorder{answer: func() (*web.Response, error) {
			if answer == "unreachable" {
				return nil, &web.FetchError{Message: "fetch failed"}
			}
			return web.NewResponse(int(js.Num(js.Dig(answer, "status"))), []byte(js.Str(js.Dig(answer, "body")))), nil
		}}
		config := configFrom(js.Dig(c, "config"))
		err := SendWith(context.Background(), fetcher, config, messageFrom(js.Dig(c, "message")), Options{Now: func() int64 { return now }})
		requests := fetcher.requests
		if requests == nil {
			requests = []any{}
		}
		label := fmt.Sprintf("case %d: %s", i, js.Stringify(js.Dig(c, "config")))
		if got, want := js.Stringify(requests), js.Stringify(js.Dig(c, "requests")); got != want {
			t.Errorf("%s requests\n got %s\nwant %s", label, got, want)
		}
		if got, want := js.Stringify(errorValue(err)), js.Stringify(js.Dig(c, "error")); got != want {
			t.Errorf("%s error\n got %s\nwant %s", label, got, want)
		}
	}
	if len(cases) != 56 {
		t.Fatalf("%d mail cases", len(cases))
	}
}

func TestServiceMessagesMatchTypeScript(t *testing.T) {
	for _, c := range js.Arr(outbound(t).Value("replies")) {
		if got, want := ServiceMessage(js.Str(js.Dig(c, "reply"))), js.Str(js.Dig(c, "message")); got != want {
			t.Errorf("%q: got %q, want %q", js.Dig(c, "reply"), got, want)
		}
	}
	// [^<]{1,200} counts UTF-16 code units, so 100 emoji fit and 101 do not.
	if got := ServiceMessage("<Message>" + strings.Repeat("😀", 100) + "</Message>"); got != strings.Repeat("😀", 100) {
		t.Error("100 emoji", got)
	}
	if got := ServiceMessage("<Message>" + strings.Repeat("😀", 101) + "</Message><Message>b</Message>"); got != "b" {
		t.Error("the first that fits", got)
	}
	if got := ServiceMessage(`{"message":"` + strings.Repeat("😀", 101) + `"}`); got != strings.Repeat("😀", 100) {
		t.Error("200 code units", got)
	}
}

func TestMimeMatchesTypeScript(t *testing.T) {
	for _, c := range js.Arr(outbound(t).Value("mimes")) {
		got := Mime(messageFrom(js.Dig(c, "message")), js.Str(js.Dig(c, "from")), int64(js.Num(js.Dig(c, "now"))), counting())
		if want := js.Str(js.Dig(c, "mime")); got != want {
			t.Errorf("got  %q\nwant %q", got, want)
		}
	}
	m := message
	m.Subject = "Café report"
	raw := Mime(m, "Runlight <reports@example.com>", 0, nil)
	if !regexp.MustCompile(`Subject: =\?UTF-8\?B\?`).MatchString(raw) ||
		!regexp.MustCompile(`boundary="rl-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"`).MatchString(raw) {
		t.Fatal(raw)
	}
}

func TestNamedAddressMatchesTheRegex(t *testing.T) {
	for from, want := range map[string]string{
		"Runlight <a@b>": "Runlight |a@b",
		"a <b> <c@d>":    "a <b> |c@d",
		"x<>>":           "x|>",
		"<>":             "",
		"<a>":            "|a",
		"plain@example":  "",
		"Line  <a@b>":    "",
	} {
		name, address, ok := namedAddress(from)
		got := ""
		if ok {
			got = name + "|" + address
		}
		if got != want {
			t.Errorf("%q: got %q, want %q", from, got, want)
		}
	}
}

func TestErrorsCarryCodesAndParams(t *testing.T) {
	e := NewMailError("Something")
	if e.Code != "mail_failed" || js.Stringify(e.Params) != `{"detail":"Something"}` || e.Error() != "Something" {
		t.Fatal(e)
	}
	if Services[0].ID != "ses" {
		t.Fatal(Services[0])
	}
	want := `{"id":"smtp","name":"SMTP","fields":[{"name":"host","label":"Host","placeholder":"smtp.example.com"},{"name":"port","label":"Port","placeholder":"587"},{"name":"security","label":"Security","options":["starttls","tls","none"]},{"name":"username","label":"Username","optional":true},{"name":"password","label":"Password","secret":true,"optional":true}]}`
	if got := js.Stringify(Services[9]); got != want {
		t.Fatal(got)
	}
}

func TestCheckConfigAndBadInput(t *testing.T) {
	ok := []Config{
		{"service": "webhook", "url": "http://127.0.0.1:8080"},
		{"service": "webhook", "url": "http://localhost/x"},
		{"service": "smtp", "host": "h", "port": "25", "security": "none"},
	}
	for _, c := range ok {
		if err := CheckConfig(c); err != nil {
			t.Error(c, err)
		}
	}
	for _, url := range []string{"http://localhost:x", "http://localhost.evil.com", "http://127.0.0.1:80x", "ftp://x"} {
		if err := CheckConfig(Config{"service": "webhook", "url": url}); err == nil {
			t.Error(url, "passed")
		}
	}
	// btoa refuses a character past U+00FF, as it does in TypeScript.
	err := Send(context.Background(), capture(200), Config{"service": "mailjet", "apiKey": "kĀ", "secretKey": "s"}, message)
	if err == nil || err.Error() != "Invalid character" {
		t.Fatal(err)
	}
}
