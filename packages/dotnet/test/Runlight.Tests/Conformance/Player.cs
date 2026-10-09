using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Runlight.Accounts;
using Runlight.Http;

namespace Runlight.Tests.ConformanceRunner;

/// <summary>
/// What a target is made from: the options new Runlight(...) gets (as JSON, without the store, the clock,
/// and the fetcher), the options rl.Routes(...) gets, and the store, clock, and fetcher themselves.
/// </summary>
public sealed record PlayOptions(JsObject Runlight, JsObject Routes, object? Store, Func<long> Now, UpstreamFetcher Fetcher);

/// <summary>
/// Plays a scenario from conformance/http.json exactly as play() in packages/sdk/test/http-conformance.ts
/// does (ported from the PHP's tests/Conformance/Player.php), and returns each step's answer, normalized,
/// in the shape of the file's <c>expect</c>: objects with status, headers, body, text, files, found,
/// fetched, or pass.
///
/// The scenario's options become the options the port conventions name, and a target (the core, or a fake)
/// takes the requests. Keep this file in step with the TypeScript runner: <see cref="FormatSha256"/> fails a
/// test when the file's description of the format changes.
/// </summary>
public sealed class Player
{
    /// <summary>The SHA-256 of http.json's description this runner was written against.</summary>
    public const string FormatSha256 = "87a6f2d7f8acd8026aa4c9ede697d21457a0b9c1a2bfc01488aa2d9598def68f";

    /// <summary>Environment the SDK reads defaults from, cleared while a scenario plays so nothing outside it counts.</summary>
    public static readonly string[] Env = ["RUNLIGHT_TOKEN", "RUNLIGHT_SECRET", "CRON_SECRET", "RUNLIGHT_OBSERVE_KEY", "NODE_ENV"];

    /// <summary>The content type JavaScript's Request gives a string body sent with none, which the TypeScript answers were made with.</summary>
    public const string TextBodyType = "text/plain;charset=UTF-8";

    // JavaScript's \s, as raw characters for a class.
    private static readonly string JsSpaceChars = new(
    [
        (char)0x09, (char)0x0A, (char)0x0B, (char)0x0C, (char)0x0D, ' ', (char)0xA0, (char)0x1680,
        (char)0x2000, '-', (char)0x200A, (char)0x2028, (char)0x2029, (char)0x202F, (char)0x205F, (char)0x3000, (char)0xFEFF,
    ]);

    private const RegexOptions Options = RegexOptions.CultureInvariant;
    private static readonly Regex TotpTemplate = new("\\{\\{totp:([A-Za-z0-9_]+)\\}\\}", Options);
    private static readonly Regex Template = new("\\{\\{([A-Za-z0-9_]+)\\}\\}", Options);
    private static readonly Regex ClearsCookie = new("^[" + JsSpaceChars + "]*max-age=0[" + JsSpaceChars + "]*\\z", Options | RegexOptions.IgnoreCase);


    /// <summary>The clock, in epoch milliseconds, as the scenario's steps move it.</summary>
    private long _now;

    /// <summary>Runs a scenario's steps and returns each answer, normalized.</summary>
    public async Task<List<JsObject>> PlayAsync(JsObject scenario, Func<PlayOptions, ITarget> target, object? store = null)
    {
        var saved = ClearEnv();
        try
        {
            var upstream = (scenario.Arr("upstream") ?? []).Cast<JsObject>().ToList();
            return await StepsAsync(scenario, target, store, new UpstreamFetcher(upstream));
        }
        finally
        {
            RestoreEnv(saved);
        }
    }

    /// <summary>The options new Runlight(...) gets, without the store, the clock, and the fetcher.</summary>
    public static JsObject RunlightOptions(JsObject scenario)
    {
        var options = scenario.Obj("options") ?? new JsObject();
        var output = new JsObject();
        if (Js.Truthy(options.Get("managedSites")))
        {
            output["managedSites"] = true;
        }
        else if (scenario.Get("sites") != null)
        {
            output["sites"] = Plain(scenario.Get("sites"));
        }
        else
        {
            output["site"] = Plain(scenario.Get("site"));
        }
        if (options.Get("secret") is string secret && secret.Length > 0)
        {
            output["secret"] = secret;
        }
        if (options.Has("rateLimit"))
        {
            output["rateLimit"] = options.Get("rateLimit");
        }
        return output;
    }

