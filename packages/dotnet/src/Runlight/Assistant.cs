using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Runlight.Http;

namespace Runlight;

/// <summary>One provider the assistant can use.</summary>
/// <param name="Id">The provider's id in settings.</param>
/// <param name="Name">Its name, as the dashboard shows it.</param>
/// <param name="Protocol">"anthropic" or "openai".</param>
/// <param name="BaseUrl">The API's address, filled in for known services and asked for otherwise.</param>
/// <param name="Model">One to start with, or "" when the person picks one.</param>
/// <param name="Key">"yes", "no" for a model on your own machine, or "optional".</param>
public sealed record AssistantProvider(string Id, string Name, string Protocol, string BaseUrl, string Model, string Key);

/// <summary>
/// The dashboard's assistant: questions about the stats, answered by a model
/// the owner chooses, through the same read-only tools as the MCP server. The
/// model runs on the server, so the key never reaches a browser, and each tool
/// reads the API with the asking person's own access.
///
/// Two protocols cover the providers: Anthropic's Messages API, and OpenAI's
/// Chat Completions, which OpenAI, Gemini (through its compatible endpoint),
/// OpenRouter, Ollama, LM Studio, and most others speak. Plain HTTP through an
/// IFetcher, no SDKs.
///
/// Settings are { provider, model, baseUrl, key }; messages are [{ role: "user" | "assistant", content }]; the
/// context (what the person is looking at, so "this week" and "this page" mean what they see) is
/// { site: { id, name, timezone }, today, view, language }.
/// </summary>
public static class Assistant
{
    /// <summary>Each provider the assistant knows, in the order the dashboard offers them.</summary>
    public static readonly IReadOnlyList<AssistantProvider> Providers =
    [
        new("anthropic", "Anthropic (Claude)", "anthropic", "https://api.anthropic.com/v1", "claude-sonnet-5-5", "yes"),
        new("openai", "OpenAI", "openai", "https://api.openai.com/v1", "", "yes"),
        new("gemini", "Google Gemini", "openai", "https://generativelanguage.googleapis.com/v1beta/openai", "", "yes"),
        new("openrouter", "OpenRouter", "openai", "https://openrouter.ai/api/v1", "", "yes"),
        new("ollama", "Ollama", "openai", "http://localhost:11434/v1", "", "no"),
        new("lmstudio", "LM Studio", "openai", "http://localhost:1234/v1", "", "no"),
        new("custom", "Another OpenAI-compatible service", "openai", "", "", "optional"),
    ];

    private const int MaxRounds = 8;

    /// <summary>However many rounds a question takes, the answer comes within this long or the assistant stops.</summary>
    public const long DeadlineMs = 120_000;

    private const long MaxTokens = 1500;

    private const string TooLong = "That question took too long to answer. Try asking something narrower.";

    private const string TooManySteps = "The assistant needed too many steps for that question. Try asking something narrower.";

    /// <summary>
    /// Words that only acknowledge an answer, in the dashboard's languages; a message of nothing else gets a reply
    /// without the model. JavaScript's /iu is matched by folding the text first (<see cref="Fold"/>) against lowercase words.
    /// </summary>
    private static readonly Regex Thanks = new(
        "^(?:(?:thanks|thank you|thank you so much|thanks a lot|thx|ty|cheers|ok|okay|great|cool|nice|perfect|awesome|got it|good|merci|merci beaucoup|super|parfait|d'accord|gracias|muchas gracias|vale|genial|perfecto|danke|danke schön|vielen dank|prima|alles klar|obrigado|obrigada|valeu|ótimo|beleza)"
        + "[\\t\\n\\v\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF!.,]*)+\\z",
        RegexOptions.CultureInvariant);

    private static readonly Dictionary<string, string> Welcome = new(StringComparer.Ordinal)
    {
        ["en"] = "You're welcome. Ask me anything else about your stats.",
        ["fr"] = "Avec plaisir. Demandez-moi autre chose sur vos statistiques.",
        ["es"] = "De nada. Pregúntame lo que quieras sobre tus estadísticas.",
        ["de"] = "Gern geschehen. Frag mich gern noch etwas zu deinen Statistiken.",
        ["pt"] = "De nada. Pergunte o que quiser sobre suas estatísticas.",
    };

