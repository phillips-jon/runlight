package runlight

import (
	"context"
	"errors"
	"math"
	"regexp"

	"runlight.sh/go/internal/assistant"
	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/mcp"
	"runlight.sh/go/internal/web"
	"runlight.sh/go/internal/whatwg"
)

// AssistantSettings are the dashboard assistant's provider, model, and key,
// kept sealed like the mail keys. Nil until an owner sets it up.
func (r *Runlight) AssistantSettings(ctx context.Context) (*assistant.Settings, error) {
	stored, has, err := r.Store.Setting(ctx, "assistant")
	if err != nil || !has || stored == "" {
		return nil, err
	}
	opened, ok := r.unseal(stored)
	if !ok || opened == "" {
		return nil, nil
	}
	parsed, err := js.Parse(opened)
	if err != nil {
		return nil, err
	}
	if parsed == nil {
		return nil, nil
	}
	return &assistant.Settings{
		Provider: textOr(jsField(parsed, "provider")),
		Model:    textOr(jsField(parsed, "model")),
		BaseURL:  textOr(jsField(parsed, "baseUrl")),
		Key:      textOr(jsField(parsed, "key")),
	}, nil
}

var trailingSlashes = regexp.MustCompile(`/+$`)

// SaveAssistantSettings saves the assistant's settings; an empty key keeps
// the one saved for the same provider. Nil removes them.
func (r *Runlight) SaveAssistantSettings(ctx context.Context, input *js.Object) error {
	if input == nil {
		return r.Store.SetSetting(ctx, "assistant", nil)
	}
	var provider *assistant.Provider
	if id, ok := input.Value("provider").(string); ok {
		for i := range assistant.Providers {
			if assistant.Providers[i].ID == id {
				provider = &assistant.Providers[i]
			}
		}
	}
	if provider == nil {
		return settingsError("Choose a provider", "assistant_provider")
	}
	baseURL := trailingSlashes.ReplaceAllString(jsTrim(textOr(input.Value("baseUrl"))), "")
	if baseURL != "" {
		parsed, err := whatwg.Parse(baseURL)
		if err != nil || (parsed.Protocol != "https:" && parsed.Protocol != "http:") {
			return settingsError("Enter the service's address, starting with https://", "assistant_address_bad")
		}
	}
	if baseURL == "" && provider.BaseURL == "" {
		return settingsError("Enter the service's address", "assistant_address")
	}
	model := head16(jsTrim(textOr(input.Value("model"))), 200)
	if model == "" && provider.Model == "" {
		return settingsError("Enter the model to use", "assistant_model")
	}
	before, err := r.AssistantSettings(ctx)
	if err != nil {
		return err
	}
	key := jsTrim(textOr(input.Value("key")))
	// A saved key is kept only for the same service at the same address, so it is never sent somewhere new.
	if key == "" && before != nil && before.Provider == provider.ID && firstNonEmpty(before.BaseURL, provider.BaseURL) == firstNonEmpty(baseURL, provider.BaseURL) {
		key = before.Key
	}
	if key == "" && provider.Key == "yes" {
		return settingsError("Enter your "+provider.Name+" key", "assistant_key", "provider", provider.Name)
	}
	sealed, err := r.seal(js.Stringify(assistant.Settings{Provider: provider.ID, Model: model, BaseURL: baseURL, Key: key}))
	if err != nil {
		return err
	}
	return r.Store.SetSetting(ctx, "assistant", &sealed)
}

// assistantErr turns the assistant package's refusals into this package's.
func assistantErr(err error) error {
	var e *assistant.Error
	if errors.As(err, &e) {
		return &CodedError{Message: e.Message, Code: e.Code, Params: e.Params}
	}
	return err
}

func isAssistantError(err error) bool {
	var e *assistant.Error
	return errors.As(err, &e)
}

// innerRead reads the HTTP API as the asker, with their own headers, for a tool.
func (rt *Routes) innerRead(c *call, u *whatwg.URL, site string) mcp.APIRead {
	headers := c.req.Header.Clone()
	for _, name := range []string{"content-type", "content-length", shareHeader, embedHeader} {
		headers.Delete(name)
	}
	return func(ctx context.Context, apiPath string, params mcp.Params) (*web.Response, error) {
		target, err := whatwg.Parse(rt.base+apiPath, u.Origin())
		if err != nil {
			return nil, err
		}
		q := target.SearchParams()
		for _, p := range params {
			q.Append(p[0], p[1])
		}
		// A tool that names no site reads the one on screen, not the install's first.
		if site != "" && apiPath != "/api/sites" && !q.Has("site") {
			q.Set("site", site)
		}
		target.SetSearchParams(q)
		inner := &call{ctx: ctx, req: web.NewRequest("GET", target.Href(), headers.Clone(), nil)}
		return rt.api(inner, apiPath, target)
	}
}

