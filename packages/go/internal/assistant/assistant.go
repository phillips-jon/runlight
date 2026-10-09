// Package assistant is the dashboard's assistant: questions about the
// stats, answered by a model the owner chooses, through the same read-only
// tools as the MCP server. The model runs on the server, so the key never
// reaches a browser, and each tool reads the API with the asking person's
// own access.
//
// Two protocols cover the providers: Anthropic's Messages API, and OpenAI's
// Chat Completions, which OpenAI, Gemini (through its compatible endpoint),
// OpenRouter, Ollama, LM Studio, and most others speak. Plain requests
// through a web.Fetcher, no SDKs.
package assistant

import (
	"context"
	"regexp"
	"sort"
	"strings"
	"time"
	"unicode"

	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/mcp"
	"runlight.sh/go/internal/web"
	"runlight.sh/go/internal/whatwg"
)

// Provider is a service the assistant can talk to.
type Provider struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	// Protocol is "anthropic" or "openai".
	Protocol string `json:"protocol"`
	// BaseURL is the API's address, filled in for known services and asked for otherwise.
	BaseURL string `json:"baseUrl"`
	// Model is a model to start with, or "" when the person picks one.
	Model string `json:"model"`
	// Key is whether it needs a key: "yes", "no" (a model on your own machine), or "optional".
	Key string `json:"key"`
}

// Providers are the services the settings offer, in order.
var Providers = []Provider{
	{ID: "anthropic", Name: "Anthropic (Claude)", Protocol: "anthropic", BaseURL: "https://api.anthropic.com/v1", Model: "claude-sonnet-5-5", Key: "yes"},
	{ID: "openai", Name: "OpenAI", Protocol: "openai", BaseURL: "https://api.openai.com/v1", Model: "", Key: "yes"},
	{ID: "gemini", Name: "Google Gemini", Protocol: "openai", BaseURL: "https://generativelanguage.googleapis.com/v1beta/openai", Model: "", Key: "yes"},
	{ID: "openrouter", Name: "OpenRouter", Protocol: "openai", BaseURL: "https://openrouter.ai/api/v1", Model: "", Key: "yes"},
	{ID: "ollama", Name: "Ollama", Protocol: "openai", BaseURL: "http://localhost:11434/v1", Model: "", Key: "no"},
	{ID: "lmstudio", Name: "LM Studio", Protocol: "openai", BaseURL: "http://localhost:1234/v1", Model: "", Key: "no"},
	{ID: "custom", Name: "Another OpenAI-compatible service", Protocol: "openai", BaseURL: "", Model: "", Key: "optional"},
}

// Settings are the assistant's settings, as an owner saves them.
type Settings struct {
	Provider string `json:"provider"`
	Model    string `json:"model"`
	BaseURL  string `json:"baseUrl"`
	Key      string `json:"key"`
}

// Error is what went wrong with the assistant, as a code the dashboard says
// in its own words; a service's own text goes in the params' detail.
type Error struct {
	Message string
	Code    string
	// Params are the words the dashboard fills in, keys in the TypeScript's order; never nil.
	Params *js.Object
}

func (e *Error) Error() string { return e.Message }

func fail(message, code string, params ...any) *Error {
	return &Error{Message: message, Code: code, Params: js.NewObject(params...)}
}

// ChatMessage is one turn of the conversation.
type ChatMessage struct {
	// Role is "user" or "assistant".
	Role    string `json:"role"`
	Content string `json:"content"`
}

// Site is the site the person is looking at.
type Site struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Timezone string `json:"timezone"`
}

// ChatContext is what the person is looking at, so "this week" and "this page" mean what they see.
type ChatContext struct {
	Site     Site   `json:"site"`
	Today    string `json:"today"`
	View     string `json:"view"`
	Language string `json:"language"`
}

// ChatResult is the reply and the tools it used, in order. A tool's name is
// as the model gave it: a string, or nil where it gave none, which JSON
// writes as null as the TypeScript's undefined is.
type ChatResult struct {
	Reply string `json:"reply"`
	Tools []any  `json:"tools"`
}

// Model is one model a service offers.
type Model struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

const (
	maxRounds = 8
	// DeadlineMS is how long a question may take: however many rounds it
	// takes, the answer comes within this long or the assistant stops.
	DeadlineMS = 120_000
	maxTokens  = 1500
	tooLong    = "That question took too long to answer. Try asking something narrower."
	tooMany    = "The assistant needed too many steps for that question. Try asking something narrower."
)

