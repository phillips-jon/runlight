using System.Collections.Generic;
using System.Linq;
using Runlight.Http;
using Xunit;
using static Runlight.Tests.Fixtures;

namespace Runlight.Tests;

/// <summary>The pure modules against the fixtures written from the TypeScript SDK and conformance/.</summary>
public sealed class PureTests
{
    [Fact]
    public void Ua_conformance()
    {
        var failures = new List<string>();
        foreach (JsObject c in Conformance("ua").Arr("cases")!)
        {
            string ua = c.Str("ua")!;
            var agent = Ua.AiAgent(ua);
            if (c.Has("agent"))
            {
                var want = c.Obj("agent")!;
                if (agent?.Str("name") != want.Str("name") || agent?.Str("kind") != want.Str("kind"))
                {
                    failures.Add("agent " + ua);
                }
                continue;
            }
            if (agent != null)
            {
                failures.Add("not an agent " + ua);
            }
            if (c.Bool("bot") != Ua.IsBot(ua))
            {
                failures.Add("bot " + ua);
            }
            if (c.Has("client"))
            {
                var got = Ua.ParseClient(ua, c.Obj("hints"), c.Has("screenWidth") ? c.Num("screenWidth") : null);
                if (J(got) != J(c.Get("client")))
                {
                    failures.Add("client " + ua + " gave " + J(got));
                }
            }
        }
        NoFailures(failures);
    }

    [Fact]
    public void Ua_fixture()
    {
        var cases = Load("ua").Arr("cases")!;
        var failures = new List<string>();
        foreach (JsObject c in cases)
        {
            string ua = c.Str("ua")!;
            var got = new JsObject
            {
                ["agent"] = Ua.AiAgent(ua),
                ["bot"] = Ua.IsBot(ua),
                ["client"] = Ua.ParseClient(ua, c.Obj("hints"), c.Get("screenWidth") is double w ? w : null),
            };
            var want = new JsObject { ["agent"] = c.Get("agent"), ["bot"] = c.Get("bot"), ["client"] = c.Get("client") };
            if (J(got) != J(want))
            {
                failures.Add(Label(c) + " gave " + Label(got));
            }
        }
        Assert.True(cases.Count > 200);
        NoFailures(failures, 20);
    }

    [Fact]
    public void Ua_client_hints_mark_a_mobile_chromium_as_mobile()
    {
        string ua = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36";
        Assert.Equal("tablet", Ua.ParseClient(ua).Str("device"));
        Assert.Equal("tablet", Ua.ParseClient(ua, new JsObject { ["mobile"] = "?1" }).Str("device"));
        string desktop = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36";
        Assert.Equal("mobile", Ua.ParseClient(desktop, new JsObject { ["mobile"] = "?1" }).Str("device"));
    }

    [Fact]
    public void Url_conformance()
    {
        var fixture = Conformance("url");
        var failures = new List<string>();
        void Check(string input, string? baseUrl, object? expect)
        {
            var url = Url.Parse(input, baseUrl);
            if (expect == null)
            {
                if (url != null)
                {
                    failures.Add(input + " should not parse");
                }
                return;
            }
            if (url == null)
            {
                failures.Add(input + " should parse");
                return;
            }
            var got = new JsObject
            {
                ["href"] = url.Href,
                ["protocol"] = url.Protocol,
                ["username"] = url.Username,
                ["password"] = url.Password,
                ["hostname"] = url.Hostname,
                ["port"] = url.Port,
                ["host"] = url.Host,
                ["origin"] = url.Origin,
                ["pathname"] = url.Pathname,
                ["search"] = url.Search,
                ["hash"] = url.Hash,
            };
            if (J(got) != J(expect))
            {
                failures.Add(input + " gave " + J(got) + " not " + J(expect));
            }
        }
        foreach (JsObject c in fixture.Arr("urls")!)
        {
            Check(c.Str("input")!, null, c.Get("expect"));
        }
        foreach (JsObject c in fixture.Arr("relative")!)
        {
            Check(c.Str("input")!, c.Str("base"), c.Get("expect"));
        }
        foreach (JsObject c in fixture.Arr("queries")!)
        {
            var parameters = new SearchParams(c.Str("input")!);
            var pairs = parameters.Select(p => (object?)new List<object?> { p.Key, p.Value }).ToList();
            if (J(pairs) != J(c.Get("pairs")) || parameters.ToString() != c.Str("string"))
            {
                failures.Add("query " + c.Str("input"));
            }
        }
        foreach (JsObject c in fixture.Arr("written")!)
        {
            var parameters = new SearchParams();
            foreach (List<object?> pair in c.Arr("pairs")!)
            {
                parameters.Append((string)pair[0]!, (string)pair[1]!);
            }
            if (parameters.ToString() != c.Str("string"))
            {
                failures.Add("written " + J(c));
            }
        }
        foreach (JsObject c in fixture.Arr("numbers")!)
        {
            object? n = c.Get("n");
            double value = n is string s ? double.Parse(s, System.Globalization.CultureInfo.InvariantCulture) : Js.Num(n);
            if (Json.Number(value) != c.Str("text"))
            {
                failures.Add("number " + J(n) + " gave " + Json.Number(value));
            }
        }
        NoFailures(failures);
    }