    /// <summary>Unicode 17's Extended_Pictographic, as first and last code point pairs (Node 24's /\p{Extended_Pictographic}/u).</summary>
    private static readonly int[] Pictographic =
    [
        0xA9, 0xA9, 0xAE, 0xAE, 0x203C, 0x203C, 0x2049, 0x2049, 0x2122, 0x2122, 0x2139, 0x2139, 0x2194, 0x2199, 0x21A9, 0x21AA,
        0x231A, 0x231B, 0x2328, 0x2328, 0x23CF, 0x23CF, 0x23E9, 0x23F3, 0x23F8, 0x23FA, 0x24C2, 0x24C2, 0x25AA, 0x25AB, 0x25B6, 0x25B6,
        0x25C0, 0x25C0, 0x25FB, 0x25FE, 0x2600, 0x2604, 0x260E, 0x260E, 0x2611, 0x2611, 0x2614, 0x2615, 0x2618, 0x2618, 0x261D, 0x261D,
        0x2620, 0x2620, 0x2622, 0x2623, 0x2626, 0x2626, 0x262A, 0x262A, 0x262E, 0x262F, 0x2638, 0x263A, 0x2640, 0x2640, 0x2642, 0x2642,
        0x2648, 0x2653, 0x265F, 0x2660, 0x2663, 0x2663, 0x2665, 0x2666, 0x2668, 0x2668, 0x267B, 0x267B, 0x267E, 0x267F, 0x2692, 0x2697,
        0x2699, 0x2699, 0x269B, 0x269C, 0x26A0, 0x26A1, 0x26A7, 0x26A7, 0x26AA, 0x26AB, 0x26B0, 0x26B1, 0x26BD, 0x26BE, 0x26C4, 0x26C5,
        0x26C8, 0x26C8, 0x26CE, 0x26CF, 0x26D1, 0x26D1, 0x26D3, 0x26D4, 0x26E9, 0x26EA, 0x26F0, 0x26F5, 0x26F7, 0x26FA, 0x26FD, 0x26FD,
        0x2702, 0x2702, 0x2705, 0x2705, 0x2708, 0x270D, 0x270F, 0x270F, 0x2712, 0x2712, 0x2714, 0x2714, 0x2716, 0x2716, 0x271D, 0x271D,
        0x2721, 0x2721, 0x2728, 0x2728, 0x2733, 0x2734, 0x2744, 0x2744, 0x2747, 0x2747, 0x274C, 0x274C, 0x274E, 0x274E, 0x2753, 0x2755,
        0x2757, 0x2757, 0x2763, 0x2764, 0x2795, 0x2797, 0x27A1, 0x27A1, 0x27B0, 0x27B0, 0x27BF, 0x27BF, 0x2934, 0x2935, 0x2B05, 0x2B07,
        0x2B1B, 0x2B1C, 0x2B50, 0x2B50, 0x2B55, 0x2B55, 0x3030, 0x3030, 0x303D, 0x303D, 0x3297, 0x3297, 0x3299, 0x3299, 0x1F004, 0x1F004,
        0x1F02C, 0x1F02F, 0x1F094, 0x1F09F, 0x1F0AF, 0x1F0B0, 0x1F0C0, 0x1F0C0, 0x1F0CF, 0x1F0D0, 0x1F0F6, 0x1F0FF, 0x1F170, 0x1F171,
        0x1F17E, 0x1F17F, 0x1F18E, 0x1F18E, 0x1F191, 0x1F19A, 0x1F1AE, 0x1F1E5, 0x1F201, 0x1F20F, 0x1F21A, 0x1F21A, 0x1F22F, 0x1F22F,
        0x1F232, 0x1F23A, 0x1F23C, 0x1F23F, 0x1F249, 0x1F25F, 0x1F266, 0x1F321, 0x1F324, 0x1F393, 0x1F396, 0x1F397, 0x1F399, 0x1F39B,
        0x1F39E, 0x1F3F0, 0x1F3F3, 0x1F3F5, 0x1F3F7, 0x1F3FA, 0x1F400, 0x1F4FD, 0x1F4FF, 0x1F53D, 0x1F549, 0x1F54E, 0x1F550, 0x1F567,
        0x1F56F, 0x1F570, 0x1F573, 0x1F57A, 0x1F587, 0x1F587, 0x1F58A, 0x1F58D, 0x1F590, 0x1F590, 0x1F595, 0x1F596, 0x1F5A4, 0x1F5A5,
        0x1F5A8, 0x1F5A8, 0x1F5B1, 0x1F5B2, 0x1F5BC, 0x1F5BC, 0x1F5C2, 0x1F5C4, 0x1F5D1, 0x1F5D3, 0x1F5DC, 0x1F5DE, 0x1F5E1, 0x1F5E1,
        0x1F5E3, 0x1F5E3, 0x1F5E8, 0x1F5E8, 0x1F5EF, 0x1F5EF, 0x1F5F3, 0x1F5F3, 0x1F5FA, 0x1F64F, 0x1F680, 0x1F6C5, 0x1F6CB, 0x1F6D2,
        0x1F6D5, 0x1F6E5, 0x1F6E9, 0x1F6E9, 0x1F6EB, 0x1F6F0, 0x1F6F3, 0x1F6FF, 0x1F7DA, 0x1F7FF, 0x1F80C, 0x1F80F, 0x1F848, 0x1F84F,
        0x1F85A, 0x1F85F, 0x1F888, 0x1F88F, 0x1F8AE, 0x1F8AF, 0x1F8BC, 0x1F8BF, 0x1F8C2, 0x1F8CF, 0x1F8D9, 0x1F8FF, 0x1F90C, 0x1F93A,
        0x1F93C, 0x1F945, 0x1F947, 0x1F9FF, 0x1FA58, 0x1FA5F, 0x1FA6E, 0x1FAFF, 0x1FC00, 0x1FFFD,
    ];

