package mcp

import (
	"context"
	"encoding/hex"
	"errors"
	"strings"
	"testing"

	"runlight.sh/go/internal/fixture"
	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/web"
)

// FakeAPI is a reader that logs each read and answers from the fixture's
// canned API, or 404 for a path it does not hold.
func FakeAPI(t testing.TB, log *[]any) APIRead {
	api := js.Obj(js.Dig(fixture.PHP(t, "mcp.json"), "api"))
	return func(_ context.Context, path string, params Params) (*web.Response, error) {
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

func TestToolCallsReadTheSameAPIAndAnswerTheSame(t *testing.T) {
	calls := js.Arr(js.Dig(fixture.PHP(t, "mcp.json"), "calls"))
	if len(calls) == 0 {
		t.Fatal("no calls")
	}
	for _, c := range calls {
		params := js.Dig(c, "params")
		label := js.Stringify(params)
		var log []any
		result, err := CallTool(context.Background(), params, FakeAPI(t, &log))
		if js.Obj(c).Has("throws") {
			var own *Error
			if !errors.As(err, &own) {
				t.Errorf("%s: want an *Error, got %v", label, err)
				continue
			}
			if own.Message != js.Str(js.Dig(c, "message")) || own.Code != -32602 {
				t.Errorf("%s: threw %q %d", label, own.Message, own.Code)
			}
			continue
		}
		if err != nil {
			t.Errorf("%s: %v", label, err)
			continue
		}
		if got, want := js.Stringify(append([]any{}, log...)), js.Stringify(js.Dig(c, "requests")); got != want {
			t.Errorf("%s: read\n%s\nwant\n%s", label, got, want)
		}
		if got, want := js.Stringify(result), js.Stringify(js.Dig(c, "value")); got != want {
			t.Errorf("%s: answered\n%s\nwant\n%s", label, got, want)
		}
	}
}

func TestJSONRPCAnswersMatch(t *testing.T) {
	rpcs := js.Arr(js.Dig(fixture.PHP(t, "mcp.json"), "rpcs"))
	if len(rpcs) == 0 {
		t.Fatal("no rpcs")
	}
	for _, c := range rpcs {
		body := []byte(js.Str(js.Dig(c, "body")))
		if js.Obj(c).Has("bodyHex") {
			b, err := hex.DecodeString(js.Str(js.Dig(c, "bodyHex")))
			if err != nil {
				t.Fatal(err)
			}
			body = b
		}
		var log []any
		request := web.NewRequest("POST", "https://example.com/runlight/mcp", nil, body)
		answer := MCPResponse(context.Background(), request, FakeAPI(t, &log))
		if want := int(js.Num(js.Dig(c, "status"))); answer.Status != want {
			t.Errorf("%s: status %d, want %d", body, answer.Status, want)
		}
		headers := &js.Object{}
		answer.Header.Each(func(name, value string) { headers.Set(name, value) })
		if got, want := js.Canonical(headers), js.Canonical(js.Dig(c, "headers")); got != want {
			t.Errorf("%s: headers %s, want %s", body, got, want)
		}
		if got, want := answer.Text(), js.Str(js.Dig(c, "text")); got != want {
			t.Errorf("%s: answered\n%s\nwant\n%s", body, got, want)
		}
		if got, want := js.Stringify(append([]any{}, log...)), js.Stringify(js.Dig(c, "requests")); got != want {
			t.Errorf("%s: read %s, want %s", body, got, want)
		}
	}
}

func rpc(t *testing.T, text string) *web.Response {
	t.Helper()
	var log []any
	return MCPResponse(context.Background(), web.NewRequest("POST", "https://x.com/mcp", nil, []byte(text)), FakeAPI(t, &log))
}

func TestToolsAreListedReadOnlyInOrder(t *testing.T) {
	answer := rpc(t, `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
	parsed, err := answer.JSON()
	if err != nil {
		t.Fatal(err)
	}
	tools := js.Arr(js.Dig(parsed, "result", "tools"))
	var names []any
	for _, tool := range tools {
		names = append(names, js.Dig(tool, "name"))
		if js.Dig(tool, "annotations", "readOnlyHint") != true {
			t.Errorf("%v is not read only", js.Dig(tool, "name"))
		}
	}
	if got, want := js.Stringify(names), js.Stringify(js.Dig(fixture.PHP(t, "mcp.json"), "tools")); got != want {
		t.Errorf("tools %s, want %s", got, want)
	}
	if !strings.Contains(answer.Text(), `"properties":{}`) {
		t.Error("an empty schema is an object")
	}
}

func TestInitializeAnswersTheAskedVersionOrTheNewest(t *testing.T) {
	ask := func(version string) any {
		answer := rpc(t, js.Stringify(js.NewObject("jsonrpc", "2.0", "id", 1, "method", "initialize", "params", js.NewObject("protocolVersion", version))))
		parsed, err := answer.JSON()
		if err != nil {
			t.Fatal(err)
		}
		return js.Dig(parsed, "result")
	}
	if got := js.Dig(ask("2025-06-18"), "protocolVersion"); got != "2025-06-18" {
		t.Errorf("asked 2025-06-18, got %v", got)
	}
	if got := js.Dig(ask("2025-06-18"), "serverInfo", "name"); got != "runlight" {
		t.Errorf("server name %v", got)
	}
	if got := js.Dig(ask("1999-01-01"), "protocolVersion"); got != "2025-11-25" {
		t.Errorf("an unknown version gets the newest, got %v", got)
	}
	note := rpc(t, `{"jsonrpc":"2.0","method":"notifications/initialized"}`)
	if note.Status != 202 || note.Text() != "" {
		t.Errorf("a notification got %d %q", note.Status, note.Text())
	}
}

func TestAFailedReadIsAnInternalError(t *testing.T) {
	failing := func(context.Context, string, Params) (*web.Response, error) { return nil, errors.New("store down") }
	answer := MCPResponse(context.Background(), web.NewRequest("POST", "https://x.com/mcp", nil, []byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_sites"}}`)), failing)
	if want := `{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"Internal error"}}`; answer.Text() != want {
		t.Errorf("got %s", answer.Text())
	}
}

func TestABodyThatIsNotAnObjectIsReadAsNoWords(t *testing.T) {
	null := func(context.Context, string, Params) (*web.Response, error) {
		return web.NewResponse(500, []byte("null")), nil
	}
	result, err := CallTool(context.Background(), js.NewObject("name", "list_sites"), null)
	if err != nil || !result.IsError || result.Content[0].Text != "Runlight answered 500" {
		t.Errorf("got %+v, %v", result, err)
	}
	ok := func(context.Context, string, Params) (*web.Response, error) {
		return web.NewResponse(200, []byte("null")), nil
	}
	result, err = CallTool(context.Background(), js.NewObject("name", "get_visit_times"), ok)
	if err != nil || result.IsError || result.Content[0].Text != "null" {
		t.Errorf("got %+v, %v", result, err)
	}
}
