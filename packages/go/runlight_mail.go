package runlight

import (
	"context"
	"errors"

	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/mail"
)

// seal encrypts a value kept in the database under the install's secret,
// or keeps it readable when there is none.
func (r *Runlight) seal(text string) (string, error) {
	secret := ""
	if r.HasSecret {
		secret = r.Secret
	}
	return mail.Seal(text, secret), nil
}

// unseal opens a sealed value; false when it cannot be opened (a different secret, or damaged).
func (r *Runlight) unseal(sealed string) (string, bool) {
	secret := ""
	if r.HasSecret {
		secret = r.Secret
	}
	return mail.Unseal(sealed, secret)
}

func mailService(id string) *mail.Service {
	for i := range mail.Services {
		if mail.Services[i].ID == id {
			return &mail.Services[i]
		}
	}
	return nil
}

func mailServiceName(id string) string {
	if s := mailService(id); s != nil {
		return s.Name
	}
	return ""
}

func mailErrorOf(err error) *CodedError {
	var me *mail.MailError
	if errors.As(err, &me) {
		return &CodedError{Message: me.Message, Code: me.Code, Params: me.Params}
	}
	return nil
}

// MailMessage is one email.
type MailMessage struct {
	To      string
	Subject string
	Text    string
	HTML    string
	Headers *js.Object
}

// MailSettings is the mail service, from code or as saved in the
// dashboard, with its source; nil when there is none.
func (r *Runlight) MailSettings(ctx context.Context) (*js.Object, error) {
	if r.mailCode != nil {
		out := r.mailCode.Clone()
		out.Set("source", "code")
		return out, nil
	}
	if err := r.Init(ctx); err != nil {
		return nil, err
	}
	sealed, ok, err := r.Store.Setting(ctx, "mail")
	if err != nil || !ok || sealed == "" {
		return nil, err
	}
	opened, ok := r.unseal(sealed)
	if !ok {
		return nil, nil
	}
	parsed, err := js.Parse(opened)
	if err != nil {
		return nil, err
	}
	out := js.Obj(parsed)
	if out == nil {
		out = &js.Object{}
	}
	out.Set("source", "dashboard")
	return out, nil
}

func configOf(settings *js.Object) mail.Config {
	config := mail.Config{}
	settings.Each(func(k string, v any) {
		if v != nil {
			config[k] = js.String(v)
		}
	})
	return config
}

// SaveMailSettings saves the mail service from the dashboard; nil removes
// it. A secret field left blank keeps the saved value, so the browser never
// needs to see it.
func (r *Runlight) SaveMailSettings(ctx context.Context, input *js.Object) error {
	if r.mailCode != nil {
		return &mail.MailError{Message: "The mail service is set in code", Code: "mail_in_code", Params: &js.Object{}}
	}
	if input == nil {
		return r.Store.SetSetting(ctx, "mail", nil)
	}
	before, err := r.MailSettings(ctx)
	if err != nil {
		return err
	}
	serviceID, _ := input.Value("service").(string)
	service := mailService(serviceID)
	if service == nil {
		return &mail.MailError{Message: "Pick a mail service", Code: "mail_service", Params: &js.Object{}}
	}
	settings := js.NewObject("service", service.ID)
	for _, f := range service.Fields {
		if !f.Secret {
			settings.Set(f.Name, jsTrim(field(input, f.Name)))
		}
	}
	// A blank secret keeps the saved one only while the connection is the same, so changing the host
	// cannot send a saved password somewhere new.
	same := before != nil && before.Value("service") == service.ID
	if same {
		for _, f := range service.Fields {
			if !f.Secret && field(before, f.Name) != js.Str(settings.Value(f.Name)) {
				same = false
			}
		}
	}
	for _, f := range service.Fields {
		if !f.Secret {
			continue
		}
		given := jsTrim(field(input, f.Name))
		if given == "" && same {
			given = field(before, f.Name)
		}
		settings.Set(f.Name, given)
	}
	from := jsTrim(field(input, "from"))
	if !emailPattern.MatchString(from) {
		return &mail.MailError{Message: "Enter the address reports come from, like reports@example.com", Code: "mail_from", Params: &js.Object{}}
	}
	fromName := head16(jsTrim(field(input, "fromName")), 80)
	settings.Set("from", from)
	if fromName != "" {
		settings.Set("fromName", fromName)
	}
	if err := mail.CheckConfig(configOf(settings)); err != nil {
		return err
	}
	sealed, err := r.seal(js.Stringify(settings))
	if err != nil {
		return err
	}
	return r.Store.SetSetting(ctx, "mail", &sealed)
}

// SendMail sends one email through the mail service.
func (r *Runlight) SendMail(ctx context.Context, message MailMessage) error {
	settings, err := r.MailSettings(ctx)
	if err != nil {
		return err
	}
	if settings == nil {
		return &mail.MailError{Message: "Set up a mail service first", Code: "mail_unset", Params: &js.Object{}}
	}
	return mail.Send(ctx, r.fetcher, configOf(settings), mail.Message{
		To: message.To, From: field(settings, "from"), FromName: field(settings, "fromName"),
		Subject: message.Subject, HTML: message.HTML, Text: message.Text, Headers: message.Headers,
	})
}

func (rt *Routes) mailView(c *call) (*Response, error) {
	settings, err := rt.r.MailSettings(c.ctx)
	if err != nil {
		return nil, err
	}
	var service *mail.Service
	if settings != nil {
		service = mailService(js.String(settings.Value("service")))
	}
	// Secret fields come back only as "saved", never as their value.
	fields := &js.Object{}
	saved := []string{}
	if service != nil {
		for _, f := range service.Fields {
			if f.Secret {
				if js.Truthy(settings.Value(f.Name)) {
					saved = append(saved, f.Name)
				}
			} else {
				fields.Set(f.Name, field(settings, f.Name))
			}
		}
	}
	value := func(key string) any {
		if settings == nil {
			return ""
		}
		v, ok := settings.Get(key)
		if !ok || v == nil {
			return ""
		}
		return v
	}
	var source any
	if settings != nil {
		source = settings.Value("source")
	}
	// A hub with a manage token learns which service sends the reports and from where, nothing more.
	if c.managed != nil {
		fields = &js.Object{}
		saved = []string{}
	}
	return jsonAnswer(js.NewObject("source", source, "service", value("service"), "from", value("from"), "fromName", value("fromName"),
		"fields", fields, "saved", saved, "encrypted", rt.r.HasSecret, "services", mail.Services), 200), nil
}