    [Fact]
    public void Json_matches_javascript()
    {
        var o = new JsObject { ["a"] = new List<object?>(), ["b"] = new JsObject(), ["c"] = 1.0, ["d"] = 0.5, ["e"] = "/caf" + (char)0xE9 + " \U0001F600", ["f"] = double.NaN };
        Assert.Equal("{\"a\":[],\"b\":{},\"c\":1,\"d\":0.5,\"e\":\"/caf" + (char)0xE9 + " \U0001F600\",\"f\":null}", Json.Stringify(o));
        Assert.Equal("\"" + (char)0x2028 + "\\n\\" + "u0001\"", Json.Stringify((char)0x2028 + "\n" + (char)1));
    }

    [Fact]
    public void Query_fixture()
    {
        var fixture = Load("query");
        Assert.Equal(J(fixture.Get("eventDimensions")), J(Query.EventDimensions.ToDictionary(e => e.Key, e => (object?)e.Value).ToList()));
        Assert.Equal(J(fixture.Get("sessionDimensions")), J(Query.SessionDimensions.ToDictionary(e => e.Key, e => (object?)e.Value).ToList()));
        Assert.Equal(J(fixture.Get("dimensions")), J(Query.Dimensions));
        Assert.Equal(Query.MaxFilters, fixture.Num("maxFilters"));
        foreach (JsObject c in fixture.Arr("dimensionTests")!)
        {
            string v = c.Str("value")!;
            Assert.Equal(J(new object?[] { c.Get("isDimension"), c.Get("isSessionDimension"), c.Get("isEventDimension") }),
                J(new object?[] { Query.IsDimension(v), Query.IsSessionDimension(v), Query.IsEventDimension(v) }));
        }
        foreach (JsObject c in fixture.Arr("filters")!)
        {
            Assert.Equal(J(c.Get("filter")), J(Wf(Query.ParseFilter(c.Str("text")!))));
        }
    }

    [Fact]
    public void Payload_fixture()
    {
        var fixture = Load("payload");
        Assert.Equal(Payload.MaxBody, fixture.Num("maxBody"));
        var failures = new List<string>();
        foreach (JsObject c in fixture.Arr("cases")!)
        {
            var p = Payload.ParsePayload(c.Str("text")!);
            object? got = p == null ? null : new JsObject
            {
                ["kind"] = p.Kind,
                ["site"] = p.Site,
                ["url"] = p.Url.Href,
                ["referrer"] = p.Referrer,
                ["title"] = p.Title,
                ["screenWidth"] = p.ScreenWidth,
                ["screenHeight"] = p.ScreenHeight,
                ["language"] = p.Language,
                ["name"] = p.Name,
                ["props"] = p.Props == null ? null : Json.Stringify(p.Props),
                ["pageviewId"] = p.PageviewId,
                ["engagedMs"] = p.EngagedMs,
                ["scroll"] = p.Scroll,
            };
            if (J(got) != J(c.Get("payload")))
            {
                failures.Add(Label(c.Str("text")) + " gave " + J(got) + " not " + J(c.Get("payload")));
            }
        }
        NoFailures(failures);
        var indexed = Payload.ParsePayload("{\"k\":\"event\",\"u\":\"https://example.com/\",\"n\":\"x\",\"p\":{\"1\":\"b\",\"0\":\"a\"}}");
        Assert.Equal("{\"0\":\"a\",\"1\":\"b\"}", Json.Stringify(indexed!.Props));
    }
}