    private static readonly CompareInfo Collation = CultureInfo.GetCultureInfo("en").CompareInfo;

    private static AssistantProvider? Provider(object? id) => Providers.FirstOrDefault(p => id is string s && s == p.Id);

    /// <summary>settings[key] as text, "" when it is missing or empty.</summary>
    private static string Setting(JsObject settings, string key)
    {
        object? value = settings.Get(key);
        return value is null or Undefined ? "" : Js.String(value);
    }

    private static string Text(object? value) => Js.String(value);

    private static string System(JsObject context)
    {
        object? site = context.Prop("site");
        return Mcp.Instructions + "\n\nYou are the assistant inside this Runlight dashboard. Today is " + Text(context.Prop("today")) + " in " + Text(Js.Get(site, "timezone"))
            + ". The person is looking at the site \"" + Text(Js.Get(site, "name")) + "\" (id " + Text(Js.Get(site, "id")) + ") for " + Text(context.Prop("view"))
            + ". Unless they ask about another site or range, use this site and these dates.\n\n"
            + "When a question needs numbers, read them with the tools first and never guess one. Answer in a few short sentences or a short list, in plain language, and name the dates you looked at.\n\n"
            + "Rule: answer only the newest message. If it asks nothing new (thanks, a greeting, \"great\", \"that helps\"), reply with one short friendly sentence, call no tools, and do not repeat, summarise, or re-check any earlier answer. Only go back to earlier numbers when the person asks about them again. Bounce rate is a fraction from 0 to 1 and durations are milliseconds in the tools; give them as a percent and in seconds or minutes. Write in the language whose code is \""
            + Text(context.Prop("language")) + "\".";
    }

    /// <summary>Stops when the question's time is up or the person has left, before more work starts.</summary>
    private static void InTime(long deadline, Func<long> now, CancellationToken cancellationToken)
    {
        if (cancellationToken.IsCancellationRequested)
        {
            throw new AssistantError("The question was cancelled.", "assistant_cancelled");
        }
        if (now() >= deadline)
        {
            throw new AssistantError(TooLong, "assistant_slow");
        }
    }

    /// <summary>The service's own message from an error answer, never the request (it carries the key); "" when there is none.</summary>
    private static string ServiceMessage(object? data)
    {
        object? error = data is null ? Undefined.Value : Js.Get(data, "error");
        if (error is string s)
        {
            return s;
        }
        object? message = error is null or Undefined ? null : Js.Get(error, "message");
        return message as string ?? "";
    }

