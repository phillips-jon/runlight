// Package mcp is the MCP server at {base}/mcp: Streamable HTTP without
// sessions or a stream, JSON-RPC in and JSON out. Every tool is a read of
// the HTTP API, made with the caller's own credentials, so the MCP server
// can see exactly what the token can and nothing more.
package mcp

import (
	"context"
	"errors"
	"math"
	"slices"
	"strings"

	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/web"
)

// Newest first; a client asking for one we do not know is answered with the newest.
var protocolVersions = []string{"2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"}

// version is version.ts's VERSION, which the root package holds; it is
// copied here so this package does not import the root one.
const version = "0.1.0"

// dimensions are the dimensions a breakdown reads, as query.ts's DIMENSIONS lists them.
var dimensions = []any{
	"page", "hostname", "event", "entry", "exit", "referrer", "source", "channel", "utm_source", "utm_medium", "utm_campaign", "utm_term",
	"utm_content", "country", "region", "city", "browser", "browser_version", "os", "os_version", "device", "screen", "language", "ai_agent", "ai_page",
}

// maxFilters is query.ts's MAX_FILTERS.
const maxFilters = 6

// Instructions tell a client what the tools read and how to ask.
const Instructions = `Runlight is privacy friendly web analytics. These tools read one install's numbers: visitors, visits, pageviews, bounce rate, visit duration, where visitors came from, what they read, goals and revenue, AI assistants that sent visitors or fetched pages, and short links.

Start with list_sites when you do not know the site id; every other tool defaults to the first site. Dates are in the site's own timezone, which each answer includes. Periods: today, yesterday, 7d, 30d, 90d, month (this month so far), last_month, year (this year so far), 12mo, all; or from and to as YYYY-MM-DD. Answers compare with the period before unless compare is off.

Filters narrow any report to matching visits, written dimension:op:value with op one of is, not, contains, for example "channel:is:Organic Search" or "page:contains:/blog". Visitors are counted per day without cookies, so a visitor seen on two days counts twice across a long range.`

// Params are an API read's query, name and value pairs in order.
type Params = [][2]string

// Tool is one tool the server offers.
type Tool struct {
	Name        string
	Title       string
	Description string
	InputSchema *js.Object
	// Request is the API path and query to read, from the tool's arguments
	// (a parsed JSON object, or an array, which has none of the keys).
	Request func(args any) (string, Params)
	// Shape trims an answer before it goes back, when the API's carries more
	// than an assistant needs; nil sends it as it is. It fails as JavaScript
	// would reading a property of null.
	Shape func(body any) (any, error)
}

// APIRead reads one API path with the caller's credentials.
type APIRead func(ctx context.Context, path string, params Params) (*web.Response, error)

// Error is a JSON-RPC error with its own code, such as -32602 for an
// unknown tool, answered with its message as it is.
type Error struct {
	Message string
	Code    int
}

func (e *Error) Error() string { return e.Message }

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

// absent is whether a value is undefined or null, for ??.
func absent(v any) bool {
	if v == nil {
		return true
	}
	_, ok := v.(js.Undefined)
	return ok
}

// isObject is typeof v === "object" for a JSON value that is truthy: an object or an array.
func isObject(v any) bool {
	switch v.(type) {
	case *js.Object, []any:
		return true
	}
	return false
}

func schema(kind, description string, more ...any) *js.Object {
	o := js.NewObject("type", kind)
	for i := 0; i+1 < len(more); i += 2 {
		o.Set(more[i].(string), more[i+1])
	}
	if description != "" {
		o.Set("description", description)
	}
	return o
}