func system(context ChatContext) string {
	return mcp.Instructions + `

You are the assistant inside this Runlight dashboard. Today is ` + context.Today + ` in ` + context.Site.Timezone + `. The person is looking at the site "` + context.Site.Name + `" (id ` + context.Site.ID + `) for ` + context.View + `. Unless they ask about another site or range, use this site and these dates.

When a question needs numbers, read them with the tools first and never guess one. Answer in a few short sentences or a short list, in plain language, and name the dates you looked at.

Rule: answer only the newest message. If it asks nothing new (thanks, a greeting, "great", "that helps"), reply with one short friendly sentence, call no tools, and do not repeat, summarise, or re-check any earlier answer. Only go back to earlier numbers when the person asks about them again. Bounce rate is a fraction from 0 to 1 and durations are milliseconds in the tools; give them as a percent and in seconds or minutes. Write in the language whose code is "` + context.Language + `".`
}

// clock is the time in milliseconds, now's or the wall clock's.
type clock func() int64

// inTime stops when the question's time is up or the person has left, before more work starts.
func inTime(ctx context.Context, deadline int64, now clock) error {
	if ctx.Err() != nil {
		return fail("The question was cancelled.", "assistant_cancelled")
	}
	if now() >= deadline {
		return fail(tooLong, "assistant_slow")
	}
	return nil
}

// TypeError is what JavaScript throws where the TypeScript lets one through,
// as new URL() does on a base address it cannot parse.
type TypeError struct{ Message string }

func (e *TypeError) Error() string { return e.Message }

// get is v[key] as JavaScript reads it from a JSON value: undefined where v
// is not an object or has no such key.
func get(v any, key string) any {
	if o, ok := v.(*js.Object); ok {
		if value, ok := o.Get(key); ok {
			return value
		}
	}
	return js.Undefined{}
}

// absent is whether a value is undefined or null, for ?? and ?.
func absent(v any) bool {
	if v == nil {
		return true
	}
	_, ok := v.(js.Undefined)
	return ok
}

func isObject(v any) bool {
	switch v.(type) {
	case *js.Object, []any:
		return true
	}
	return false
}

// unreadable is a service that answered, but not in its protocol's shape.
func unreadable(url string) error {
	h, err := host(url)
	if err != nil {
		return err
	}
	message := h + " sent an answer Runlight could not read"
	return fail(message, "assistant_failed", "host", h, "detail", message)
}

// isPlainObject is whether v is a JSON object, not null and not an array.
func isPlainObject(v any) bool {
	_, ok := v.(*js.Object)
	return ok
}

// allObjects is whether every value in list is a JSON object.
func allObjects(list []any) bool {
	for _, v := range list {
		if !isPlainObject(v) {
			return false
		}
	}
	return true
}

// allFunctions is whether every tool call has an object for its function.
func allFunctions(calls []any) bool {
	for _, call := range calls {
		if !isPlainObject(get(call, "function")) {
			return false
		}
	}
	return true
}

func host(url string) (string, error) {
	u, err := whatwg.Parse(url)
	if err != nil {
		return "", &TypeError{"Invalid URL"}
	}
	return u.Host(), nil
}

// serviceMessage is the service's own message from an error answer, never
// the request (it carries the key); "" when there is none.
func serviceMessage(data any) string {
	e := get(data, "error")
	if s, ok := e.(string); ok {
		return s
	}
	s, _ := get(e, "message").(string)
	return s
}

// refusal is the error for an answer that is not OK.
func refusal(url string, status int, data any) error {
	h, err := host(url)
	if err != nil {
		return err
	}
	message := serviceMessage(data)
	if message == "" {
		code := js.FormatNumber(float64(status))
		return fail(h+": it answered "+code, "assistant_status", "host", h, "status", code)
	}
	detail := js.Head16(message, 300)
	return fail(h+": "+detail, "assistant_refused", "host", h, "detail", detail)
}

// readJSON is answer.json(), or null where it is not JSON.
func readJSON(answer *web.Response) any {
	data, err := answer.JSON()
	if err != nil {
		return nil
	}
	return data
}