    /// <summary>
    /// The options rl.Routes(...) gets. The token is always there: a string, "" for none, or null to leave
    /// the routes open, never left out, which would read RUNLIGHT_TOKEN.
    /// </summary>
    public static JsObject RoutesOptions(JsObject scenario)
    {
        var options = scenario.Obj("options") ?? new JsObject();
        var output = new JsObject
        {
            ["token"] = scenario.Get("token"),
            ["observeKey"] = options.Get("observeKey") ?? "",
            ["cronSecret"] = options.Get("cronSecret") ?? "",
        };
        if (Js.Truthy(options.Get("accounts")))
        {
            output["accounts"] = true;
        }
        if (Js.Truthy(options.Get("origin")))
        {
            output["origin"] = options.Get("origin");
        }
        return output;
    }

    private async Task<List<JsObject>> StepsAsync(JsObject scenario, Func<PlayOptions, ITarget> makeTarget, object? store, UpstreamFetcher fetcher)
    {
        _now = (long)scenario.Num("start");
        var target = makeTarget(new PlayOptions(RunlightOptions(scenario), RoutesOptions(scenario), store, () => _now, fetcher));
        var kept = new Dictionary<string, string>(StringComparer.Ordinal);
        var jars = new Dictionary<string, OrderedDictionary<string, string>>(StringComparer.Ordinal);
        var answers = new List<JsObject>();
        var steps = scenario.Arr("steps")!.Cast<JsObject>().ToList();
        for (int i = 0; i < steps.Count; i++)
        {
            var step = steps[i];
            try
            {
                answers.Add(await StepAsync(step, target, fetcher, kept, jars));
            }
            catch (Exception error)
            {
                throw new InvalidOperationException(
                    string.Create(CultureInfo.InvariantCulture, $"{scenario.Str("name")}: step {i + 1}, {step.Str("method")} {step.Str("path")}: {error.Message}"),
                    error);
            }
        }
        return answers;
    }

    private async Task<JsObject> StepAsync(JsObject step, ITarget target, UpstreamFetcher fetcher, Dictionary<string, string> kept, Dictionary<string, OrderedDictionary<string, string>> jars)
    {
        _now += step.Has("advance") ? (long)step.Num("advance") : 0;
        var headers = new OrderedDictionary<string, string>(StringComparer.Ordinal);
        foreach (var (k, v) in step.Obj("headers") ?? new JsObject())
        {
            headers[k.ToLowerInvariant()] = FillTotp(Js.String(v), kept);
        }
        string? body = null;
        if (step.Get("form") is JsObject form)
        {
            var fields = new List<KeyValuePair<string, string>>();
            foreach (var (name, value) in (JsObject)FillDeep(form, kept)!)
            {
                fields.Add(new(name, Js.String(value)));
            }
            body = new SearchParams(fields).ToString();
            headers.TryAdd("content-type", "application/x-www-form-urlencoded");
        }
        else if (step.Has("body"))
        {
            object? given = step.Get("body");
            body = given is string s ? FillTotp(s, kept) : Json.Stringify(FillDeep(given, kept));
        }
        // JavaScript's Request gives a string body this type when none is named, and the core may read it.
        if (body != null)
        {
            headers.TryAdd("content-type", TextBodyType);
        }
        OrderedDictionary<string, string>? jar = null;
        object? jarName = step.Prop("jar");
        if (jarName is not false)
        {
            string name = jarName is Undefined || jarName == null ? "main" : Js.String(jarName);
            if (!jars.TryGetValue(name, out jar))
            {
                jar = new OrderedDictionary<string, string>(StringComparer.Ordinal);
                jars[name] = jar;
            }
        }
        if (jar != null && jar.Count > 0 && !headers.ContainsKey("cookie"))
        {
            headers["cookie"] = string.Join("; ", jar.Select(e => e.Key + "=" + e.Value));
        }
        string to = step.Str("to") ?? "routes";
        string prefix = to == "routes" && !Js.Truthy(step.Get("absolute")) ? "/runlight" : "";
        string raw = "https://" + (step.Str("host") ?? "example.com") + prefix + FillTotp(Js.String(step.Get("path")), kept);
        // request.url is the parsed URL, as `new Request(url)` gives it.
        string url = Url.Parse(raw)?.Href ?? raw;
        var request = new Request(url, step.Str("method")!, new Headers(headers), body ?? "");
        fetcher.Take();
        Response? answer = to switch
        {
            "links" => await target.LinksAsync(request),
            "linkDomain" => await target.LinkDomainAsync(request),
            _ => await target.HandleAsync(request),
        };
        // Work the request started after answering (retention) finishes before the next one, as it would between real requests.
        await target.IdleAsync();
        var sentOut = fetcher.Take();
        var outbound = sentOut.Select(f => Normalizer.Normalize(f.Seen)).ToList();
        if (answer == null)
        {
            var passed = new JsObject { ["pass"] = true };
            if (outbound.Count > 0)
            {
                passed["fetched"] = outbound;
            }
            return passed;
        }
        return await AnswerAsync(step, answer, sentOut, outbound, kept, jar);
    }

