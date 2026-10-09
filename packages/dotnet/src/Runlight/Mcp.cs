using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Runlight.Http;

namespace Runlight;

/// <summary>Reads one API path with the caller's credentials, as ApiRead does in TypeScript.</summary>
public delegate Task<Response> ApiRead(string path, IReadOnlyList<KeyValuePair<string, string>> parameters);

/// <summary>The API path and query a tool reads.</summary>
public sealed record McpRead(string Path, List<KeyValuePair<string, string>> Params);

/// <summary>
/// One tool: name, title, description, inputSchema, Request (args to an API path and query), and Shape (trims
/// an answer before it goes back, when the API's carries more than an assistant needs) or null.
/// </summary>
public sealed record McpTool(string Name, string Title, string Description, JsObject InputSchema, Func<object?, McpRead> Request, Func<object?, object?>? Shape);

/// <summary>
/// The MCP server at {base}/mcp: Streamable HTTP without sessions or a stream,
/// JSON-RPC in and JSON out. Every tool is a read of the HTTP API, made with
/// the caller's own credentials, so the MCP server can see exactly what the
/// token can and nothing more.
/// </summary>
public static class Mcp
{
    /// <summary>Newest first; a client asking for one we do not know is answered with the newest.</summary>
    public static readonly IReadOnlyList<string> ProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];

    public const string Instructions =
        "Runlight is privacy friendly web analytics. These tools read one install's numbers: visitors, visits, pageviews, bounce rate, visit duration, where visitors came from, what they read, goals and revenue, AI assistants that sent visitors or fetched pages, and short links.\n"
        + "\n"
        + "Start with list_sites when you do not know the site id; every other tool defaults to the first site. Dates are in the site's own timezone, which each answer includes. Periods: today, yesterday, 7d, 30d, 90d, month (this month so far), last_month, year (this year so far), 12mo, all; or from and to as YYYY-MM-DD. Answers compare with the period before unless compare is off.\n"
        + "\n"
        + "Filters narrow any report to matching visits, written dimension:op:value with op one of is, not, contains, for example \"channel:is:Organic Search\" or \"page:contains:/blog\". Visitors are counted per day without cookies, so a visitor seen on two days counts twice across a long range.";

    /// <summary>The dimensions a breakdown reads, as query.ts's DIMENSIONS lists them.</summary>
    private static readonly string[] Dimensions =
    [
        "page", "hostname", "event", "entry", "exit", "referrer", "source", "channel", "utm_source", "utm_medium", "utm_campaign", "utm_term",
        "utm_content", "country", "region", "city", "browser", "browser_version", "os", "os_version", "device", "screen", "language", "ai_agent", "ai_page",
    ];

    /// <summary>query.ts's MAX_FILTERS.</summary>
    private const long MaxFilters = 6;

    private static readonly string[] RangeKeys = ["site", "period", "from", "to", "filters"];
    private static readonly string[] CompareKeys = [.. RangeKeys, "compare", "compare_from", "compare_to"];

    private static IReadOnlyList<McpTool>? _tools;

    private static List<object?> Strings(params string[] items) => [.. items];

    private static JsObject Range() => new()
    {
        ["site"] = new JsObject { ["type"] = "string", ["description"] = "Site id from list_sites. Defaults to the first site." },
        ["period"] = new JsObject
        {
            ["type"] = "string",
            ["enum"] = Strings("today", "yesterday", "7d", "30d", "90d", "month", "last_month", "year", "12mo", "all"),
            ["description"] = "The date range. Defaults to 30d. Ignored when from and to are given.",
        },
        ["from"] = new JsObject { ["type"] = "string", ["description"] = "First day, YYYY-MM-DD, with to." },
        ["to"] = new JsObject { ["type"] = "string", ["description"] = "Last day, YYYY-MM-DD, inclusive." },
        ["filters"] = new JsObject
        {
            ["type"] = "array",
            ["items"] = new JsObject { ["type"] = "string" },
            ["maxItems"] = MaxFilters,
            ["description"] = "Narrow to matching visits, up to " + Js.Str(MaxFilters) + " at once, each \"dimension:op:value\" with op is, not, or contains.",
        },
    };

    private static JsObject Compare() => new()
    {
        ["compare"] = new JsObject { ["type"] = "string", ["enum"] = Strings("previous", "year", "custom", "off"), ["description"] = "What to compare with. Defaults to previous, the same length of time just before." },
        ["compare_from"] = new JsObject { ["type"] = "string", ["description"] = "For compare custom: first day, YYYY-MM-DD." },
        ["compare_to"] = new JsObject { ["type"] = "string", ["description"] = "For compare custom: last day, YYYY-MM-DD." },
    };

    /// <summary>args[key], undefined when args is not something with properties.</summary>
    private static object? Arg(object? args, string key) => args is null or Undefined ? Undefined.Value : Js.Get(args, key);

    private static List<KeyValuePair<string, string>> RangeParams(object? args, IEnumerable<string> keys)
    {
        var parameters = new List<KeyValuePair<string, string>>();
        foreach (string key in keys)
        {
            object? value = Arg(args, key);
            if (key == "filters")
            {
                if (value is List<object?> list)
                {
                    foreach (object? f in list)
                    {
                        parameters.Add(new("filter", Js.String(f)));
                    }
                }
            }
            else if (value is not Undefined && value is not null && !(value is string s && s.Length == 0))
            {
                parameters.Add(new(key, Js.String(value)));
            }
        }
        return parameters;
    }

    private static Func<object?, McpRead> Read(string path, IEnumerable<string> keys, Func<object?, List<KeyValuePair<string, string>>>? extra = null)
    {
        string[] fixedKeys = [.. keys];
        return args => new McpRead(path, [.. RangeParams(args, fixedKeys), .. extra != null ? extra(args) : []]);
    }

    /// <summary>Math.min(100, Math.max(1, Number(value) || fallback)) as text.</summary>
    private static string Limit(object? value, double fallback)
    {
        double n = Js.Number(value);
        if (!Js.Truthy(n))
        {
            n = fallback;
        }
        return Js.String(Math.Min(100, Math.Max(1, n)));
    }

    private static JsObject Merge(params JsObject[] parts)
    {
        var o = new JsObject();
        foreach (var part in parts)
        {
            foreach (var (k, v) in part)
            {
                o[k] = v;
            }
        }
        return o;
    }

    /// <summary>The tools, in the order tools/list gives them.</summary>
    public static IReadOnlyList<McpTool> Tools => _tools ??= MakeTools();

    private static List<McpTool> MakeTools()
    {
        var range = Range();
        var compare = Compare();
        return
        [
            new(
                "list_sites",
                "List sites",
                "Every site this token can read, with its id, name, hostnames, timezone, and when it last had a visit.",
                new JsObject { ["type"] = "object", ["properties"] = new JsObject() },
                _ => new McpRead("/api/sites", []),
                null),
            new(
                "get_stats",
                "Headline numbers",
                "Visitors, visits, pageviews, views per visit, bounce rate (0 to 1), and visit duration (milliseconds) for a range, with the comparison range's numbers as previous.",
                new JsObject { ["type"] = "object", ["properties"] = Merge(range, compare) },
                Read("/api/stats", CompareKeys),
                null),
            new(
                "get_timeseries",
                "Numbers over time",
                "The headline numbers for each hour, day, week, or month of a range, with the comparison range's points lined up by position.",
                new JsObject
                {
                    ["type"] = "object",
                    ["properties"] = Merge(range, compare, new JsObject { ["interval"] = new JsObject { ["type"] = "string", ["enum"] = Strings("hour", "day", "week", "month"), ["description"] = "Chosen from the range when left out." } }),
                },
                Read("/api/series", [.. CompareKeys, "interval"]),
                null),
            new(
                "get_breakdown",
                "Top values of a dimension",
                "Rows for one dimension, most visitors first: pages, entry and exit pages, referrers, sources, channels (Direct, Organic Search, Social, AI, and so on), UTM tags, countries, regions, cities, browsers, operating systems, devices, screens, languages, custom events, and AI agents that fetched pages (ai_agent, ai_page).",
                new JsObject
                {
                    ["type"] = "object",
                    ["properties"] = Merge(range, new JsObject
                    {
                        ["dimension"] = new JsObject { ["type"] = "string", ["enum"] = Strings(Dimensions) },
                        ["limit"] = new JsObject { ["type"] = "integer", ["minimum"] = 1L, ["maximum"] = 100L, ["description"] = "Rows to return. Defaults to 10." },
                        ["page"] = new JsObject { ["type"] = "integer", ["minimum"] = 1L, ["description"] = "For more rows: 2 is the next limit rows." },
                    }),
                    ["required"] = Strings("dimension"),
                },
                Read("/api/breakdown", [.. RangeKeys, "dimension", "page"], args => [new("limit", Limit(Arg(args, "limit"), 10))]),
                null),
            new(
                "list_funnels",
                "Funnels",
                "Every funnel with how many visits reached each step in order within the same visit. Divide a step by the one before it for that step's conversion rate.",
                new JsObject { ["type"] = "object", ["properties"] = Merge(range) },
                Read("/api/funnels", RangeKeys),
                null),
            new(
                "get_event_properties",
                "An event's properties",
                "The properties sent with one custom event and the values each took, most common first. Automatic events have their own: \"Outbound link\" and \"File download\" carry url, and \"404\" carries path. Leave key out to see every property name and the values of the most used one.",
                new JsObject
                {
                    ["type"] = "object",
                    ["properties"] = Merge(range, new JsObject
                    {
                        ["event"] = new JsObject { ["type"] = "string", ["description"] = "The event's name, as get_breakdown with dimension event lists it." },
                        ["key"] = new JsObject { ["type"] = "string", ["description"] = "Which property. Defaults to the most used one." },
                        ["limit"] = new JsObject { ["type"] = "integer", ["minimum"] = 1L, ["maximum"] = 100L, ["description"] = "Values to return. Defaults to 25." },
                    }),
                    ["required"] = Strings("event"),
                },
                Read("/api/event-props", [.. RangeKeys, "event", "key"], args => [new("limit", Limit(Arg(args, "limit"), 25))]),
                null),
            new(
                "get_visit_times",
                "When people visit",
                "Visits by weekday and hour in the site's timezone: grid[weekday][hour], Monday first, hours 0 to 23.",
                new JsObject { ["type"] = "object", ["properties"] = Merge(range) },
                Read("/api/rhythm", RangeKeys),
                body => new JsObject
                {
                    ["site"] = Arg(body, "site"),
                    ["range"] = Arg(body, "range"),
                    ["weekdays"] = Strings("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"),
                    ["grid"] = Arg(body, "grid"),
                }),
            new(
                "get_realtime",
                "Right now",
                "People on the site in the last five minutes, the pages they are reading, where they came from, their countries, and the latest activity.",
                new JsObject { ["type"] = "object", ["properties"] = new JsObject { ["site"] = range["site"] } },
                Read("/api/realtime", ["site"]),
                null),
            new(
                "list_goals",
                "Goals and conversions",
                "Every goal with its conversions, converted visitors, conversion rate (0 to 1), and revenue for a range, with the comparison range's numbers as previous.",
                new JsObject { ["type"] = "object", ["properties"] = Merge(range, compare) },
                Read("/api/goals", CompareKeys),
                null),
            new(
                "get_goal",
                "One goal in detail",
                "One goal's conversions over time and by channel, source, and page. Find the goal_id with list_goals.",
                new JsObject { ["type"] = "object", ["properties"] = Merge(range, new JsObject { ["goal_id"] = new JsObject { ["type"] = "string" } }), ["required"] = Strings("goal_id") },
                args =>
                {
                    object? id = Arg(args, "goal_id");
                    return new McpRead("/api/goals/" + Js.EncodeURIComponent(Js.String(id is null or Undefined ? "" : id)), RangeParams(args, RangeKeys));
                },
                null),
            new(
                "get_journeys",
                "Paths through the site",
                "The paths visits take, page by page: the top pages at each step, how many went no further, the flows between steps, and the commonest whole paths. A refresh counts once. start and end follow only paths from or to a page.",
                new JsObject
                {
                    ["type"] = "object",
                    ["properties"] = Merge(range, new JsObject
                    {
                        ["steps"] = new JsObject { ["type"] = "integer", ["minimum"] = 2L, ["maximum"] = 8L, ["description"] = "How many pages of each path. Defaults to 5." },
                        ["start"] = new JsObject { ["type"] = "string", ["description"] = "Only paths from this page, such as /pricing." },
                        ["end"] = new JsObject { ["type"] = "string", ["description"] = "Only paths that reach this page, cut there." },
                    }),
                },
                Read("/api/journeys", [.. RangeKeys, "steps", "start", "end"]),
                null),
            new(
                "list_links",
                "Short links",
                "Every short link with its destination and its clicks in the range.",
                new JsObject { ["type"] = "object", ["properties"] = new JsObject { ["site"] = range["site"], ["period"] = range["period"], ["from"] = range["from"], ["to"] = range["to"] } },
                Read("/api/links", ["site", "period", "from", "to"]),
                null),
        ];
    }

    private static JsObject RpcError(object? id, int code, string message) => new()
    {
        ["jsonrpc"] = "2.0",
        ["id"] = id is Undefined ? null : id,
        ["error"] = new JsObject { ["code"] = (long)code, ["message"] = message },
    };

    /// <summary>
    /// Runs one tool by name, as the MCP server does; the dashboard's assistant calls it too.
    /// <paramref name="parameters"/> holds name and arguments. Answers { content: [{ type, text }], isError? }.
    /// </summary>
    /// <exception cref="McpError">For an unknown tool.</exception>
    public static async Task<JsObject> CallToolAsync(object? parameters, ApiRead readApi)
    {
        object? name = Arg(parameters, "name");
        var tool = Tools.FirstOrDefault(t => name is string s && s == t.Name)
            ?? throw new McpError("Unknown tool \"" + Js.String(name) + "\"", -32602);
        object? given = Arg(parameters, "arguments");
        object? args = Js.Truthy(given) && Js.IsObject(given) ? given : new JsObject();
        var (path, query) = tool.Request(args);
        var answer = await readApi(path, query).ConfigureAwait(false);
        byte[] bytes = await answer.BytesAsync().ConfigureAwait(false);
        if (!Js.ParseJson(bytes, out object? body))
        {
            body = new JsObject();
        }
        if (!answer.Ok)
        {
            object? error = Arg(body, "error");
            return new JsObject
            {
                ["content"] = new List<object?> { new JsObject { ["type"] = "text", ["text"] = Js.String(error is null or Undefined ? "Runlight answered " + Js.Str(answer.Status) : error) } },
                ["isError"] = true,
            };
        }
        return new JsObject
        {
            ["content"] = new List<object?> { new JsObject { ["type"] = "text", ["text"] = Json.Stringify(tool.Shape != null ? tool.Shape(body) : body) } },
        };
    }

    /// <summary>The answer to one message, or null for a notification.</summary>
    private static async Task<JsObject?> AnswerAsync(object? message, ApiRead readApi)
    {
        if (message is null)
        {
            throw new JsTypeError("Cannot read properties of null (reading 'id')");
        }
        object? id = Js.Get(message, "id");
        bool isNotification = id is Undefined;
        object? method = Js.Get(message, "method");
        if (Js.Get(message, "jsonrpc") is not "2.0" || method is not string methodName)
        {
            return isNotification ? null : RpcError(id, -32600, "Invalid request");
        }
        object? given = Js.Get(message, "params");
        object? parameters = Js.Truthy(given) && Js.IsObject(given) ? given : new JsObject();
        try
        {
            object? result;
            switch (methodName)
            {
                case "initialize":
                    {
                        object? asked = Arg(parameters, "protocolVersion");
                        string version = Js.String(asked is null or Undefined ? "" : asked);
                        result = new JsObject
                        {
                            ["protocolVersion"] = ProtocolVersions.Contains(version) ? version : ProtocolVersions[0],
                            ["capabilities"] = new JsObject { ["tools"] = new JsObject { ["listChanged"] = false } },
                            ["serverInfo"] = new JsObject { ["name"] = "runlight", ["title"] = "Runlight", ["version"] = Version.Current },
                            ["instructions"] = Instructions,
                        };
                        break;
                    }
                case "ping":
                    result = new JsObject();
                    break;
                case "tools/list":
                    result = new JsObject
                    {
                        ["tools"] = Tools.Select(t => (object?)new JsObject
                        {
                            ["name"] = t.Name,
                            ["title"] = t.Title,
                            ["description"] = t.Description,
                            ["inputSchema"] = t.InputSchema,
                            ["annotations"] = new JsObject { ["readOnlyHint"] = true, ["openWorldHint"] = false },
                        }).ToList(),
                    };
                    break;
                case "tools/call":
                    result = await CallToolAsync(parameters, readApi).ConfigureAwait(false);
                    break;
                default:
                    if (isNotification)
                    {
                        return null;
                    }
                    return RpcError(id, -32601, "Unknown method \"" + methodName + "\"");
            }
            return isNotification ? null : new JsObject { ["jsonrpc"] = "2.0", ["id"] = id, ["result"] = result };
        }
        catch (Exception error)
        {
            if (isNotification)
            {
                return null;
            }
            return error is McpError mcp ? RpcError(id, mcp.Code, mcp.Message) : RpcError(id, -32603, "Internal error");
        }
    }

    /// <summary>Answers one POST to the MCP endpoint, already authorised.</summary>
    /// <exception cref="JsTypeError">For a batch holding null, as the TypeScript throws.</exception>
    public static async Task<Response> McpResponseAsync(Request request, ApiRead readApi)
    {
        Headers JsonHeaders() => new() { ["content-type"] = "application/json; charset=utf-8", ["cache-control"] = "no-store" };
        if (!Js.ParseJson(request.Bytes(), out object? body) || !Js.IsObject(body))
        {
            return new Response(Json.Stringify(RpcError(null, -32700, "Send a JSON-RPC message")), 400, JsonHeaders());
        }
        // Batches were in the 2025-03-26 protocol; answering them costs nothing.
        if (body is List<object?> batch)
        {
            if (batch.Contains(null))
            {
                // Promise.all rejects with the first message that cannot be read.
                throw new JsTypeError("Cannot read properties of null (reading 'id')");
            }
            var answers = new List<object?>();
            foreach (object? message in batch)
            {
                var one = await AnswerAsync(message, readApi).ConfigureAwait(false);
                if (one != null)
                {
                    answers.Add(one);
                }
            }
            return answers.Count > 0 ? new Response(Json.Stringify(answers), 200, JsonHeaders()) : new Response("", 202);
        }
        var single = await AnswerAsync(body, readApi).ConfigureAwait(false);
        return single != null ? new Response(Json.Stringify(single), 200, JsonHeaders()) : new Response("", 202);
    }
}