var (
	rangeSite   = schema("string", "Site id from list_sites. Defaults to the first site.")
	rangePeriod = js.NewObject(
		"type", "string",
		"enum", []any{"today", "yesterday", "7d", "30d", "90d", "month", "last_month", "year", "12mo", "all"},
		"description", "The date range. Defaults to 30d. Ignored when from and to are given.",
	)
	rangeFrom    = schema("string", "First day, YYYY-MM-DD, with to.")
	rangeTo      = schema("string", "Last day, YYYY-MM-DD, inclusive.")
	rangeFilters = js.NewObject(
		"type", "array",
		"items", js.NewObject("type", "string"),
		"maxItems", maxFilters,
		"description", `Narrow to matching visits, up to `+js.FormatNumber(maxFilters)+` at once, each "dimension:op:value" with op is, not, or contains.`,
	)
)

// properties is a schema's properties: RANGE's, COMPARE's, then any more, in order.
func properties(withRange, withCompare bool, more ...any) *js.Object {
	o := &js.Object{}
	if withRange {
		o.Set("site", rangeSite)
		o.Set("period", rangePeriod)
		o.Set("from", rangeFrom)
		o.Set("to", rangeTo)
		o.Set("filters", rangeFilters)
	}
	if withCompare {
		o.Set("compare", js.NewObject("type", "string", "enum", []any{"previous", "year", "custom", "off"}, "description", "What to compare with. Defaults to previous, the same length of time just before."))
		o.Set("compare_from", schema("string", "For compare custom: first day, YYYY-MM-DD."))
		o.Set("compare_to", schema("string", "For compare custom: last day, YYYY-MM-DD."))
	}
	for i := 0; i+1 < len(more); i += 2 {
		o.Set(more[i].(string), more[i+1])
	}
	return o
}

func rangeParams(args any, keys []string) Params {
	params := Params{}
	for _, key := range keys {
		value := get(args, key)
		if key == "filters" {
			if list, ok := value.([]any); ok {
				for _, f := range list {
					params = append(params, [2]string{"filter", js.String(f)})
				}
			}
		} else if !absent(value) && value != "" {
			params = append(params, [2]string{key, js.String(value)})
		}
	}
	return params
}

func read(path string, keys []string, extra func(args any) Params) func(args any) (string, Params) {
	return func(args any) (string, Params) {
		params := rangeParams(args, keys)
		if extra != nil {
			params = append(params, extra(args)...)
		}
		return path, params
	}
}

// limit is String(Math.min(100, Math.max(1, Number(value) || fallback))).
func limit(fallback float64) func(args any) Params {
	return func(args any) Params {
		n := js.ToNumber(get(args, "limit"))
		if n == 0 || math.IsNaN(n) {
			n = fallback
		}
		return Params{{"limit", js.FormatNumber(math.Min(100, math.Max(1, n)))}}
	}
}

var (
	rangeKeys   = []string{"site", "period", "from", "to", "filters"}
	compareKeys = append(slices.Clone(rangeKeys), "compare", "compare_from", "compare_to")
)

func with(keys []string, more ...string) []string {
	return append(slices.Clone(keys), more...)
}

