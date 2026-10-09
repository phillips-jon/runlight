// Package mail sends a site's mail through the service it picked (Amazon SES, Resend, Postmark,
// SendGrid, Mailgun, Brevo, Mailjet, MailerSend, SparkPost, SMTP, or a webhook), and seals the keys
// kept for them. It is a port of the TypeScript SDK's mail/ modules.
package mail

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/tls"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"math"
	"slices"
	"strings"
	"time"

	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/web"
	"runlight.sh/go/internal/whatwg"
)

// Message is one mail to send.
type Message struct {
	To       string
	From     string
	FromName string // "" when there is none, as undefined is in TypeScript
	Subject  string
	HTML     string
	Text     string
	// Headers are extra headers, such as List-Unsubscribe, in order; nil is none.
	Headers *js.Object
}

// MailError is a mail problem to show the person setting it up. Code and Params let the
// dashboard say it in its own language; a service's own words, which only it can give, travel
// in Params' detail.
type MailError struct {
	Message string
	Code    string
	Params  *js.Object
}

func (e *MailError) Error() string { return e.Message }

// NewMailError is `new MailError(message)`: code mail_failed, and params { detail: message }.
func NewMailError(message string) *MailError {
	return &MailError{Message: message, Code: "mail_failed", Params: js.NewObject("detail", message)}
}

func mailError(message, code string, params ...any) *MailError {
	return &MailError{Message: message, Code: code, Params: js.NewObject(params...)}
}

// Config is a service's settings: "service" plus its fields. Every value is a string, as typed
// in the dashboard; a field that is missing reads as "".
type Config map[string]string

// ServiceField is one setting a service needs.
type ServiceField struct {
	Name  string
	Label string
	// Secret fields are never sent back to the browser once saved.
	Secret      bool
	Options     []string
	Optional    bool
	Placeholder string
}

// JSValue writes the field as the TypeScript object literal does, leaving out what it leaves out.
func (f ServiceField) JSValue() any {
	o := js.NewObject("name", f.Name, "label", f.Label)
	if f.Secret {
		o.Set("secret", true)
	}
	if f.Options != nil {
		o.Set("options", f.Options)
	}
	if f.Optional {
		o.Set("optional", true)
	}
	if f.Placeholder != "" {
		o.Set("placeholder", f.Placeholder)
	}
	return o
}

// Service is a service Runlight can send through, and what it needs.
type Service struct {
	ID     string         `json:"id"`
	Name   string         `json:"name"`
	Fields []ServiceField `json:"fields"`
}

// Services are every service Runlight can send through, and what each needs.
var Services = []Service{
	{ID: "ses", Name: "Amazon SES", Fields: []ServiceField{
		{Name: "region", Label: "Region", Placeholder: "us-east-1"},
		{Name: "accessKeyId", Label: "Access key ID"},
		{Name: "secretAccessKey", Label: "Secret access key", Secret: true},
	}},
	{ID: "resend", Name: "Resend", Fields: []ServiceField{{Name: "apiKey", Label: "API key", Secret: true, Placeholder: "re_..."}}},
	{ID: "postmark", Name: "Postmark", Fields: []ServiceField{
		{Name: "serverToken", Label: "Server API token", Secret: true},
		{Name: "stream", Label: "Message stream", Optional: true, Placeholder: "outbound"},
	}},
	{ID: "sendgrid", Name: "SendGrid", Fields: []ServiceField{{Name: "apiKey", Label: "API key", Secret: true, Placeholder: "SG...."}}},
	{ID: "mailgun", Name: "Mailgun", Fields: []ServiceField{
		{Name: "domain", Label: "Sending domain", Placeholder: "mg.example.com"},
		{Name: "apiKey", Label: "API key", Secret: true},
		{Name: "region", Label: "Region", Options: []string{"us", "eu"}},
	}},
	{ID: "brevo", Name: "Brevo", Fields: []ServiceField{{Name: "apiKey", Label: "API key", Secret: true, Placeholder: "xkeysib-..."}}},
	{ID: "mailjet", Name: "Mailjet", Fields: []ServiceField{
		{Name: "apiKey", Label: "API key"},
		{Name: "secretKey", Label: "Secret key", Secret: true},
	}},
	{ID: "mailersend", Name: "MailerSend", Fields: []ServiceField{{Name: "apiKey", Label: "API token", Secret: true, Placeholder: "mlsn...."}}},
	{ID: "sparkpost", Name: "SparkPost", Fields: []ServiceField{
		{Name: "apiKey", Label: "API key", Secret: true},
		{Name: "region", Label: "Region", Options: []string{"us", "eu"}},
	}},
	{ID: "smtp", Name: "SMTP", Fields: []ServiceField{
		{Name: "host", Label: "Host", Placeholder: "smtp.example.com"},
		{Name: "port", Label: "Port", Placeholder: "587"},
		{Name: "security", Label: "Security", Options: []string{"starttls", "tls", "none"}},
		{Name: "username", Label: "Username", Optional: true},
		{Name: "password", Label: "Password", Secret: true, Optional: true},
	}},
	{ID: "webhook", Name: "Webhook", Fields: []ServiceField{
		{Name: "url", Label: "URL", Placeholder: "https://example.com/hooks/mail"},
		{Name: "secret", Label: "Signing secret", Secret: true, Optional: true},
	}},
}