    private static async Task<JsObject> AnswerAsync(JsObject step, Response answer, List<Fetched> sentOut, List<object?> outbound, Dictionary<string, string> kept, OrderedDictionary<string, string>? jar)
    {
        byte[] bytes = await answer.BytesAsync();
        string text = Body.Utf8(bytes);
        string type = (answer.Headers.Get("content-type") ?? "").Split(';')[0].Trim();
        object? parsed = null;
        bool hasParsed = false;
        if (type != "application/zip" && text.Length > 0)
        {
            hasParsed = Json.TryParse(text, out parsed);
        }
        foreach (var (name, spec) in step.Obj("capture") ?? new JsObject())
        {
            kept[name] = Capture(Js.String(spec), answer, text, hasParsed ? parsed : null, sentOut);
        }
        foreach (string cookie in answer.Headers.GetSetCookie())
        {
            if (jar == null)
            {
                continue;
            }
            string[] attributes = cookie.Split(';');
            string pair = attributes[0];
            int at = pair.IndexOf('=', StringComparison.Ordinal);
            // As pair.slice(0, pair.indexOf("=")): with no "=", indexOf is -1, and the last character is cut.
            string name = Js.Trim(at < 0 ? pair[..Math.Max(0, pair.Length - 1)] : pair[..at]);
            string value = Js.Trim(at < 0 ? pair : pair[(at + 1)..]);
            bool clears = attributes.Skip(1).Any(a => ClearsCookie.IsMatch(a));
            if (value.Length == 0 || clears)
            {
                jar.Remove(name);
            }
            else
            {
                jar[name] = value;
            }
        }
        var sent = new JsObject();
        foreach (string name in Normalizer.Headers)
        {
            if (name == "set-cookie")
            {
                var cookies = answer.Headers.GetSetCookie();
                if (cookies.Count > 0)
                {
                    sent[name] = cookies.Select(c => (object?)Normalizer.CookieShape(c)).ToList();
                }
                continue;
            }
            string? value = answer.Headers.Get(name);
            if (!string.IsNullOrEmpty(value))
            {
                sent[name] = name == "content-type" ? value.Split(';')[0].Trim() : Normalizer.Normalize(value);
            }
        }
        var output = new JsObject { ["status"] = (long)answer.Status };
        if (!sent.IsEmpty)
        {
            output["headers"] = sent;
        }
        if (hasParsed)
        {
            output["body"] = Normalizer.Normalize(parsed);
        }
        if (!hasParsed && (type == "text/plain" || type == "text/csv"))
        {
            output["text"] = Normalizer.Normalize(text);
        }
        if (type == "application/zip")
        {
            output["files"] = TestZip.Unzip(bytes).Select(f => (object?)new JsObject { ["name"] = f.Name, ["text"] = Normalizer.Normalize(f.Text) }).ToList();
        }
        if (step.Arr("look") is List<object?> look)
        {
            output["found"] = look.Select(s => (object?)text.Contains(Js.String(s), StringComparison.Ordinal)).ToList();
        }
        if (outbound.Count > 0)
        {
            output["fetched"] = outbound;
        }
        return output;
    }

