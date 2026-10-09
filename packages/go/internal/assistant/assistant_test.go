package assistant

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strings"
	"testing"
	"time"

	"runlight.sh/go/internal/fixture"
	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/mcp"
	"runlight.sh/go/internal/web"
)

// fakeAPI is a reader that logs each read and answers from the fixture's
// canned API, or 404 for a path it does not hold.
func fakeAPI(t testing.TB, log *[]any) mcp.APIRead {
	api := js.Obj(js.Dig(fixture.PHP(t, "assistant.json"), "api"))
	return func(_ context.Context, path string, params mcp.Params) (*web.Response, error) {
		pairs := make([]any, len(params))
		for i, p := range params {
			pairs[i] = []any{p[0], p[1]}
		}
		*log = append(*log, js.NewObject("path", path, "params", pairs))
		canned := api.Value(path)
		if canned == nil {
			return web.NewResponse(404, []byte(`{"error":"Not found: `+strings.ReplaceAll(path, `"`, "")+`"}`), "content-type", "application/json"), nil
		}
		return web.NewResponse(int(js.Num(js.Dig(canned, "status"))), []byte(js.Str(js.Dig(canned, "body"))), "content-type", "application/json"), nil
	}
}

type sent struct {
	url, method string
	headers     *js.Object
	body        []byte
	timeout     time.Duration
}

// recorder is a Fetcher that records each request and answers from a
// queue: a response, or "timeout" or "network" to fail.
type recorder struct {
	queue    []any
	requests []sent
}

func (r *recorder) Fetch(_ context.Context, url string, init web.FetchInit) (*web.Response, error) {
	headers := &js.Object{}
	init.Headers.Each(func(name, value string) { headers.Set(name, value) })
	method := init.Method
	if method == "" {
		method = "GET"
	}
	r.requests = append(r.requests, sent{url, method, headers, init.Body, init.Timeout})
	if len(r.queue) == 0 {
		return nil, errors.New("no canned answer left")
	}
	next := r.queue[0]
	r.queue = r.queue[1:]
	switch next {
	case "timeout":
		return nil, &web.FetchError{Message: "The operation was aborted due to timeout", Timeout: true}
	case "network":
		return nil, &web.FetchError{Message: "fetch failed"}
	}
	return next.(*web.Response), nil
}

func settingsOf(v any) Settings {
	return Settings{Provider: js.Str(js.Dig(v, "provider")), Model: js.Str(js.Dig(v, "model")), BaseURL: js.Str(js.Dig(v, "baseUrl")), Key: js.Str(js.Dig(v, "key"))}
}