func post(ctx context.Context, fetcher web.Fetcher, url string, headers *web.Headers, body any, deadline int64, now clock) (any, error) {
	if err := inTime(ctx, deadline, now); err != nil {
		return nil, err
	}
	left := deadline - now()
	all := web.NewHeaders("content-type", "application/json")
	headers.Each(func(name, value string) { all.Set(name, value) })
	answer, err := fetcher.Fetch(ctx, url, web.FetchInit{
		Method:  "POST",
		Headers: all,
		Body:    []byte(js.Stringify(body)),
		Timeout: time.Duration(min(90_000, left)) * time.Millisecond,
	})
	if err != nil {
		h, herr := host(url)
		if herr != nil {
			return nil, herr
		}
		// The person leaving aborts the request too, which is not the timeout.
		if web.IsTimeout(err) && ctx.Err() == nil {
			return nil, fail("Could not reach "+h+": it took too long to answer", "assistant_timeout", "host", h)
		}
		return nil, fail("Could not reach "+h+": the connection failed", "unreachable", "host", h)
	}
	data := readJSON(answer)
	if !answer.OK() {
		return nil, refusal(url, answer.Status, data)
	}
	if data == nil {
		return &js.Object{}, nil
	}
	return data, nil
}

type toolOut struct {
	text  string
	error bool
}

func toolText(ctx context.Context, name, args any, readAPI mcp.APIRead) toolOut {
	if !isObject(args) {
		args = &js.Object{}
	}
	result, err := mcp.CallTool(ctx, js.NewObject("name", name, "arguments", args), readAPI)
	if err != nil {
		return toolOut{err.Error(), true}
	}
	text := ""
	if len(result.Content) > 0 {
		text = result.Content[0].Text
	}
	return toolOut{text, result.IsError}
}

// thanks are words that only acknowledge an answer, in the dashboard's
// languages; a message of nothing else gets a reply without the model.
var thanks = regexp.MustCompile(`(?i)^(?:(?:thanks|thank you|thank you so much|thanks a lot|thx|ty|cheers|ok|okay|great|cool|nice|perfect|awesome|got it|good|merci|merci beaucoup|super|parfait|d'accord|gracias|muchas gracias|vale|genial|perfecto|danke|danke schön|vielen dank|prima|alles klar|obrigado|obrigada|valeu|ótimo|beleza)[` + js.Whitespace + `!.,]*)+$`)

var welcome = map[string]string{
	"en": "You're welcome. Ask me anything else about your stats.",
	"fr": "Avec plaisir. Demandez-moi autre chose sur vos statistiques.",
	"es": "De nada. Pregúntame lo que quieras sobre tus estadísticas.",
	"de": "Gern geschehen. Frag mich gern noch etwas zu deinen Statistiken.",
	"pt": "De nada. Pergunte o que quiser sobre suas estatísticas.",
}

// Acknowledgement is a short reply to a message that only says thanks or
// OK, and false when the message asks something.
func Acknowledgement(text, language string) (string, bool) {
	plain := js.Trim(strings.Map(func(r rune) rune {
		if r == 0xfe0f || unicode.Is(extendedPictographic, r) {
			return ' '
		}
		return r
	}, text))
	reply, ok := welcome[language]
	if !ok {
		reply = welcome["en"]
	}
	if plain == "" && js.Trim(text) != "" {
		return reply, true
	}
	if thanks.MatchString(plain) {
		return reply, true
	}
	return "", false
}

func providerOf(id string) *Provider {
	for i := range Providers {
		if Providers[i].ID == id {
			return &Providers[i]
		}
	}
	return nil
}