var languageCode = regexp.MustCompile(`^[a-z]{2}$`)

// assistantAPI is the assistant: an owner sets it up; anyone signed in to the dashboard can ask it.
func (rt *Routes) assistantAPI(c *call, path string, u *whatwg.URL) (*Response, error) {
	ctx, request, r := c.ctx, c.req, rt.r
	if path == "/api/assistant" {
		self := rt.canRead(c)
		// A member uses the assistant like anyone else, but its settings are for owners and admins.
		owner := self == canFull && !c.member
		if request.Method == "GET" {
			access, err := rt.reader(c)
			if err != nil {
				return nil, err
			}
			if access.refused() {
				return deniedReader(access), nil
			}
			// Only people at the dashboard, never an API token or a share, so nobody spends the owner's AI credit from outside.
			if !access.full && access.token.ID != "" {
				return Coded("Only the dashboard can use the assistant", "assistant_dashboard", 403, nil), nil
			}
			if err := r.Init(ctx); err != nil {
				return nil, err
			}
			settings, err := r.AssistantSettings(ctx)
			if err != nil {
				return nil, err
			}
			if !owner {
				return jsonAnswer(js.NewObject("configured", settings != nil), 200), nil
			}
			daily, err := rt.viewerDaily(ctx)
			if err != nil {
				return nil, err
			}
			out := js.NewObject("configured", settings != nil, "viewerDaily", daily)
			if settings != nil {
				out.Set("provider", settings.Provider)
				out.Set("model", settings.Model)
				out.Set("baseUrl", settings.BaseURL)
				out.Set("keySaved", settings.Key != "")
			} else {
				out.Set("provider", "")
				out.Set("model", "")
				out.Set("baseUrl", "")
				out.Set("keySaved", false)
			}
			out.Set("encrypted", r.HasSecret)
			out.Set("providers", assistant.Providers)
			return jsonAnswer(out, 200), nil
		}
		if !owner {
			if self == canFull {
				return Coded("Only an owner or admin can change this", "admin_only", 403, nil), nil
			}
			return denied(self), nil
		}
		if err := r.Init(ctx); err != nil {
			return nil, err
		}
		if request.Method == "DELETE" {
			if err := r.SaveAssistantSettings(ctx, nil); err != nil {
				return nil, err
			}
			return jsonAnswer(js.NewObject("ok", true), 200), nil
		}
		if request.Method == "PUT" {
			body, refused := readJSON(request)
			if refused != nil {
				return refused, nil
			}
			if err := r.SaveAssistantSettings(ctx, body); err != nil {
				if isRangeError(err) {
					return refusedAnswer(err, "assistant_invalid", 400), nil
				}
				return nil, err
			}
			return jsonAnswer(js.NewObject("ok", true), 200), nil
		}
		return Coded("Method not allowed", "method_not_allowed", 405, nil), nil
	}
	// How many questions each viewer may ask a day; 0 keeps the assistant for owners.
	if path == "/api/assistant/limits" && request.Method == "PUT" {
		if access := rt.canRead(c); access != canFull {
			return denied(access), nil
		}
		if err := r.Init(ctx); err != nil {
			return nil, err
		}
		body, refused := readJSON(request)
		if refused != nil {
			return refused, nil
		}
		daily := js.ToNumber(undefinedIfMissing(body, "viewerDaily", body.Value("viewerDaily")))
		if math.IsNaN(daily) || math.IsInf(daily, 0) || daily != math.Trunc(daily) || daily < 0 || daily > 1000 {
			return Coded("Use a whole number from 0 to 1,000", "assistant_limit", 400, nil), nil
		}
		value := js.FormatNumber(daily)
		if err := r.Store.SetSetting(ctx, "assistant-viewer-daily", &value); err != nil {
			return nil, err
		}
		return jsonAnswer(js.NewObject("viewerDaily", daily), 200), nil
	}
	// The models a service offers, for the setup form's dropdown. The key can be the one already saved.
	if path == "/api/assistant/models" && request.Method == "POST" {
		if access := rt.canRead(c); access != canFull {
			return denied(access), nil
		}
		if err := r.Init(ctx); err != nil {
			return nil, err
		}
		body, refused := readJSON(request)
		if refused != nil {
			return refused, nil
		}
		provider := textOr(body.Value("provider"))
		saved, err := r.AssistantSettings(ctx)
		if err != nil {
			return nil, err
		}
		baseURL := trailingSlashes.ReplaceAllString(jsTrim(textOr(body.Value("baseUrl"))), "")
		// The saved key only for the address it was saved with.
		sameAddress := saved != nil && saved.Provider == provider && saved.BaseURL == baseURL
		key := jsTrim(textOr(body.Value("key")))
		if key == "" && sameAddress {
			key = saved.Key
		}
		models, err := assistant.ListModels(ctx, r.fetcher, assistant.Settings{Provider: provider, BaseURL: jsTrim(textOr(body.Value("baseUrl"))), Key: key})
		if err != nil {
			if isAssistantError(err) {
				return refusedAnswer(assistantErr(err), "assistant_failed", 400), nil
			}
			return nil, err
		}
		return jsonAnswer(js.NewObject("models", models), 200), nil
	}
	if path == "/api/assistant/chat" && request.Method == "POST" {
		access, err := rt.reader(c)
		if err != nil {
			return nil, err
		}
		if access.refused() {
			return deniedReader(access), nil
		}
		if !access.full && access.token.ID != "" {
			return Coded("Only the dashboard can use the assistant", "assistant_dashboard", 403, nil), nil
		}
		if _, has := request.Header.Lookup(shareHeader); has {
			return Coded("Not available on a shared dashboard", "share_not_available", 403, nil), nil
		}
		if err := r.Init(ctx); err != nil {
			return nil, err
		}
		settings, err := r.AssistantSettings(ctx)
		if err != nil {
			return nil, err
		}
		if settings == nil {
			return Coded("The assistant is not set up yet. An owner can set it up in Settings, AI Assistant.", "assistant_unset", 400, nil), nil
		}
		body, refused := readJSON(request)
		if refused != nil {
			return refused, nil
		}
		site, ok := r.Site(textOr(body.Value("site")))
		if !ok {
			return Coded("Unknown site", "unknown_site", 404, nil), nil
		}
		messages := []assistant.ChatMessage{}
		if list, ok := body.Value("messages").([]any); ok {
			for _, m := range list {
				o, ok := m.(*js.Object)
				if !ok {
					continue
				}
				role, _ := o.Value("role").(string)
				content, isText := o.Value("content").(string)
				if (role == "user" || role == "assistant") && isText {
					messages = append(messages, assistant.ChatMessage{Role: role, Content: content})
				}
			}
		}
		if len(messages) == 0 || messages[len(messages)-1].Role != "user" {
			return Coded("Ask a question", "question_needed", 400, nil), nil
		}
		owner := access.full
		who := ""
		if rt.accountOf != nil {
			who = rt.accountOf(ctx, request)
		}
		if who == "" {
			who = "viewer"
			if owner {
				who = "owner"
			}
		}
		turn, finish, err := rt.askTurn(ctx, who, owner)
		if err != nil {
			return nil, err
		}
		if turn != nil {
			return turn, nil
		}
		defer finish()
		view := "the last 30 days"
		if v := body.Value("view"); v != nil {
			if _, u := v.(js.Undefined); !u {
				view = js.String(v)
			}
		}
		language := "en"
		if l := js.String(undefinedIfMissing(body, "language", body.Value("language"))); languageCode.MatchString(l) {
			language = l
		}
		answer, err := assistant.Chat(ctx, r.fetcher, *settings, messages, assistant.ChatContext{
			Site:     assistant.Site{ID: site.ID, Name: site.Name, Timezone: site.Timezone},
			Today:    LocalDate(r.now(), site.Timezone),
			View:     head16(view, 200),
			Language: language,
		}, rt.innerRead(c, u, site.ID), r.now)
		if err != nil {
			if isAssistantError(err) {
				return refusedAnswer(assistantErr(err), "assistant_failed", 502), nil
			}
			return nil, err
		}
		return jsonAnswer(answer, 200), nil
	}
	return nil, nil
}

// mcp answers the MCP endpoint. No server-sent stream and no sessions: every message is one POST.
func (rt *Routes) mcp(c *call, u *whatwg.URL) (*Response, error) {
	if c.req.Method != "POST" {
		return Coded("Method not allowed", "method_not_allowed", 405, nil, "allow", "POST"), nil
	}
	access, err := rt.reader(c)
	if err != nil {
		return nil, err
	}
	if access.refused() {
		refused := deniedReader(access)
		// Points an OAuth client at the metadata that starts the sign-in.
		refused.Header.Set("www-authenticate", `Bearer realm="runlight", resource_metadata="`+ResourceMetadataURL(u.Origin(), rt.base)+`"`)
		return refused, nil
	}
	// Each tool reads the HTTP API with the caller's own headers, so it sees what they may.
	return mcp.MCPResponse(c.ctx, c.req, rt.innerRead(c, u, "")), nil
}