    /// <summary>A refusal from a service, in its own words when it gives them.</summary>
    private static AssistantError Refused(Response answer, object? data, string address)
    {
        string message = ServiceMessage(data);
        string host = new Url(address).Host;
        if (message.Length == 0)
        {
            return new AssistantError(host + ": it answered " + Js.Str(answer.Status), "assistant_status", new JsObject { ["host"] = host, ["status"] = Js.Str(answer.Status) });
        }
        string detail = Js.Slice(message, 0, 300);
        return new AssistantError(host + ": " + detail, "assistant_refused", new JsObject { ["host"] = host, ["detail"] = detail });
    }

    /// <summary>A service that answered, but not in its protocol's shape.</summary>
    private static AssistantError Unreadable(string url)
    {
        string host = new Url(url).Host;
        string message = host + " sent an answer Runlight could not read";
        return new AssistantError(message, "assistant_failed", new JsObject { ["host"] = host, ["detail"] = message });
    }

    private static async Task<object?> PostAsync(IFetcher fetcher, string url, Headers headers, object? body, long deadline, Func<long> now, CancellationToken cancellationToken)
    {
        InTime(deadline, now, cancellationToken);
        long left = deadline - now();
        var all = new Headers { ["content-type"] = "application/json" };
        foreach (var (name, values) in headers.All())
        {
            all.Set(name, string.Join(", ", values));
        }
        Response answer;
        byte[] bytes;
        try
        {
            answer = await fetcher.FetchAsync(url, new FetchInit
            {
                Method = "POST",
                Headers = all,
                BodyText = Json.Stringify(body),
                TimeoutMs = (int)Math.Min(90_000, left),
            }, cancellationToken).ConfigureAwait(false);
            bytes = await answer.BytesAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            string host = new Url(url).Host;
            throw error is FetchException { TimedOut: true }
                ? new AssistantError("Could not reach " + host + ": it took too long to answer", "assistant_timeout", new JsObject { ["host"] = host })
                : new AssistantError("Could not reach " + host + ": the connection failed", "unreachable", new JsObject { ["host"] = host });
        }
        object? data = Js.ParseJson(bytes, out object? parsed) ? parsed : null;
        if (!answer.Ok)
        {
            throw Refused(answer, data, url);
        }
        return data ?? new JsObject();
    }

    private static async Task<(string Text, bool Error)> ToolTextAsync(object? name, object? args, ApiRead readApi)
    {
        try
        {
            var result = await Mcp.CallToolAsync(new JsObject { ["name"] = name, ["arguments"] = Js.Truthy(args) && Js.IsObject(args) ? args : new JsObject() }, readApi).ConfigureAwait(false);
            var content = result.Arr("content");
            string text = content is { Count: > 0 } && content[0] is JsObject first && first.Get("text") is string t ? t : "";
            return (text, result.Get("isError") is true);
        }
        catch (Exception error)
        {
            return (error.Message, true);
        }
    }

    /// <summary>The text with each letter JavaScript's /iu folds onto one of the words folded, so a lowercase pattern matches as /iu does.</summary>
    private static string Fold(string text)
    {
        var b = new StringBuilder(text.Length);
        foreach (char c in text)
        {
            b.Append(c switch
            {
                >= 'A' and <= 'Z' => (char)(c + 32),
                (char)0x212A => 'k',
                (char)0x017F => 's',
                (char)0x00D3 => (char)0x00F3,
                (char)0x00D6 => (char)0x00F6,
                _ => c,
            });
        }
        return b.ToString();
    }

    private static bool IsPictographic(int cp)
    {
        for (int i = 0; i < Pictographic.Length; i += 2)
        {
            if (cp < Pictographic[i])
            {
                return false;
            }
            if (cp <= Pictographic[i + 1])
            {
                return true;
            }
        }
        return false;
    }