// Chat answers the last question in messages, calling tools as the model
// asks, through fetcher. now is the clock in milliseconds (nil for the wall
// clock); ctx ending is the person leaving, checked before each request and
// tool. It fails with an *Error, or a *TypeError where the TypeScript throws
// one on a base address it cannot parse.
func Chat(ctx context.Context, fetcher web.Fetcher, settings Settings, messages []ChatMessage, chatContext ChatContext, readAPI mcp.APIRead, now func() int64) (*ChatResult, error) {
	if now == nil {
		now = func() int64 { return time.Now().UnixMilli() }
	}
	provider := providerOf(settings.Provider)
	if provider == nil {
		return nil, fail("Choose a provider in Settings, AI Assistant", "assistant_provider")
	}
	base := settings.BaseURL
	if base == "" {
		base = provider.BaseURL
	}
	base = strings.TrimRight(base, "/")
	if base == "" {
		return nil, fail("Enter the service's address in Settings, AI Assistant", "assistant_address")
	}
	model := settings.Model
	if model == "" {
		model = provider.Model
	}
	if model == "" {
		return nil, fail("Enter a model in Settings, AI Assistant", "assistant_model")
	}
	used := []any{}
	// "Thanks!" needs no model, no tools, and certainly not the last answer again.
	last := ""
	if len(messages) > 0 {
		last = messages[len(messages)-1].Content
	}
	if reply, ok := Acknowledgement(last, chatContext.Language); ok {
		return &ChatResult{Reply: reply, Tools: []any{}}, nil
	}
	deadline := now() + DeadlineMS
	// The last twenty turns, starting with a question (Anthropic refuses a history that opens with an answer),
	// and with unanswered questions in a row (a reply that never came) joined into one.
	recent := messages[max(0, len(messages)-20):]
	for len(recent) > 0 && recent[0].Role != "user" {
		recent = recent[1:]
	}
	type turn struct{ role, content string }
	var history []turn
	for _, m := range recent {
		content := js.Head16(m.Content, 8000)
		if n := len(history); n > 0 && history[n-1].role == m.Role {
			history[n-1].content += "\n\n" + content
		} else {
			history = append(history, turn{m.Role, content})
		}
	}
	convo := []any{}
	for _, h := range history {
		convo = append(convo, js.NewObject("role", h.role, "content", h.content))
	}

	if provider.Protocol == "anthropic" {
		tools := make([]any, len(mcp.Tools))
		for i, t := range mcp.Tools {
			tools[i] = js.NewObject("name", t.Name, "description", t.Description, "input_schema", t.InputSchema)
		}
		headers := web.NewHeaders("x-api-key", settings.Key, "anthropic-version", "2023-06-01")
		for round := 0; round < maxRounds; round++ {
			body := js.NewObject("model", model, "max_tokens", maxTokens, "system", system(chatContext), "tools", tools, "messages", convo)
			data, err := post(ctx, fetcher, base+"/messages", headers, body, deadline, now)
			if err != nil {
				return nil, err
			}
			content := get(data, "content")
			if absent(content) {
				content = []any{}
			}
			blocks, ok := content.([]any)
			if !ok || !allObjects(blocks) {
				return nil, unreadable(base)
			}
			var calls []any
			for _, b := range blocks {
				if get(b, "type") == "tool_use" {
					calls = append(calls, b)
				}
			}
			if get(data, "stop_reason") != "tool_use" || len(calls) == 0 {
				var texts []string
				for _, b := range blocks {
					if get(b, "type") == "text" {
						text := get(b, "text")
						if absent(text) {
							text = ""
						}
						texts = append(texts, js.String(text))
					}
				}
				return &ChatResult{Reply: js.Trim(strings.Join(texts, "\n")), Tools: used}, nil
			}
			convo = append(convo, js.NewObject("role", "assistant", "content", blocks))
			results := []any{}
			for _, call := range calls {
				// The deadline covers the reading too, however many tools one answer asks for.
				if err := inTime(ctx, deadline, now); err != nil {
					return nil, err
				}
				name := get(call, "name")
				if absent(name) {
					name = ""
				}
				used = append(used, name)
				out := toolText(ctx, name, get(call, "input"), readAPI)
				result := js.NewObject("type", "tool_result", "tool_use_id", get(call, "id"), "content", out.text)
				if out.error {
					result.Set("is_error", true)
				}
				results = append(results, result)
			}
			convo = append(convo, js.NewObject("role", "user", "content", results))
		}
		return nil, fail(tooMany, "assistant_steps")
	}

	tools := make([]any, len(mcp.Tools))
	for i, t := range mcp.Tools {
		tools[i] = js.NewObject("type", "function", "function", js.NewObject("name", t.Name, "description", t.Description, "parameters", t.InputSchema))
	}
	convo = append([]any{js.NewObject("role", "system", "content", system(chatContext))}, convo...)
	headers := web.NewHeaders()
	if settings.Key != "" {
		headers.Set("authorization", "Bearer "+settings.Key)
	}
	for round := 0; round < maxRounds; round++ {
		body := js.NewObject("model", model)
		// OpenAI's newer models take max_completion_tokens and refuse max_tokens; the other services still take max_tokens.
		if provider.ID == "openai" {
			body.Set("max_completion_tokens", maxTokens)
		} else {
			body.Set("max_tokens", maxTokens)
		}
		body.Set("messages", convo)
		body.Set("tools", tools)
		data, err := post(ctx, fetcher, base+"/chat/completions", headers, body, deadline, now)
		if err != nil {
			return nil, err
		}
		message := firstMessage(data)
		given := get(message, "tool_calls")
		content := get(message, "content")
		if !js.Truthy(length(given)) {
			if absent(content) {
				content = ""
			}
			return &ChatResult{Reply: js.Trim(js.String(content)), Tools: used}, nil
		}
		calls, ok := given.([]any)
		if !ok || !allObjects(calls) || !allFunctions(calls) {
			return nil, unreadable(base)
		}
		if _, undefined := content.(js.Undefined); undefined {
			content = nil
		}
		convo = append(convo, js.NewObject("role", "assistant", "content", content, "tool_calls", calls))
		for _, call := range calls {
			if err := inTime(ctx, deadline, now); err != nil {
				return nil, err
			}
			function := get(call, "function")
			name := get(function, "name")
			if _, undefined := name.(js.Undefined); undefined {
				used = append(used, nil)
			} else {
				used = append(used, name)
			}
			var args any = &js.Object{}
			if text := get(function, "arguments"); js.Truthy(text) {
				if parsed, err := js.Parse(js.String(text)); err == nil {
					args = parsed
				}
			}
			out := toolText(ctx, name, args, readAPI)
			convo = append(convo, js.NewObject("role", "tool", "tool_call_id", get(call, "id"), "content", out.text))
		}
	}
	return nil, fail(tooMany, "assistant_steps")
}