func TestScenariosSendTheSameRequestsAndAnswerTheSame(t *testing.T) {
	scenarios := js.Arr(js.Dig(fixture.PHP(t, "assistant.json"), "scenarios"))
	if len(scenarios) == 0 {
		t.Fatal("no scenarios")
	}
	for _, s := range scenarios {
		name := js.Str(js.Dig(s, "name"))
		fetcher := &recorder{}
		for _, c := range js.Arr(js.Dig(s, "responses")) {
			if js.Obj(c).Has("throws") {
				fetcher.queue = append(fetcher.queue, js.Str(js.Dig(c, "throws")))
				continue
			}
			fetcher.queue = append(fetcher.queue, web.NewResponse(int(js.Num(js.Dig(c, "status"))), []byte(js.Str(js.Dig(c, "body"))), "content-type", "application/json"))
		}
		var tools []any
		var result any
		var err error
		if js.Dig(s, "call") == "chat" {
			var messages []ChatMessage
			for _, m := range js.Arr(js.Dig(s, "messages")) {
				messages = append(messages, ChatMessage{Role: js.Str(js.Dig(m, "role")), Content: js.Str(js.Dig(m, "content"))})
			}
			c := js.Dig(s, "context")
			chatContext := ChatContext{
				Site:     Site{ID: js.Str(js.Dig(c, "site", "id")), Name: js.Str(js.Dig(c, "site", "name")), Timezone: js.Str(js.Dig(c, "site", "timezone"))},
				Today:    js.Str(js.Dig(c, "today")),
				View:     js.Str(js.Dig(c, "view")),
				Language: js.Str(js.Dig(c, "language")),
			}
			var answer *ChatResult
			answer, err = Chat(context.Background(), fetcher, settingsOf(js.Dig(s, "settings")), messages, chatContext, fakeAPI(t, &tools), nil)
			result = answer
		} else {
			result, err = ListModels(context.Background(), fetcher, settingsOf(js.Dig(s, "settings")))
		}
		if err != nil {
			var own *Error
			if !errors.As(err, &own) {
				t.Errorf("%s: %v", name, err)
				continue
			}
			if !js.Obj(s).Has("error") {
				t.Errorf("%s: threw %s", name, own.Message)
				continue
			}
			want := js.Dig(s, "error")
			if own.Message != js.Str(js.Dig(want, "message")) || own.Code != js.Str(js.Dig(want, "code")) {
				t.Errorf("%s: threw %q %q, want %q %q", name, own.Message, own.Code, js.Str(js.Dig(want, "message")), js.Str(js.Dig(want, "code")))
			}
			if got, want := js.Stringify(own.Params), js.Stringify(js.Dig(want, "params")); got != want {
				t.Errorf("%s: params %s, want %s", name, got, want)
			}
		} else {
			if !js.Obj(s).Has("result") {
				t.Errorf("%s: answered %s", name, js.Stringify(result))
				continue
			}
			if got, want := js.Stringify(result), js.Stringify(js.Dig(s, "result")); got != want {
				t.Errorf("%s: answered\n%s\nwant\n%s", name, got, want)
			}
		}
		if got, want := js.Stringify(append([]any{}, tools...)), js.Stringify(js.Dig(s, "tools")); got != want {
			t.Errorf("%s: read the API\n%s\nwant\n%s", name, got, want)
		}
		requests := js.Arr(js.Dig(s, "requests"))
		if len(requests) != len(fetcher.requests) {
			t.Errorf("%s: sent %d requests, want %d", name, len(fetcher.requests), len(requests))
			continue
		}
		for i, want := range requests {
			got := fetcher.requests[i]
			if got.url != js.Str(js.Dig(want, "url")) || got.method != js.Str(js.Dig(want, "method")) {
				t.Errorf("%s request %d: %s %s, want %s %s", name, i, got.method, got.url, js.Dig(want, "method"), js.Dig(want, "url"))
			}
			if g, w := js.Canonical(got.headers), js.Canonical(js.Dig(want, "headers")); g != w {
				t.Errorf("%s request %d: headers %s, want %s", name, i, g, w)
			}
			var hash any
			if got.body != nil {
				sum := sha256.Sum256(got.body)
				hash = hex.EncodeToString(sum[:])
			}
			if hash != js.Dig(want, "bodySha256") {
				t.Errorf("%s request %d: body %s", name, i, got.body)
			}
		}
	}
}

func TestAcknowledgementsMatch(t *testing.T) {
	cases := js.Arr(js.Dig(fixture.PHP(t, "assistant.json"), "acknowledgements"))
	if len(cases) == 0 {
		t.Fatal("no cases")
	}
	for _, c := range cases {
		text, language := js.Str(js.Dig(c, "text")), js.Str(js.Dig(c, "language"))
		reply, ok := Acknowledgement(text, language)
		var got any
		if ok {
			got = reply
		}
		if want := js.Dig(c, "reply"); got != want {
			t.Errorf("Acknowledgement(%q, %q) = %v, want %v", text, language, got, want)
		}
	}
}

func TestThanksGetsAShortReplyWithoutTheModelOrTheTools(t *testing.T) {
	for _, text := range []string{"Thanks!", "thank you", "Thanks!! 🙏", "ok", "Great, thanks.", "👍", "merci beaucoup", "Danke schön!", "valeu"} {
		if _, ok := Acknowledgement(text, "en"); !ok {
			t.Errorf("%q is thanks", text)
		}
	}
	for _, text := range []string{"Thanks, and what about last week?", "What was my bounce rate?", "ok so which pages?", "great results?"} {
		if _, ok := Acknowledgement(text, "en"); ok {
			t.Errorf("%q asks something", text)
		}
	}
	if reply, _ := Acknowledgement("merci", "fr"); !strings.Contains(reply, "plaisir") {
		t.Errorf("French thanks got %q", reply)
	}
}