    /// <summary>text.replace(/\p{Extended_Pictographic}|️/gu, " ").</summary>
    private static string WithoutPictographs(string text)
    {
        var b = new StringBuilder(text.Length);
        for (int i = 0; i < text.Length; i++)
        {
            char c = text[i];
            if (char.IsHighSurrogate(c) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1]))
            {
                int cp = char.ConvertToUtf32(c, text[i + 1]);
                if (IsPictographic(cp))
                {
                    b.Append(' ');
                }
                else
                {
                    b.Append(c).Append(text[i + 1]);
                }
                i++;
            }
            else
            {
                b.Append(c == (char)0xFE0F || IsPictographic(c) ? ' ' : c);
            }
        }
        return b.ToString();
    }

    /// <summary>A short reply to a message that only says thanks or OK, or null when the message asks something.</summary>
    public static string? Acknowledgement(string text, string language)
    {
        string plain = Js.Trim(WithoutPictographs(text));
        string welcome = Welcome.TryGetValue(language, out string? w) ? w : Welcome["en"];
        if (plain.Length == 0 && Js.Trim(text).Length > 0)
        {
            return welcome;
        }
        return Thanks.IsMatch(Fold(plain)) ? welcome : null;
    }

    private static string BaseOf(JsObject settings, AssistantProvider provider)
    {
        string given = Setting(settings, "baseUrl");
        return Regex.Replace(given.Length > 0 ? given : provider.BaseUrl, "/+\\z", "", RegexOptions.CultureInvariant);
    }

    private static long WallClock() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

    /// <summary>
    /// Answers the last question in <paramref name="messages"/>, calling tools as the model asks. Returns
    /// { reply, tools }: the reply and the tools it used. <paramref name="now"/> is the clock in milliseconds;
    /// <paramref name="cancellationToken"/> says whether the person has left, checked before each request and tool,
    /// as the TypeScript's AbortSignal is, and passed to each request.
    /// </summary>
    /// <exception cref="AssistantError">When the question cannot be answered.</exception>
    public static async Task<JsObject> ChatAsync(
        JsObject settings,
        IReadOnlyList<JsObject> messages,
        JsObject context,
        ApiRead readApi,
        IFetcher fetcher,
        Func<long>? now = null,
        CancellationToken cancellationToken = default)
    {
        now ??= WallClock;
        var provider = Provider(settings.Get("provider")) ?? throw new AssistantError("Choose a provider in Settings, AI Assistant", "assistant_provider");
        string @base = BaseOf(settings, provider);
        if (@base.Length == 0)
        {
            throw new AssistantError("Enter the service's address in Settings, AI Assistant", "assistant_address");
        }
        string givenModel = Setting(settings, "model");
        string model = givenModel.Length > 0 ? givenModel : provider.Model;
        if (model.Length == 0)
        {
            throw new AssistantError("Enter a model in Settings, AI Assistant", "assistant_model");
        }
        string key = Setting(settings, "key");
        var used = new List<object?>();
        // "Thanks!" needs no model, no tools, and certainly not the last answer again.
        object? last = messages.Count == 0 ? null : messages[^1].Get("content");
        string? thanks = Acknowledgement(last is null or Undefined ? "" : Js.String(last), Text(context.Prop("language")));
        if (thanks != null)
        {
            return new JsObject { ["reply"] = thanks, ["tools"] = new List<object?>() };
        }
        long deadline = now() + DeadlineMs;
        // The last twenty turns, starting with a question (Anthropic refuses a history that opens with an answer),
        // and with unanswered questions in a row (a reply that never came) joined into one.
        var recent = messages.Skip(Math.Max(0, messages.Count - 20)).SkipWhile(m => m.Get("role") is not "user").ToList();
        var history = new List<JsObject>();
        foreach (var m in recent)
        {
            string content = Js.Slice(Js.String(m.Prop("content")), 0, 8000);
            object? role = m.Prop("role");
            if (history.Count > 0 && Equals(history[^1].Get("role"), role))
            {
                history[^1]["content"] = (string)history[^1].Get("content")! + "\n\n" + content;
            }
            else
            {
                history.Add(new JsObject { ["role"] = role, ["content"] = content });
            }
        }

        if (provider.Protocol == "anthropic")
        {
            var tools = Mcp.Tools.Select(t => (object?)new JsObject { ["name"] = t.Name, ["description"] = t.Description, ["input_schema"] = t.InputSchema }).ToList();
            var convo = history.Select(h => (object?)h).ToList();
            var headers = new Headers { ["x-api-key"] = key, ["anthropic-version"] = "2023-06-01" };
            for (int round = 0; round < MaxRounds; round++)
            {
                var data = await PostAsync(
                    fetcher,
                    @base + "/messages",
                    headers,
                    new JsObject { ["model"] = model, ["max_tokens"] = MaxTokens, ["system"] = System(context), ["tools"] = tools, ["messages"] = convo },
                    deadline,
                    now,
                    cancellationToken).ConfigureAwait(false);
                object? content = Js.Get(data, "content");
                if (content is null or Undefined)
                {
                    content = new List<object?>();
                }
                if (content is not List<object?> blocks || !blocks.All(b => b is JsObject))
                {
                    throw Unreadable(@base);
                }
                var calls = blocks.Where(b => Js.Get(b, "type") is "tool_use").ToList();
                if (Js.Get(data, "stop_reason") is not "tool_use" || calls.Count == 0)
                {
                    var texts = new List<string>();
                    foreach (object? b in blocks)
                    {
                        if (Js.Get(b, "type") is "text")
                        {
                            object? text = Js.Get(b, "text");
                            texts.Add(text is null or Undefined ? "" : Js.String(text));
                        }
                    }
                    return new JsObject { ["reply"] = Js.Trim(string.Join('\n', texts)), ["tools"] = used };
                }
                convo.Add(new JsObject { ["role"] = "assistant", ["content"] = blocks });
                var results = new List<object?>();
                foreach (object? call in calls)
                {
                    // The deadline covers the reading too, however many tools one answer asks for.
                    InTime(deadline, now, cancellationToken);
                    object? name = Js.Get(call, "name");
                    name = name is null or Undefined ? "" : name;
                    used.Add(name);
                    var (text, error) = await ToolTextAsync(name, Js.Get(call, "input"), readApi).ConfigureAwait(false);
                    var result = new JsObject { ["type"] = "tool_result", ["tool_use_id"] = Js.Get(call, "id"), ["content"] = text };
                    if (error)
                    {
                        result["is_error"] = true;
                    }
                    results.Add(result);
                }
                convo.Add(new JsObject { ["role"] = "user", ["content"] = results });
            }
            throw new AssistantError(TooManySteps, "assistant_steps");
        }

        var functions = Mcp.Tools.Select(t => (object?)new JsObject
        {
            ["type"] = "function",
            ["function"] = new JsObject { ["name"] = t.Name, ["description"] = t.Description, ["parameters"] = t.InputSchema },
        }).ToList();
        var chat = new List<object?> { new JsObject { ["role"] = "system", ["content"] = System(context) } };
        chat.AddRange(history);
        var bearer = key.Length > 0 ? new Headers { ["authorization"] = "Bearer " + key } : new Headers();
        for (int round = 0; round < MaxRounds; round++)
        {
            // OpenAI's newer models take max_completion_tokens and refuse max_tokens; the other services still take max_tokens.
            var body = new JsObject { ["model"] = model };
            body[provider.Id == "openai" ? "max_completion_tokens" : "max_tokens"] = MaxTokens;
            body["messages"] = chat;
            body["tools"] = functions;
            var data = await PostAsync(fetcher, @base + "/chat/completions", bearer, body, deadline, now, cancellationToken).ConfigureAwait(false);
            object? message = FirstMessage(data);
            object? calls = Js.Get(message, "tool_calls");
            object? count = calls is null or Undefined ? Undefined.Value : Js.Get(calls, "length");
            object? content = Js.Get(message, "content");
            if (!Js.Truthy(count))
            {
                return new JsObject { ["reply"] = Js.Trim(content is null or Undefined ? "" : Js.String(content)), ["tools"] = used };
            }
            if (calls is not List<object?> list || !list.All(call => call is JsObject o && o.Get("function") is JsObject))
            {
                throw Unreadable(@base);
            }
            chat.Add(new JsObject { ["role"] = "assistant", ["content"] = content is Undefined ? null : content, ["tool_calls"] = list });
            foreach (object? call in list)
            {
                InTime(deadline, now, cancellationToken);
                object? function = Js.Get(call, "function");
                object? name = Js.Get(function, "name");
                used.Add(name is Undefined ? null : name);
                object? given = Js.Get(function, "arguments");
                if (!Js.ParseJson(Js.Truthy(given) ? Js.String(given) : "{}", out object? args))
                {
                    args = new JsObject();
                }
                var (text, _) = await ToolTextAsync(name, args, readApi).ConfigureAwait(false);
                chat.Add(new JsObject { ["role"] = "tool", ["tool_call_id"] = Js.Get(call, "id"), ["content"] = text });
            }
        }
        throw new AssistantError(TooManySteps, "assistant_steps");
    }

    /// <summary>data.choices?.[0]?.message ?? {}.</summary>
    private static object? FirstMessage(object? data)
    {
        object? choices = Js.Get(data, "choices");
        if (choices is null or Undefined)
        {
            return new JsObject();
        }
        object? first = Js.Get(choices, "0");
        if (first is null or Undefined)
        {
            return new JsObject();
        }
        object? message = Js.Get(first, "message");
        return message is null or Undefined ? new JsObject() : message;
    }

    /// <summary>
    /// The models a service offers with a key, from its own list: Anthropic's
    /// /models, or the /models of an OpenAI-compatible API. Newest or most
    /// relevant first where the service orders them; otherwise by name. Each is { id, name }.
    /// </summary>
    /// <exception cref="AssistantError">When the service cannot be asked or lists none.</exception>
    public static async Task<List<object?>> ListModelsAsync(JsObject settings, IFetcher fetcher, CancellationToken cancellationToken = default)
    {
        var provider = Provider(settings.Get("provider")) ?? throw new AssistantError("Choose a provider", "assistant_provider");
        string @base = BaseOf(settings, provider);
        if (@base.Length == 0)
        {
            throw new AssistantError("Enter the service's address first", "assistant_address");
        }
        string key = Setting(settings, "key");
        if (provider.Key == "yes" && key.Length == 0)
        {
            throw new AssistantError("Enter your " + provider.Name + " key first", "assistant_key", new JsObject { ["provider"] = provider.Name });
        }
        var headers = provider.Protocol == "anthropic"
            ? new Headers { ["x-api-key"] = key, ["anthropic-version"] = "2023-06-01" }
            : key.Length > 0 ? new Headers { ["authorization"] = "Bearer " + key } : new Headers();
        Response answer;
        byte[] bytes;
        try
        {
            answer = await fetcher.FetchAsync(@base + "/models" + (provider.Protocol == "anthropic" ? "?limit=100" : ""), new FetchInit { Headers = headers, TimeoutMs = 20_000 }, cancellationToken).ConfigureAwait(false);
            bytes = await answer.BytesAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (Exception)
        {
            string host = new Url(@base).Host;
            throw new AssistantError("Could not reach " + host, "unreachable", new JsObject { ["host"] = host });
        }
        object? data = Js.ParseJson(bytes, out object? parsed) ? parsed : null;
        if (!answer.Ok)
        {
            throw Refused(answer, data, @base);
        }
        object? list = data is null ? Undefined.Value : Js.Get(data, "data");
        if (list is null or Undefined)
        {
            list = new List<object?>();
        }
        if (list is not List<object?> items)
        {
            throw Unreadable(@base);
        }
        var models = new List<JsObject>();
        foreach (object? m in items)
        {
            if (m is not JsObject || Js.Get(m, "id") is not string id || id.Length == 0)
            {
                continue;
            }
            // Gemini lists ids as "models/gemini-...", which its OpenAI-compatible API takes without the prefix.
            id = id.StartsWith("models/", StringComparison.Ordinal) ? id["models/".Length..] : id;
            models.Add(new JsObject { ["id"] = id, ["name"] = Js.Get(m, "display_name") is string display ? display : id });
        }
        if (models.Count == 0)
        {
            string host = new Url(@base).Host;
            throw new AssistantError(host + " listed no models. Type the model's name instead.", "assistant_no_models", new JsObject { ["host"] = host });
        }
        // Anthropic lists newest first already; others come in no useful order (a stable sort, as JavaScript's is).
        IEnumerable<JsObject> ordered = provider.Protocol == "anthropic"
            ? models
            : models.OrderBy(m => (string)m.Get("id")!, Comparer<string>.Create(LocaleCompare));
        return [.. ordered];
    }

    /// <summary>a.localeCompare(b) with ICU's default collation, as Node has it.</summary>
    private static int LocaleCompare(string a, string b) => Math.Sign(Collation.Compare(a, b, CompareOptions.None));
}