// firstMessage is data.choices?.[0]?.message ?? {}.
func firstMessage(data any) any {
	var first any = js.Undefined{}
	switch choices := get(data, "choices").(type) {
	case []any:
		if len(choices) > 0 {
			first = choices[0]
		}
	case *js.Object:
		first = get(choices, "0")
	}
	message := get(first, "message")
	if absent(message) {
		return &js.Object{}
	}
	return message
}

// length is v?.length for a JSON value.
func length(v any) any {
	switch t := v.(type) {
	case []any:
		return float64(len(t))
	case string:
		return float64(js.Length16(t))
	}
	return get(v, "length")
}

// ListModels is the models a service offers with a key, from its own list:
// Anthropic's /models, or the /models of an OpenAI-compatible API. Newest or
// most relevant first where the service orders them; otherwise by name.
// settings.Model is not read.
func ListModels(ctx context.Context, fetcher web.Fetcher, settings Settings) ([]Model, error) {
	provider := providerOf(settings.Provider)
	if provider == nil {
		return nil, fail("Choose a provider", "assistant_provider")
	}
	base := settings.BaseURL
	if base == "" {
		base = provider.BaseURL
	}
	base = strings.TrimRight(base, "/")
	if base == "" {
		return nil, fail("Enter the service's address first", "assistant_address")
	}
	if provider.Key == "yes" && settings.Key == "" {
		return nil, fail("Enter your "+provider.Name+" key first", "assistant_key", "provider", provider.Name)
	}
	headers := web.NewHeaders()
	url := base + "/models"
	if provider.Protocol == "anthropic" {
		headers.Set("x-api-key", settings.Key)
		headers.Set("anthropic-version", "2023-06-01")
		url += "?limit=100"
	} else if settings.Key != "" {
		headers.Set("authorization", "Bearer "+settings.Key)
	}
	answer, err := fetcher.Fetch(ctx, url, web.FetchInit{Method: "GET", Headers: headers, Timeout: 20 * time.Second})
	if err != nil {
		h, herr := host(base)
		if herr != nil {
			return nil, herr
		}
		return nil, fail("Could not reach "+h, "unreachable", "host", h)
	}
	data := readJSON(answer)
	if !answer.OK() {
		return nil, refusal(base, answer.Status, data)
	}
	listed := get(data, "data")
	if absent(listed) {
		listed = []any{}
	}
	list, ok := listed.([]any)
	if !ok {
		return nil, unreadable(base)
	}
	models := []Model{}
	for _, m := range list {
		if !isPlainObject(m) {
			continue
		}
		id, ok := get(m, "id").(string)
		if !ok || id == "" {
			continue
		}
		// Gemini lists ids as "models/gemini-...", which its OpenAI-compatible API takes without the prefix.
		id = strings.TrimPrefix(id, "models/")
		name, ok := get(m, "display_name").(string)
		if !ok {
			name = id
		}
		models = append(models, Model{ID: id, Name: name})
	}
	if len(models) == 0 {
		h, err := host(base)
		if err != nil {
			return nil, err
		}
		return nil, fail(h+" listed no models. Type the model's name instead.", "assistant_no_models", "host", h)
	}
	// Anthropic lists newest first already; others come in no useful order.
	if provider.Protocol != "anthropic" {
		sort.SliceStable(models, func(i, j int) bool { return localeCompare(models[i].ID, models[j].ID) < 0 })
	}
	return models, nil
}