var testContext = ChatContext{Site: Site{ID: "default", Name: "Blog", Timezone: "UTC"}, Today: "2026-10-08", View: "today", Language: "en"}

func TestEachRequestHasTheTimeLeftAndTheDeadlineStopsTheRest(t *testing.T) {
	clock := int64(1_000_000)
	now := func() int64 { return clock }
	toolUse := func(id string) *web.Response {
		return web.NewResponse(200, []byte(js.Stringify(js.NewObject("stop_reason", "tool_use", "content", []any{js.NewObject("type", "tool_use", "id", id, "name", "list_sites", "input", &js.Object{})}))))
	}
	fetcher := &recorder{queue: []any{toolUse("a"), toolUse("b"), toolUse("c")}}
	var log []any
	read := fakeAPI(t, &log)
	slow := func(ctx context.Context, path string, params mcp.Params) (*web.Response, error) {
		clock += 50_000
		return read(ctx, path, params)
	}
	_, err := Chat(context.Background(), fetcher, Settings{Provider: "anthropic", Model: "m", Key: "k"}, []ChatMessage{{"user", "All of it"}}, testContext, slow, now)
	var own *Error
	if !errors.As(err, &own) || own.Code != "assistant_slow" {
		t.Fatalf("should run out of time, got %v", err)
	}
	var timeouts []time.Duration
	for _, r := range fetcher.requests {
		timeouts = append(timeouts, r.timeout)
	}
	if want := []time.Duration{90 * time.Second, 70 * time.Second, 20 * time.Second}; js.Stringify(timeouts) != js.Stringify(want) {
		t.Errorf("timeouts %v, want %v", timeouts, want)
	}
	if len(log) != 3 {
		t.Errorf("read the API %d times, want 3", len(log))
	}
}

func TestACancelledQuestionStopsBeforeItsNextRequest(t *testing.T) {
	fetcher := &recorder{}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	var log []any
	_, err := Chat(ctx, fetcher, Settings{Provider: "openai", Model: "m", Key: "k"}, []ChatMessage{{"user", "Hi?"}}, testContext, fakeAPI(t, &log), nil)
	var own *Error
	if !errors.As(err, &own) || own.Code != "assistant_cancelled" || own.Message != "The question was cancelled." {
		t.Fatalf("should be cancelled, got %v", err)
	}
	if len(fetcher.requests) != 0 {
		t.Error("sent a request")
	}
}

func TestModelsAreListedWithinTwentySeconds(t *testing.T) {
	fetcher := &recorder{queue: []any{web.NewResponse(200, []byte(`{"data":[{"id":"b"},{"id":"a"}]}`))}}
	models, err := ListModels(context.Background(), fetcher, Settings{Provider: "ollama"})
	if err != nil {
		t.Fatal(err)
	}
	if got := js.Stringify(models); got != `[{"id":"a","name":"a"},{"id":"b","name":"b"}]` {
		t.Errorf("models %s", got)
	}
	if fetcher.requests[0].timeout != 20*time.Second || fetcher.requests[0].url != "http://localhost:11434/v1/models" {
		t.Errorf("request %+v", fetcher.requests[0])
	}
}

func TestProvidersAreWrittenAsTheTypeScriptHasThem(t *testing.T) {
	want := `{"id":"anthropic","name":"Anthropic (Claude)","protocol":"anthropic","baseUrl":"https://api.anthropic.com/v1","model":"claude-sonnet-5-5","key":"yes"}`
	if got := js.Stringify(Providers[0]); got != want {
		t.Errorf("got %s", got)
	}
	if len(Providers) != 7 {
		t.Errorf("%d providers", len(Providers))
	}
}