// Address is the From address: `Name <address>` when there is a name, with the characters that
// would break out of it dropped.
func Address(m Message) string {
	if m.FromName == "" {
		return m.From
	}
	return strings.NewReplacer(`"`, "", `\`, "", "\r", "", "\n", "").Replace(m.FromName) + " <" + m.From + ">"
}

// ServiceMessage is the error a mail service explains itself with, from its JSON or XML reply,
// and never the raw body: a reply is shown to the dashboard, so an address that is not a mail
// service must not be able to put its page there.
func ServiceMessage(reply string) string {
	parsed, err := js.Parse(reply)
	// JSON.parse fails, or reading a field of null does, and either way the XML form is tried.
	if err != nil || parsed == nil {
		return xmlMessage(reply)
	}
	var first func(v any) string
	first = func(v any) string {
		switch t := v.(type) {
		case string:
			return t
		case []any:
			if len(t) == 0 {
				return ""
			}
			return first(t[0])
		case *js.Object:
			m, _ := t.Get("message")
			return first(m)
		}
		return ""
	}
	o, _ := parsed.(*js.Object)
	for _, name := range []string{"message", "Message", "error", "errors", "ErrorMessage"} {
		if o == nil {
			break
		}
		v, _ := o.Get(name)
		if text := first(v); text != "" {
			return js.Head16(text, 200)
		}
	}
	return ""
}

// xmlMessage is `/<Message>([^<]{1,200})<\/Message>/.exec(reply)?.[1]`, trimmed: the first
// <Message> holding 1 to 200 code units and no <.
func xmlMessage(reply string) string {
	const open, close = "<Message>", "</Message>"
	for at := 0; ; {
		i := strings.Index(reply[at:], open)
		if i < 0 {
			return ""
		}
		start := at + i + len(open)
		end := strings.IndexByte(reply[start:], '<')
		if end > 0 && strings.HasPrefix(reply[start+end:], close) {
			if inner := reply[start : start+end]; js.Length16(inner) <= 200 {
				return js.Trim(inner)
			}
		}
		at += i + 1
	}
}

// post sends to a service, with the errors the dashboard shows. explains is false where the
// reply must not be shown.
func post(ctx context.Context, fetcher web.Fetcher, url string, headers *web.Headers, body string, explains bool) error {
	parsed, perr := whatwg.Parse(url)
	if perr != nil {
		// fetch() refuses it, and then so does new URL() in the catch.
		return errors.New("Invalid URL")
	}
	host := parsed.Host()
	response, err := fetcher.Fetch(ctx, url, web.FetchInit{Method: "POST", Headers: headers, Body: []byte(body), Timeout: 20 * time.Second})
	if err != nil {
		return mailError("Could not reach "+host+": "+err.Error(), "mail_unreachable", "host", host, "detail", err.Error())
	}
	if response.OK() {
		return nil
	}
	message := ""
	if explains {
		message = ServiceMessage(response.Text())
	}
	return refused(host, response.Status, message)
}

func refused(host string, status int, message string) *MailError {
	code := js.FormatNumber(float64(status))
	text, detail := host+" answered "+code, code
	if message != "" {
		text += ": " + message
		detail += " " + message
	}
	return mailError(text, "mail_refused", "host", host, "detail", detail)
}

// jsonHeaders is `{ "content-type": "application/json", ...headers }`.
func jsonHeaders(pairs ...string) *web.Headers {
	return web.NewHeaders(append([]string{"content-type", "application/json"}, pairs...)...)
}

// basic is Basic auth over the UTF-8 bytes, so a key with any character is sent.
func basic(user, pass string) string {
	return "Basic " + base64.StdEncoding.EncodeToString([]byte(js.WellFormed(user+":"+pass)))
}

func hmacHex(secret, body string) string {
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(body))
	return hex.EncodeToString(mac.Sum(nil))
}

// CheckConfig checks a config has what its service needs, before anything is saved or sent.
// The error is always a *MailError.
func CheckConfig(config Config) error {
	i := slices.IndexFunc(Services, func(s Service) bool { return s.ID == config["service"] })
	if i < 0 {
		return mailError("Pick a mail service", "mail_service")
	}
	for _, f := range Services[i].Fields {
		value := config[f.Name]
		if !f.Optional && js.Trim(value) == "" {
			return mailError("Enter the "+js.ToLower(f.Label), "mail_field", "field", f.Name)
		}
		if f.Options != nil && value != "" && !slices.Contains(f.Options, value) {
			options := strings.Join(f.Options, ", ")
			return mailError(f.Label+" must be one of "+options, "mail_option", "field", f.Name, "options", options)
		}
	}
	if config["service"] == "webhook" && !strings.HasPrefix(config["url"], "https://") && !localWebhook(config["url"]) {
		return mailError("The webhook URL must use https", "mail_https")
	}
	if config["service"] == "webhook" && !whatwg.CanParse(config["url"]) {
		return mailError("Enter the webhook's whole URL, like https://example.com/hooks/mail", "mail_url")
	}
	// A port a socket can connect to, read with Number() as the SMTP client reads it.
	port := js.Number(config["port"])
	if config["service"] == "smtp" && !(port == math.Trunc(port) && port >= 1 && port <= 65535) {
		return mailError("The port must be a whole number from 1 to 65535", "mail_port")
	}
	return nil
}

// localWebhook is /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?(\/|$)/.
func localWebhook(url string) bool {
	rest, ok := strings.CutPrefix(url, "http://")
	if !ok {
		return false
	}
	if r, ok := strings.CutPrefix(rest, "localhost"); ok {
		rest = r
	} else if r, ok := strings.CutPrefix(rest, "127.0.0.1"); ok {
		rest = r
	} else {
		return false
	}
	if r, ok := strings.CutPrefix(rest, ":"); ok {
		n := 0
		for n < len(r) && r[n] >= '0' && r[n] <= '9' {
			n++
		}
		if n > 0 {
			// (:\d+)? backtracks to leave it out when what follows does not fit, and then ":" must.
			if r[n:] == "" || r[n] == '/' {
				return true
			}
		}
	}
	return rest == "" || rest[0] == '/'
}

// Options are what a send takes besides the config and message, for tests: the clock (SES's
// signature and the MIME Date), the stand-in for crypto.randomUUID(), the SMTP send's whole
// deadline, and the TLS settings an SMTP connection starts from.
type Options struct {
	// Now is milliseconds since the epoch; the clock when nil.
	Now func() int64
	// UUID gives the MIME boundary and Message-ID; random version 4 UUIDs when nil.
	UUID func() string
	// Deadline is how long a whole SMTP send may take; 60 s when zero.
	Deadline time.Duration
	// TLS is cloned for SMTP's TLS, with its ServerName set to the host; the system's roots when nil.
	TLS *tls.Config
}

func (o Options) now() int64 {
	if o.Now != nil {
		return o.Now()
	}
	return time.Now().UnixMilli()
}

// headerPairs are the message's extra headers, as Object.entries gives them.
func headerPairs(m Message) [][2]any {
	var out [][2]any
	if m.Headers != nil {
		m.Headers.Each(func(k string, v any) { out = append(out, [2]any{k, v}) })
	}
	return out
}

// headerList is Object.entries(headers).map(([k, v]) => ({ [name]: k, [value]: v })).
func headerList(m Message, name, value string) []any {
	out := []any{}
	for _, p := range headerPairs(m) {
		out = append(out, js.NewObject(name, p[0], value, p[1]))
	}
	return out
}

// sender is `{ [email]: m.from, ...(m.fromName ? { [name]: m.fromName } : {}) }`.
func sender(m Message, email, name string) *js.Object {
	o := js.NewObject(email, m.From)
	if m.FromName != "" {
		o.Set(name, m.FromName)
	}
	return o
}

// Send sends one message through the configured service. Every HTTP request goes through
// fetcher; SMTP opens its own connection. A problem the dashboard shows is a *MailError.
func Send(ctx context.Context, fetcher web.Fetcher, config Config, m Message) error {
	return SendWith(ctx, fetcher, config, m, Options{})
}

// SendWith is Send with the clock, UUIDs, deadline, and TLS settings given.
func SendWith(ctx context.Context, fetcher web.Fetcher, config Config, m Message, opts Options) error {
	if err := CheckConfig(config); err != nil {
		return err
	}
	headers := m.Headers
	if headers == nil {
		headers = js.NewObject()
	}
	switch config["service"] {
	case "resend":
		return post(ctx, fetcher, "https://api.resend.com/emails", jsonHeaders("authorization", "Bearer "+config["apiKey"]),
			js.Stringify(js.NewObject("from", Address(m), "to", []any{m.To}, "subject", m.Subject, "html", m.HTML, "text", m.Text, "headers", headers)), true)
	case "postmark":
		stream := config["stream"]
		if stream == "" {
			stream = "outbound"
		}
		return post(ctx, fetcher, "https://api.postmarkapp.com/email", jsonHeaders("accept", "application/json", "x-postmark-server-token", config["serverToken"]),
			js.Stringify(js.NewObject(
				"From", Address(m), "To", m.To, "Subject", m.Subject, "HtmlBody", m.HTML, "TextBody", m.Text,
				"MessageStream", stream,
				"Headers", headerList(m, "Name", "Value"),
			)), true)
	case "sendgrid":
		return post(ctx, fetcher, "https://api.sendgrid.com/v3/mail/send", jsonHeaders("authorization", "Bearer "+config["apiKey"]),
			js.Stringify(js.NewObject(
				"personalizations", []any{js.NewObject("to", []any{js.NewObject("email", m.To)})},
				"from", sender(m, "email", "name"),
				"subject", m.Subject,
				"content", []any{js.NewObject("type", "text/plain", "value", m.Text), js.NewObject("type", "text/html", "value", m.HTML)},
				"headers", headers,
			)), true)
	case "mailgun":
		form := whatwg.NewSearchParams("from", Address(m), "to", m.To, "subject", m.Subject, "html", m.HTML, "text", m.Text)
		for _, p := range headerPairs(m) {
			form.Set("h:"+p[0].(string), js.String(p[1]))
		}
		host := "api.mailgun.net"
		if config["region"] == "eu" {
			host = "api.eu.mailgun.net"
		}
		domain, err := encodeURIComponent(config["domain"])
		if err != nil {
			return err
		}
		auth := basic("api", config["apiKey"])
		return post(ctx, fetcher, "https://"+host+"/v3/"+domain+"/messages",
			web.NewHeaders("authorization", auth, "content-type", "application/x-www-form-urlencoded"), form.String(), true)
	case "brevo":
		return post(ctx, fetcher, "https://api.brevo.com/v3/smtp/email", jsonHeaders("api-key", config["apiKey"], "accept", "application/json"),
			js.Stringify(js.NewObject("sender", sender(m, "email", "name"), "to", []any{js.NewObject("email", m.To)}, "subject", m.Subject, "htmlContent", m.HTML, "textContent", m.Text, "headers", headers)), true)
	case "mailjet":
		auth := basic(config["apiKey"], config["secretKey"])
		return post(ctx, fetcher, "https://api.mailjet.com/v3.1/send", jsonHeaders("authorization", auth),
			js.Stringify(js.NewObject(
				"Messages", []any{js.NewObject("From", sender(m, "Email", "Name"), "To", []any{js.NewObject("Email", m.To)}, "Subject", m.Subject, "TextPart", m.Text, "HTMLPart", m.HTML, "Headers", headers)},
			)), true)
	case "mailersend":
		body := js.NewObject("from", sender(m, "email", "name"), "to", []any{js.NewObject("email", m.To)}, "subject", m.Subject, "html", m.HTML, "text", m.Text)
		if headers.Len() > 0 {
			body.Set("headers", headerList(m, "name", "value"))
		}
		return post(ctx, fetcher, "https://api.mailersend.com/v1/email", jsonHeaders("authorization", "Bearer "+config["apiKey"]), js.Stringify(body), true)
	case "sparkpost":
		host := "api.sparkpost.com"
		if config["region"] == "eu" {
			host = "api.eu.sparkpost.com"
		}
		var from any = m.From
		if m.FromName != "" {
			from = js.NewObject("email", m.From, "name", m.FromName)
		}
		return post(ctx, fetcher, "https://"+host+"/api/v1/transmissions", jsonHeaders("authorization", config["apiKey"]),
			js.Stringify(js.NewObject(
				"recipients", []any{js.NewObject("address", js.NewObject("email", m.To))},
				"content", js.NewObject("from", from, "subject", m.Subject, "html", m.HTML, "text", m.Text, "headers", headers),
			)), true)
	case "ses":
		return SESSend(ctx, fetcher, config, m, Address(m), opts)
	case "smtp":
		return SMTPSend(ctx, config, m, Address(m), opts)
	case "webhook":
		body := js.Stringify(js.NewObject("to", m.To, "from", m.From, "fromName", m.FromName, "subject", m.Subject, "html", m.HTML, "text", m.Text, "headers", headers))
		var signature []string
		if config["secret"] != "" {
			signature = []string{"x-runlight-signature", "sha256=" + hmacHex(config["secret"], body)}
		}
		// A webhook can be any address, so only its status comes back.
		return post(ctx, fetcher, config["url"], jsonHeaders(signature...), body, false)
	}
	return mailError(`Unknown mail service "`+config["service"]+`"`, "mail_service")
}