// Tools are the tools, in the order tools/list gives them.
var Tools = []Tool{
	{
		Name:        "list_sites",
		Title:       "List sites",
		Description: "Every site this token can read, with its id, name, hostnames, timezone, and when it last had a visit.",
		InputSchema: js.NewObject("type", "object", "properties", &js.Object{}),
		Request:     func(any) (string, Params) { return "/api/sites", Params{} },
	},
	{
		Name:        "get_stats",
		Title:       "Headline numbers",
		Description: "Visitors, visits, pageviews, views per visit, bounce rate (0 to 1), and visit duration (milliseconds) for a range, with the comparison range's numbers as previous.",
		InputSchema: js.NewObject("type", "object", "properties", properties(true, true)),
		Request:     read("/api/stats", compareKeys, nil),
	},
	{
		Name:        "get_timeseries",
		Title:       "Numbers over time",
		Description: "The headline numbers for each hour, day, week, or month of a range, with the comparison range's points lined up by position.",
		InputSchema: js.NewObject("type", "object", "properties", properties(true, true,
			"interval", js.NewObject("type", "string", "enum", []any{"hour", "day", "week", "month"}, "description", "Chosen from the range when left out."),
		)),
		Request: read("/api/series", with(compareKeys, "interval"), nil),
	},
	{
		Name:        "get_breakdown",
		Title:       "Top values of a dimension",
		Description: "Rows for one dimension, most visitors first: pages, entry and exit pages, referrers, sources, channels (Direct, Organic Search, Social, AI, and so on), UTM tags, countries, regions, cities, browsers, operating systems, devices, screens, languages, custom events, and AI agents that fetched pages (ai_agent, ai_page).",
		InputSchema: js.NewObject(
			"type", "object",
			"properties", properties(true, false,
				"dimension", js.NewObject("type", "string", "enum", dimensions),
				"limit", js.NewObject("type", "integer", "minimum", 1, "maximum", 100, "description", "Rows to return. Defaults to 10."),
				"page", js.NewObject("type", "integer", "minimum", 1, "description", "For more rows: 2 is the next limit rows."),
			),
			"required", []any{"dimension"},
		),
		Request: read("/api/breakdown", with(rangeKeys, "dimension", "page"), limit(10)),
	},
	{
		Name:        "list_funnels",
		Title:       "Funnels",
		Description: "Every funnel with how many visits reached each step in order within the same visit. Divide a step by the one before it for that step's conversion rate.",
		InputSchema: js.NewObject("type", "object", "properties", properties(true, false)),
		Request:     read("/api/funnels", rangeKeys, nil),
	},
	{
		Name:        "get_event_properties",
		Title:       "An event's properties",
		Description: "The properties sent with one custom event and the values each took, most common first. Automatic events have their own: \"Outbound link\" and \"File download\" carry url, and \"404\" carries path. Leave key out to see every property name and the values of the most used one.",
		InputSchema: js.NewObject(
			"type", "object",
			"properties", properties(true, false,
				"event", schema("string", "The event's name, as get_breakdown with dimension event lists it."),
				"key", schema("string", "Which property. Defaults to the most used one."),
				"limit", js.NewObject("type", "integer", "minimum", 1, "maximum", 100, "description", "Values to return. Defaults to 25."),
			),
			"required", []any{"event"},
		),
		Request: read("/api/event-props", with(rangeKeys, "event", "key"), limit(25)),
	},
	{
		Name:        "get_visit_times",
		Title:       "When people visit",
		Description: "Visits by weekday and hour in the site's timezone: grid[weekday][hour], Monday first, hours 0 to 23.",
		InputSchema: js.NewObject("type", "object", "properties", properties(true, false)),
		Request:     read("/api/rhythm", rangeKeys, nil),
		Shape: func(body any) (any, error) {
			return js.NewObject(
				"site", get(body, "site"),
				"range", get(body, "range"),
				"weekdays", []any{"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"},
				"grid", get(body, "grid"),
			), nil
		},
	},
	{
		Name:        "get_realtime",
		Title:       "Right now",
		Description: "People on the site in the last five minutes, the pages they are reading, where they came from, their countries, and the latest activity.",
		InputSchema: js.NewObject("type", "object", "properties", js.NewObject("site", rangeSite)),
		Request:     read("/api/realtime", []string{"site"}, nil),
	},
	{
		Name:        "list_goals",
		Title:       "Goals and conversions",
		Description: "Every goal with its conversions, converted visitors, conversion rate (0 to 1), and revenue for a range, with the comparison range's numbers as previous.",
		InputSchema: js.NewObject("type", "object", "properties", properties(true, true)),
		Request:     read("/api/goals", compareKeys, nil),
	},
	{
		Name:        "get_goal",
		Title:       "One goal in detail",
		Description: "One goal's conversions over time and by channel, source, and page. Find the goal_id with list_goals.",
		InputSchema: js.NewObject("type", "object", "properties", properties(true, false, "goal_id", js.NewObject("type", "string")), "required", []any{"goal_id"}),
		Request: func(args any) (string, Params) {
			id := get(args, "goal_id")
			if absent(id) {
				id = ""
			}
			return "/api/goals/" + encodeURIComponent(js.String(id)), rangeParams(args, rangeKeys)
		},
	},
	{
		Name:        "get_journeys",
		Title:       "Paths through the site",
		Description: "The paths visits take, page by page: the top pages at each step, how many went no further, the flows between steps, and the commonest whole paths. A refresh counts once. start and end follow only paths from or to a page.",
		InputSchema: js.NewObject(
			"type", "object",
			"properties", properties(true, false,
				"steps", js.NewObject("type", "integer", "minimum", 2, "maximum", 8, "description", "How many pages of each path. Defaults to 5."),
				"start", schema("string", "Only paths from this page, such as /pricing."),
				"end", schema("string", "Only paths that reach this page, cut there."),
			),
		),
		Request: read("/api/journeys", with(rangeKeys, "steps", "start", "end"), nil),
	},
	{
		Name:        "list_links",
		Title:       "Short links",
		Description: "Every short link with its destination and its clicks in the range.",
		InputSchema: js.NewObject("type", "object", "properties", js.NewObject("site", rangeSite, "period", rangePeriod, "from", rangeFrom, "to", rangeTo)),
		Request:     read("/api/links", []string{"site", "period", "from", "to"}, nil),
	},
}

