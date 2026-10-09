using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Runlight.Http;
using Xunit;
using static Runlight.Tests.Fixtures;

namespace Runlight.Tests.Routes;

/// <summary>
/// Replays packages/php/tests/fixtures/routes.json, which scripts/php-fixtures-routes.mts writes from the TypeScript
/// SDK: the dashboard's page, the tracker, refusals with their codes, and OAuth's documents, each answer byte for
/// byte with every header, and the helpers routes.ts and oauth.ts export.
/// </summary>
public sealed class RoutesFixtureTests : RoutesTestCase
{
    public static TheoryData<int> Exchanges()
    {
        var data = new TheoryData<int>();
        for (int i = 0; i < Load("routes").Arr("exchanges")!.Count; i++)
        {
            data.Add(i);
        }
        return data;
    }

    /// <summary>A site as the fixture writes it.</summary>
    private static SiteOptions SiteOf(object? value)
    {
        var o = (JsObject)value!;
        return new SiteOptions { Id = o.Str("id"), Name = o.Str("name"), Hostnames = o.Arr("hostnames")?.Cast<string>().ToList(), Timezone = o.Str("timezone") };
    }

    /// <summary>Routes options as the fixture writes them, with the TypeScript names.</summary>
    private static RoutesOptions RoutesOf(JsObject o)
    {
        var options = new RoutesOptions
        {
            BasePath = o.Str("basePath"),
            SignOut = o.Str("signOut"),
            SignIn = o.Str("signIn"),
            GeoCredit = o.Get("geoCredit") is true,
            Origin = o.Str("origin"),
            CronSecret = o.Str("cronSecret"),
            ObserveKey = o.Str("observeKey"),
            Accounts = o.Get("accounts") is true,
        };
        return o.Has("token") ? new RoutesOptions
        {
            Token = o.Str("token"),
            BasePath = options.BasePath,
            SignOut = options.SignOut,
            SignIn = options.SignIn,
            GeoCredit = options.GeoCredit,
            Origin = options.Origin,
            CronSecret = options.CronSecret,
            ObserveKey = options.ObserveKey,
            Accounts = options.Accounts,
        } : options;
    }

    [Theory]
    [MemberData(nameof(Exchanges))]
    public async Task Answers_as_the_typescript_does(int index)
    {
        var fixture = Load("routes");
        var exchange = (JsObject)fixture.Arr("exchanges")![index]!;
        long now = fixture.Long("now");
        var runlight = exchange.Obj("runlight")!;
        var rl = await Make.RunlightAsync(
            site: runlight.Has("site") ? SiteOf(runlight.Get("site")) : null,
            sites: runlight.Arr("sites")?.Select(SiteOf).ToList(),
            now: () => now);
        var routes = rl.Routes(RoutesOf(exchange.Obj("routes")!));
        foreach (var item in exchange.Arr("answers")!)
        {
            var answer = (JsObject)item!;
            var ask = answer.Obj("ask")!;
            string method = ask.Str("method") ?? "GET";
            string label = exchange.Str("name") + ": " + method + " " + ask.Str("path");
            var headers = new Headers();
            foreach (var (name, value) in ask.Obj("headers") ?? [])
            {
                headers.Set(name, (string)value!);
            }
            var response = await routes.HandleAsync(Make.At("https://example.com" + ask.Str("path"), method, headers, ask.Str("body")));
            Assert.True(answer.Long("status") == response.Status, label + ": status " + response.Status + " " + await response.TextAsync());
            var got = new JsObject();
            foreach (var (name, values) in response.Headers.All().OrderBy(e => e.Key, StringComparer.Ordinal))
            {
                got[name] = name == "set-cookie" ? values.Select(v => (object?)v).ToList() : string.Join(", ", values);
            }
            var want = JsObject.From(answer.Obj("headers")!.OrderBy(e => e.Key, StringComparer.Ordinal));
            Assert.True(J(want) == J(got), label + ": headers\n" + J(want) + "\n" + J(got));
            byte[] body = await response.BytesAsync();
            if (answer.Has("sha256"))
            {
                Assert.True(answer.Str("sha256") == Hash.Sha256(body), label + ": body");
            }
            else
            {
                Assert.True(answer.Str("text") == Js.Decode(body), label + ": body\n" + answer.Str("text") + "\n" + Js.Decode(body));
            }
        }
    }

    [Fact]
    public void Coded_errors_are_the_same_bytes()
    {
        foreach (var item in Load("routes").Arr("coded")!)
        {
            var c = (JsObject)item!;
            var args = c.Arr("args")!;
            var headers = new Headers();
            foreach (var (name, value) in (JsObject)args[4]!)
            {
                headers.Set(name, (string)value!);
            }
            var response = global::Runlight.Routes.Coded((string)args[0]!, (string)args[1]!, (int)Js.Num(args[2]), args[3] as JsObject, headers);
            Assert.Equal(c.Long("status"), response.Status);
            Assert.Equal(c.Str("text"), response.Text());
            var got = JsObject.From(response.Headers.All().OrderBy(e => e.Key, StringComparer.Ordinal).Select(e => new KeyValuePair<string, object?>(e.Key, string.Join(", ", e.Value))));
            Assert.Equal(J(JsObject.From(c.Obj("headers")!.OrderBy(e => e.Key, StringComparer.Ordinal))), J(got));
        }
    }

    [Fact]
    public void Host_names_are_bare_as_the_typescript_makes_them()
    {
        foreach (var item in Load("routes").Arr("hostName")!)
        {
            var pair = (List<object?>)item!;
            Assert.Equal((string)pair[1]!, global::Runlight.Routes.HostName((string)pair[0]!));
        }
    }

    [Fact]
    public void Manage_paths_are_the_same()
    {
        foreach (var item in Load("routes").Arr("managePath")!)
        {
            var c = (List<object?>)item!;
            Assert.True((bool)c[2]! == global::Runlight.Routes.ManagePath((string)c[0]!, (string)c[1]!), c[0] + " " + c[1]);
        }
    }

    [Fact]
    public void Pkce_s256_matches_the_typescript()
    {
        foreach (var item in Load("routes").Arr("s256")!)
        {
            var pair = (List<object?>)item!;
            Assert.Equal((string)pair[1]!, OAuth.S256((string)pair[0]!));
        }
        // RFC 7636's own example.
        Assert.Equal("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", OAuth.S256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"));
    }

    [Fact]
    public void Resource_metadata_url()
    {
        foreach (var item in Load("routes").Arr("resourceMetadataUrl")!)
        {
            var c = (List<object?>)item!;
            Assert.Equal((string)c[2]!, OAuth.ResourceMetadataUrl((string)c[0]!, (string)c[1]!));
        }
    }
}
