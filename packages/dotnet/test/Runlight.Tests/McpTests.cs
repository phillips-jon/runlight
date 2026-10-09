using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Runlight.Http;
using Xunit;
using static Runlight.Tests.Fixtures;

namespace Runlight.Tests;

/// <summary>
/// The MCP server against tests/fixtures/mcp.json: the TypeScript's API reads and answers for the same JSON-RPC
/// messages and tool arguments, over canned API answers. The parts of mcp.test.ts that need no store are here too.
/// </summary>
public sealed class McpTests
{
    /// <summary>A readApi that logs each read as { path, params } and answers from the fixture's canned API.</summary>
    public static ApiRead ReadApi(List<object?> log)
    {
        var api = Load("mcp").Obj("api")!;
        return (path, parameters) =>
        {
            log.Add(new JsObject
            {
                ["path"] = path,
                ["params"] = parameters.Select(p => (object?)new List<object?> { p.Key, p.Value }).ToList(),
            });
            var canned = api.Obj(path) ?? new JsObject { ["status"] = 404.0, ["body"] = "{\"error\":\"Not found: " + path.Replace("\"", "", StringComparison.Ordinal) + "\"}" };
            return Task.FromResult(new Response(canned.Str("body")!, (int)canned.Num("status"), new Headers { ["content-type"] = "application/json" }));
        };
    }

    private static Request Post(string url, byte[] body) => new(url, "POST", null, body);

    private static Request Post(string url, string body) => new(url, "POST", null, Js.Utf8(body));

    [Fact]
    public async Task Tool_calls_read_the_same_api_and_answer_the_same()
    {
        var failures = new List<string>();
        foreach (JsObject c in Load("mcp").Arr("calls")!)
        {
            string label = J(c.Get("params"));
            var log = new List<object?>();
            JsObject result;
            try
            {
                result = await Mcp.CallToolAsync(c.Get("params"), ReadApi(log));
            }
            catch (McpError error)
            {
                if (!c.Has("throws"))
                {
                    failures.Add(label + " threw " + error.Message);
                }
                else if (c.Str("message") != error.Message || error.Code != -32602)
                {
                    failures.Add(label + " threw " + error.Message);
                }
                continue;
            }
            if (c.Has("throws"))
            {
                failures.Add(label + " should throw");
                continue;
            }
            if (J(c.Get("requests")) != J(log))
            {
                failures.Add(label + " read " + J(log));
            }
            if (J(c.Get("value")) != J(result))
            {
                failures.Add(label + " answered " + J(result));
            }
        }
        NoFailures(failures);
    }

    [Fact]
    public async Task Json_rpc_answers_match()
    {
        var failures = new List<string>();
        foreach (JsObject c in Load("mcp").Arr("rpcs")!)
        {
            byte[] body = c.Has("bodyHex") ? Convert.FromHexString(c.Str("bodyHex")!) : Js.Utf8(c.Str("body")!);
            string label = Label(Js.Decode(body));
            var log = new List<object?>();
            var request = Post("https://example.com/runlight/mcp", body);
            if (c.Has("throws"))
            {
                await Assert.ThrowsAsync<JsTypeError>(() => Mcp.McpResponseAsync(request, ReadApi(log)));
                continue;
            }
            var answer = await Mcp.McpResponseAsync(request, ReadApi(log));
            var headers = new JsObject();
            foreach (var (name, value) in answer.Headers)
            {
                headers[name] = value;
            }
            if ((long)c.Num("status") != answer.Status)
            {
                failures.Add(label + " status " + answer.Status);
            }
            if (J(c.Get("headers")) != J(headers))
            {
                failures.Add(label + " headers " + J(headers));
            }
            if (c.Str("text") != answer.Text())
            {
                failures.Add(label + " answered " + answer.Text());
            }
            if (J(c.Get("requests")) != J(log))
            {
                failures.Add(label + " read " + J(log));
            }
        }
        NoFailures(failures);
    }

    [Fact]
    public async Task Tools_are_listed_read_only_in_order()
    {
        var log = new List<object?>();
        var answer = await Mcp.McpResponseAsync(Post("https://x.com/mcp", "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}"), ReadApi(log));
        var tools = ((JsObject)Json.Parse(answer.Text())!).Obj("result")!.Arr("tools")!.Cast<JsObject>().ToList();
        Assert.Equal(J(Load("mcp").Get("tools")), J(tools.Select(t => (object?)t.Str("name")).ToList()));
        foreach (var tool in tools)
        {
            Assert.True(tool.Obj("annotations")!.Bool("readOnlyHint"));
        }
        Assert.Contains("\"properties\":{}", answer.Text(), StringComparison.Ordinal);
    }

    [Fact]
    public async Task Initialize_answers_the_asked_version_or_the_newest()
    {
        var log = new List<object?>();
        async Task<JsObject> Ask(string version)
        {
            string body = Json.Stringify(new JsObject { ["jsonrpc"] = "2.0", ["id"] = 1L, ["method"] = "initialize", ["params"] = new JsObject { ["protocolVersion"] = version } });
            var answer = await Mcp.McpResponseAsync(Post("https://x.com/mcp", body), ReadApi(log));
            return ((JsObject)Json.Parse(answer.Text())!).Obj("result")!;
        }
        Assert.Equal("2025-06-18", (await Ask("2025-06-18")).Str("protocolVersion"));
        Assert.Equal("runlight", (await Ask("2025-06-18")).Obj("serverInfo")!.Str("name"));
        Assert.Equal("2025-11-25", (await Ask("1999-01-01")).Str("protocolVersion"));
        var note = await Mcp.McpResponseAsync(Post("https://x.com/mcp", "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"), ReadApi(log));
        Assert.Equal(202, note.Status);
        Assert.Equal("", note.Text());
    }
}