// Content is one block of a tool's answer.
type Content struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

// Result is what a tool answers: its text, and whether it is an error.
type Result struct {
	Content []Content
	IsError bool
}

// JSValue writes isError only when it is true, as the TypeScript does.
func (r Result) JSValue() any {
	content := make([]any, len(r.Content))
	for i, c := range r.Content {
		content[i] = js.NewObject("type", c.Type, "text", c.Text)
	}
	o := js.NewObject("content", content)
	if r.IsError {
		o.Set("isError", true)
	}
	return o
}

// CallTool runs one tool by name, as the MCP server does; the dashboard's
// assistant calls it too. params holds name and arguments. An unknown tool
// fails with an *Error; a failed read fails with the reader's error.
func CallTool(ctx context.Context, params any, readAPI APIRead) (*Result, error) {
	name := get(params, "name")
	var tool *Tool
	for i := range Tools {
		if s, ok := name.(string); ok && Tools[i].Name == s {
			tool = &Tools[i]
			break
		}
	}
	if tool == nil {
		return nil, &Error{Message: `Unknown tool "` + js.String(name) + `"`, Code: -32602}
	}
	args := get(params, "arguments")
	if !isObject(args) {
		args = &js.Object{}
	}
	path, query := tool.Request(args)
	answer, err := readAPI(ctx, path, query)
	if err != nil {
		return nil, err
	}
	body, err := answer.JSON()
	if err != nil {
		body = &js.Object{}
	}
	// Any body that is not an object (null included) carries no words of its own.
	_, object := body.(*js.Object)
	if !answer.OK() {
		text := get(body, "error")
		if absent(text) {
			text = "Runlight answered " + js.FormatNumber(float64(answer.Status))
		}
		return &Result{Content: []Content{{"text", js.String(text)}}, IsError: true}, nil
	}
	if tool.Shape != nil && object {
		if body, err = tool.Shape(body); err != nil {
			return nil, err
		}
	}
	return &Result{Content: []Content{{"text", js.Stringify(body)}}}, nil
}

func rpcError(id any, code int, message string) *js.Object {
	if _, ok := id.(js.Undefined); ok {
		id = nil
	}
	return js.NewObject("jsonrpc", "2.0", "id", id, "error", js.NewObject("code", code, "message", message))
}

