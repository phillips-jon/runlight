using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Runlight.Http;
using Xunit;
using static Runlight.Tests.Fixtures;

namespace Runlight.Tests;

/// <summary>
/// The assistant against tests/fixtures/assistant.json: for each provider and failure, the very requests the
/// TypeScript sends (bodies compared by SHA-256), the API reads its tools make, and what it answers.
/// </summary>
public sealed class AssistantTests
{
    private static JsObject Context() => new()
    {
        ["site"] = new JsObject { ["id"] = "default", ["name"] = "Blog", ["timezone"] = "UTC" },
        ["today"] = "2026-10-08",
        ["view"] = "today",
        ["language"] = "en",
    };

    /// <summary>Headers as an object with its names in order, so two sets compare whatever order they were set in.</summary>
    private static string Sorted(JsObject? headers) =>
        J(JsObject.From((headers ?? []).OrderBy(e => e.Key, StringComparer.Ordinal)));

    [Fact]
    public async Task Scenarios_send_the_same_requests_and_answer_the_same()
    {
        var failures = new List<string>();
        foreach (JsObject scenario in Load("assistant").Arr("scenarios")!)
        {
            string name = scenario.Str("name")!;
            var queue = scenario.Arr("responses")!.Cast<JsObject>()
                .Select(c => c.Has("throws") ? (object)c.Str("throws")! : new Response(c.Str("body")!, (int)c.Num("status"), new Headers { ["content-type"] = "application/json" }))
                .ToArray();
            var fetcher = new RecordingFetcher(queue);
            var tools = new List<object?>();
            try
            {
                object result = scenario.Str("call") == "chat"
                    ? await Assistant.ChatAsync(scenario.Obj("settings")!, scenario.Arr("messages")!.Cast<JsObject>().ToList(), scenario.Obj("context")!, McpTests.ReadApi(tools), fetcher)
                    : await Assistant.ListModelsAsync(scenario.Obj("settings")!, fetcher);
                if (!scenario.Has("result"))
                {
                    failures.Add(name + " answered " + J(result));
                }
                else if (J(scenario.Get("result")) != J(result))
                {
                    failures.Add(name + " answered " + J(result));
                }
            }
            catch (AssistantError error)
            {
                var want = scenario.Obj("error");
                if (want == null)
                {
                    failures.Add(name + " threw " + error.Message);
                }
                else if (want.Str("message") != error.Message || want.Str("code") != error.Code || J(want.Get("params")) != J(error.Params))
                {
                    failures.Add(name + " threw " + error.Code + " " + error.Message + " " + J(error.Params));
                }
            }
            if (J(scenario.Get("tools")) != J(tools))
            {
                failures.Add(name + " read the API as " + J(tools));
            }
            var requests = scenario.Arr("requests")!.Cast<JsObject>().ToList();
            if (requests.Count != fetcher.Requests.Count)
            {
                failures.Add(name + " sent " + fetcher.Requests.Count + " requests");
                continue;
            }
            for (int i = 0; i < requests.Count; i++)
            {
                var want = requests[i];
                var sent = fetcher.Requests[i];
                if (want.Str("url") != sent.Url || want.Str("method") != sent.Method)
                {
                    failures.Add(name + " request " + i + " " + sent.Method + " " + sent.Url);
                }
                if (Sorted(want.Obj("headers")) != Sorted(sent.Headers))
                {
                    failures.Add(name + " request " + i + " headers " + J(sent.Headers));
                }
                string? sha = sent.Init.Body == null ? null : Hash.Sha256(sent.Init.Body);
                if (want.Str("bodySha256") != sha)
                {
                    failures.Add(name + " request " + i + " body " + sent.Body);
                }
            }
        }
        NoFailures(failures, 5);
    }

    [Fact]
    public void Acknowledgements_match()
    {
        var failures = new List<string>();
        foreach (JsObject c in Load("assistant").Arr("acknowledgements")!)
        {
            string? got = Assistant.Acknowledgement(c.Str("text")!, c.Str("language")!);
            if (got != c.Str("reply"))
            {
                failures.Add(J(new List<object?> { c.Get("text"), c.Get("language") }) + " gave " + (got ?? "null"));
            }
        }
        NoFailures(failures);
    }