    /// <summary>
    /// A value kept from an answer: a dotted path into its JSON body, header:&lt;name&gt;, text, or fetched,
    /// any of them followed by ~&lt;regex&gt; to keep the regex's first group instead. Read before normalizing.
    /// </summary>
    public static string Capture(string spec, Response answer, string text, object? parsed, List<Fetched> sentOut)
    {
        int cut = spec.IndexOf('~', StringComparison.Ordinal);
        string source = cut < 0 ? spec : spec[..cut];
        string? pattern = cut < 0 ? null : spec[(cut + 1)..];
        string value;
        if (source == "text")
        {
            value = text;
        }
        else if (source == "fetched")
        {
            value = string.Join("\n", sentOut.Select(f => f.Text));
        }
        else if (source.StartsWith("header:", StringComparison.Ordinal))
        {
            string header = source["header:".Length..].ToLowerInvariant();
            value = header == "set-cookie" ? string.Join("\n", answer.Headers.GetSetCookie()) : answer.Headers.Get(header) ?? "";
        }
        else
        {
            value = JsString(Dig(parsed, source));
        }
        return pattern == null ? value : FirstGroup(pattern, value);
    }

    /// <summary><c>new RegExp(pattern).exec(value)?.[1] ?? ""</c>.</summary>
    public static string FirstGroup(string pattern, string value)
    {
        var m = new Regex(pattern, Options).Match(value);
        return m.Success && m.Groups.Count > 1 && m.Groups[1].Success ? m.Groups[1].Value : "";
    }

    /// <summary><c>path.split(".").reduce((v, k) => (v &amp;&amp; typeof v === "object" ? v[k] : undefined), value)</c>.</summary>
    public static object? Dig(object? value, string path)
    {
        foreach (string k in path.Split('.'))
        {
            if (value is JsObject obj)
            {
                value = obj.Has(k) ? obj.Get(k) : null;
            }
            else if (value is List<object?> list)
            {
                bool index = k.Length > 0 && k.All(char.IsAsciiDigit) && (k == "0" || k[0] != '0') && k.Length < 10;
                value = index && int.Parse(k, CultureInfo.InvariantCulture) is int n && n < list.Count ? list[n] : null;
            }
            else
            {
                return null;
            }
        }
        return value;
    }

    /// <summary><c>String(value ?? "")</c>, as JavaScript writes a JSON value as text.</summary>
    public static string JsString(object? value) => value switch
    {
        null or Undefined => "",
        string s => s,
        bool b => b ? "true" : "false",
        double d => Json.Number(d),
        long l => l.ToString(CultureInfo.InvariantCulture),
        List<object?> list => string.Join(",", list.Select(JsString)),
        _ => "[object Object]",
    };

    /// <summary>{{totp:name}} as the six-digit code for the captured secret at the step's clock, then {{name}}.</summary>
    private string FillTotp(string text, Dictionary<string, string> kept)
    {
        string output = text;
        foreach (Match m in TotpTemplate.Matches(text))
        {
            int at = output.IndexOf(m.Value, StringComparison.Ordinal);
            if (at >= 0)
            {
                string code = Crypto.Totp(kept.GetValueOrDefault(m.Groups[1].Value, ""), _now / 30_000);
                output = output[..at] + code + output[(at + m.Value.Length)..];
            }
        }
        return Fill(output, kept);
    }

    /// <summary>{{name}} as the value captured earlier, empty when nothing was.</summary>
    private static string Fill(string text, Dictionary<string, string> kept) =>
        Template.Replace(text, m => kept.GetValueOrDefault(m.Groups[1].Value, ""));

    private object? FillDeep(object? value, Dictionary<string, string> kept) => value switch
    {
        string s => FillTotp(s, kept),
        List<object?> list => list.Select(v => FillDeep(v, kept)).ToList(),
        JsObject obj => JsObject.From(obj.Select(e => new KeyValuePair<string, object?>(e.Key, FillDeep(e.Value, kept)))),
        _ => value,
    };

    /// <summary>A JSON value copied, the shape options take.</summary>
    private static object? Plain(object? value) => Json.Parse(Json.Stringify(value));

    /// <summary>Clears <see cref="Env"/> and hands back what was there, for <see cref="RestoreEnv"/>.</summary>
    public static Dictionary<string, string?> ClearEnv()
    {
        var saved = new Dictionary<string, string?>(StringComparer.Ordinal);
        foreach (string name in Env)
        {
            saved[name] = Environment.GetEnvironmentVariable(name);
            Environment.SetEnvironmentVariable(name, null);
        }
        return saved;
    }

    public static void RestoreEnv(Dictionary<string, string?> saved)
    {
        foreach (var (name, value) in saved)
        {
            Environment.SetEnvironmentVariable(name, value);
        }
    }
}