// answer is the answer to one message, or nil for a notification.
func answer(ctx context.Context, message any, readAPI APIRead) *js.Object {
	// A batch element that is not an object is an invalid request, answered with a null id.
	if _, ok := message.(*js.Object); !ok {
		return rpcError(nil, -32600, "Invalid request")
	}
	id := get(message, "id")
	_, isNotification := id.(js.Undefined)
	method, ok := get(message, "method").(string)
	if get(message, "jsonrpc") != "2.0" || !ok {
		if isNotification {
			return nil
		}
		return rpcError(id, -32600, "Invalid request")
	}
	// A notification is never answered, so it never runs anything either.
	if isNotification {
		return nil
	}
	params := get(message, "params")
	if !isObject(params) {
		params = &js.Object{}
	}
	var result any
	var err error
	switch method {
	case "initialize":
		asked := get(params, "protocolVersion")
		if absent(asked) {
			asked = ""
		}
		protocol := js.String(asked)
		if !slices.Contains(protocolVersions, protocol) {
			protocol = protocolVersions[0]
		}
		result = js.NewObject(
			"protocolVersion", protocol,
			"capabilities", js.NewObject("tools", js.NewObject("listChanged", false)),
			"serverInfo", js.NewObject("name", "runlight", "title", "Runlight", "version", version),
			"instructions", Instructions,
		)
	case "ping":
		result = &js.Object{}
	case "tools/list":
		tools := make([]any, len(Tools))
		for i, t := range Tools {
			tools[i] = js.NewObject(
				"name", t.Name, "title", t.Title, "description", t.Description, "inputSchema", t.InputSchema,
				"annotations", js.NewObject("readOnlyHint", true, "openWorldHint", false),
			)
		}
		result = js.NewObject("tools", tools)
	case "tools/call":
		result, err = CallTool(ctx, params, readAPI)
	default:
		return rpcError(id, -32601, `Unknown method "`+method+`"`)
	}
	if err != nil {
		var own *Error
		if errors.As(err, &own) {
			return rpcError(id, own.Code, own.Message)
		}
		return rpcError(id, -32603, "Internal error")
	}
	return js.NewObject("jsonrpc", "2.0", "id", id, "result", result)
}

// MCPResponse answers one POST to the MCP endpoint, already authorised.
func MCPResponse(ctx context.Context, request *web.Request, readAPI APIRead) *web.Response {
	headers := []string{"content-type", "application/json; charset=utf-8", "cache-control", "no-store"}
	body, err := request.JSON()
	if err != nil || !isObject(body) {
		return web.NewResponse(400, []byte(js.Stringify(rpcError(nil, -32700, "Send a JSON-RPC message"))), headers...)
	}
	// Batches were in the 2025-03-26 protocol; answering them costs nothing.
	if batch, ok := body.([]any); ok {
		answers := []any{}
		for _, m := range batch {
			if one := answer(ctx, m, readAPI); one != nil {
				answers = append(answers, one)
			}
		}
		if len(answers) == 0 {
			return web.NewResponse(202, nil)
		}
		return web.NewResponse(200, []byte(js.Stringify(answers)), headers...)
	}
	one := answer(ctx, body, readAPI)
	if one == nil {
		return web.NewResponse(202, nil)
	}
	return web.NewResponse(200, []byte(js.Stringify(one)), headers...)
}

// encodeURIComponent is JavaScript's: every byte of the UTF-8 percent-encoded
// except letters, digits, and -_.!~*'().
func encodeURIComponent(text string) string {
	const hex = "0123456789ABCDEF"
	var b strings.Builder
	for i := 0; i < len(text); i++ {
		c := text[i]
		if 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' || '0' <= c && c <= '9' || strings.IndexByte("-_.!~*'()", c) >= 0 {
			b.WriteByte(c)
			continue
		}
		b.WriteByte('%')
		b.WriteByte(hex[c>>4])
		b.WriteByte(hex[c&15])
	}
	return b.String()
}