    [Fact]
    public void Thanks_gets_a_short_reply_without_the_model_or_the_tools()
    {
        foreach (string text in new[] { "Thanks!", "thank you", "Thanks!! \U0001F64F", "ok", "Great, thanks.", "\U0001F44D", "merci beaucoup", "Danke schön!", "valeu" })
        {
            Assert.NotNull(Assistant.Acknowledgement(text, "en"));
        }
        foreach (string text in new[] { "Thanks, and what about last week?", "What was my bounce rate?", "ok so which pages?", "great results?" })
        {
            Assert.Null(Assistant.Acknowledgement(text, "en"));
        }
        Assert.Contains("plaisir", Assistant.Acknowledgement("merci", "fr"), StringComparison.Ordinal);
    }

    [Fact]
    public async Task Each_request_has_the_time_left_and_the_deadline_stops_the_rest()
    {
        long clock = 1_000_000;
        Response ToolUse(string id) => new(Json.Stringify(new JsObject
        {
            ["stop_reason"] = "tool_use",
            ["content"] = new List<object?> { new JsObject { ["type"] = "tool_use", ["id"] = id, ["name"] = "list_sites", ["input"] = new JsObject() } },
        }));
        var fetcher = new RecordingFetcher(ToolUse("a"), ToolUse("b"), ToolUse("c"));
        var log = new List<object?>();
        var readApi = McpTests.ReadApi(log);
        ApiRead slowApi = (path, parameters) =>
        {
            clock += 50_000;
            return readApi(path, parameters);
        };
        var settings = new JsObject { ["provider"] = "anthropic", ["model"] = "m", ["baseUrl"] = "", ["key"] = "k" };
        var messages = new List<JsObject> { new() { ["role"] = "user", ["content"] = "All of it" } };
        var error = await Assert.ThrowsAsync<AssistantError>(() => Assistant.ChatAsync(settings, messages, Context(), slowApi, fetcher, () => clock));
        Assert.Equal("assistant_slow", error.Code);
        Assert.Equal([90_000, 70_000, 20_000], fetcher.Requests.Select(r => r.TimeoutMs).ToArray());
        Assert.Equal(3, log.Count);
    }

    [Fact]
    public async Task A_cancelled_question_stops_before_its_next_request()
    {
        var fetcher = new RecordingFetcher();
        var settings = new JsObject { ["provider"] = "openai", ["model"] = "m", ["baseUrl"] = "", ["key"] = "k" };
        var messages = new List<JsObject> { new() { ["role"] = "user", ["content"] = "Hi?" } };
        using var cancelled = new CancellationTokenSource();
        await cancelled.CancelAsync();
        var error = await Assert.ThrowsAsync<AssistantError>(() => Assistant.ChatAsync(settings, messages, Context(), McpTests.ReadApi([]), fetcher, null, cancelled.Token));
        Assert.Equal("assistant_cancelled", error.Code);
        Assert.Equal("The question was cancelled.", error.Message);
        Assert.Empty(fetcher.Requests);
    }

    [Fact]
    public async Task Models_are_listed_within_twenty_seconds()
    {
        var fetcher = new RecordingFetcher(new Response("{\"data\":[{\"id\":\"b\"},{\"id\":\"a\"}]}"));
        var models = await Assistant.ListModelsAsync(new JsObject { ["provider"] = "ollama", ["baseUrl"] = "", ["key"] = "" }, fetcher);
        Assert.Equal("[{\"id\":\"a\",\"name\":\"a\"},{\"id\":\"b\",\"name\":\"b\"}]", J(models));
        Assert.Equal(20_000, fetcher.Requests[0].TimeoutMs);
        Assert.Equal("http://localhost:11434/v1/models", fetcher.Requests[0].Url);
    }
}
