using System;
using System.Collections.Generic;
using System.IO;
using Runlight.Http;
using Xunit;
using static Runlight.Tests.Fixtures;

namespace Runlight.Tests;

/// <summary>Location from platform headers and MMDB files, and where visits came from.</summary>
public sealed class GeoSourcesTests
{
    private static Headers HeadersOf(JsObject? o)
    {
        var h = new Headers();
        foreach (var (k, v) in o ?? new JsObject())
        {
            h.Append(k, (string)v!);
        }
        return h;
    }

    [Fact]
    public void Geo_headers()
    {
        foreach (JsObject c in Load("geo").Arr("headers")!)
        {
            Assert.Equal(J(c.Get("location")), J(Geo.LocationFromHeaders(HeadersOf(c.Obj("headers")))));
        }
    }

    [Fact]
    public void Geo_locate()
    {
        foreach (JsObject c in Load("geo").Arr("located")!)
        {
            Func<string, JsObject?>? lookup = c.Bool("noLookup") ? null : ip => c.Bool("throws") ? throw new InvalidOperationException("broken") : c.Obj("found");
            Assert.Equal(J(c.Get("location")), J(Geo.Locate(HeadersOf(c.Obj("headers")), c.Str("ip")!, lookup)));
        }
    }

    [Fact]
    public void Mmdb_in_memory_and_from_a_file()
    {
        foreach (JsObject db in Load("geo").Arr("databases")!)
        {
            byte[] bytes = Convert.FromBase64String(db.Str("base64")!);
            using var reader = new Mmdb(bytes);
            Assert.Equal(db.Num("ipVersion"), Js.Num(reader.Metadata.Get("ip_version")));
            Assert.Equal(db.Num("recordSize"), Js.Num(reader.Metadata.Get("record_size")));
            Assert.Equal(1759708800, Js.Num(reader.Metadata.Get("build_epoch")));
            Assert.Equal("{\"en\":\"A test database\"}", J(reader.Metadata.Get("description")));
            var lookup = Geo.LookupFrom(reader);
            string file = Path.GetTempFileName();
            File.WriteAllBytes(file, bytes);
            try
            {
                using var paged = Mmdb.Open(file);
                foreach (JsObject c in db.Arr("records")!)
                {
                    string ip = c.Str("ip")!;
                    Assert.Equal(J(c.Get("record")), J(reader.Get(ip)));
                    Assert.Equal(J(c.Get("record")), J(paged.Get(ip)));
                    Assert.Equal(J(c.Get("location")), J(lookup(ip)));
                }
            }
            finally
            {
                File.Delete(file);
            }
        }
        Assert.Throws<IOException>(() => Mmdb.Open(Path.Combine(Path.GetTempPath(), "no-such-runlight.mmdb")));
    }

    [Fact]
    public void Db_ip_records_become_a_country_code_a_readable_region_and_a_plain_city()
    {
        var records = new Dictionary<string, object?>
        {
            ["24.114.0.1"] = Json.Parse("{\"country\":{\"iso_code\":\"CA\"},\"subdivisions\":[{\"names\":{\"en\":\"Ontario\"}}],\"city\":{\"names\":{\"en\":\"Toronto (Old Toronto)\"}}}"),
            ["8.8.8.8"] = Json.Parse("{\"country\":{\"iso_code\":\"US\"},\"subdivisions\":[{\"iso_code\":\"CA\",\"names\":{\"en\":\"California\"}}],\"city\":{\"names\":{\"en\":\"Mountain View\"}}}"),
        };
        var lookup = Geo.LookupFrom(ip => records.GetValueOrDefault(ip));
        Assert.Equal("{\"country\":\"CA\",\"region\":\"Ontario\",\"city\":\"Toronto\"}", J(lookup("24.114.0.1")));
        Assert.Equal("{\"country\":\"US\",\"region\":\"CA\",\"city\":\"Mountain View\"}", J(lookup("8.8.8.8")));
        Assert.Null(lookup("10.0.0.1"));
        var broken = Geo.LookupFrom(ip => throw new InvalidOperationException("bad address"));
        Assert.Null(broken("nonsense"));
    }

    private static JsObject Visit(string url, string referrer = "", string[]? internalHosts = null) =>
        Sources.Attribute(Sources.ParsePage(new Url(url)), referrer, internalHosts ?? []);

    [Fact]
    public void Sources_by_hand()
    {
        Assert.Equal("{\"referrerHost\":\"\",\"referrerPath\":\"\",\"source\":\"\",\"channel\":\"Direct\"}", J(Visit("https://example.com/")));
        Assert.Equal("Organic Search", Visit("https://example.com/", "https://www.google.co.uk/").Str("channel"));
        Assert.Equal("Gmail", Sources.SourceForHost("mail.google.com")!.Str("name"));
        Assert.Equal("Paid Search", Visit("https://example.com/?gclid=abc", "https://www.google.com/").Str("channel"));
        Assert.Equal("AI", Visit("https://example.com/post?utm_source=chatgpt.com").Str("channel"));
        Assert.Equal("Kit", Visit("https://example.com/", "https://15a992bb.click.convertkit-mail4.com/x").Str("source"));
        Assert.Equal("Email", Visit("https://example.com/", "https://mail.aol.com/").Str("channel"));
        Assert.Equal("Referral", Visit("https://example.com/", "https://mailbox.org/").Str("channel"));
        Assert.Equal("Gmail", Visit("https://example.com/", "android-app://com.google.android.gm/").Str("source"));
        Assert.Equal("", Visit("https://example.com/b", "https://shop.example.com/a", ["shop.example.com"]).Str("referrerHost"));
        var page = Sources.ParsePage(new Url("https://www.example.com/a/b?email=x@y.z&utm_campaign=spring&fbclid=123#top"));
        Assert.Equal("/a/b#top", page.Str("path"));
        Assert.True(page.Bool("paid"));
        Assert.DoesNotContain("x@y.z", J(page), StringComparison.Ordinal);
    }

    [Fact]
    public void Sources_fixture()
    {
        var fixture = Load("sources");
        var failures = new List<string>();
        foreach (JsObject c in fixture.Arr("hosts")!)
        {
            if (J(c.Get("source")) != J(Sources.SourceForHost(c.Str("host")!)))
            {
                failures.Add("host " + c.Str("host"));
            }
        }
        foreach (JsObject c in fixture.Arr("aliases")!)
        {
            if (J(c.Get("source")) != J(Sources.SourceForAlias(c.Str("alias")!)))
            {
                failures.Add("alias " + c.Str("alias"));
            }
        }
        foreach (JsObject c in fixture.Arr("stripWww")!)
        {
            if (c.Str("host") != Sources.StripWww(c.Str("input")!))
            {
                failures.Add("stripWww " + c.Str("input"));
            }
        }
        foreach (JsObject c in fixture.Arr("pages")!)
        {
            var url = Url.Parse(c.Str("url")!);
            if (J(c.Get("page")) != J(Wf(url == null ? null : Sources.ParsePage(url))))
            {
                failures.Add("page " + c.Str("url") + " gave " + J(url == null ? null : Sources.ParsePage(url)));
            }
        }
        var visits = fixture.Arr("visits")!;
        foreach (JsObject c in visits)
        {
            var hosts = new List<string>();
            foreach (var h in c.Arr("internal")!)
            {
                hosts.Add((string)h!);
            }
            var got = Sources.Attribute(Sources.ParsePage(new Url(c.Str("url")!)), c.Str("referrer")!, hosts);
            if (J(Wf(got)) != J(c.Get("attribution")))
            {
                failures.Add("visit " + Label(c) + " gave " + J(got));
            }
        }
        Assert.True(visits.Count > 300);
        foreach (JsObject c in fixture.Arr("recordedPaths")!)
        {
            if (J(c.Get("path")) != J(Sources.RecordedPath(c.Str("input")!)))
            {
                failures.Add("recorded " + c.Str("input") + " gave " + Sources.RecordedPath(c.Str("input")!));
            }
        }
        foreach (JsObject c in fixture.Arr("readablePaths")!)
        {
            string readable = Sources.ReadablePath(c.Str("input")!);
            if (readable != c.Str("path"))
            {
                failures.Add("readable " + c.Str("input") + " gave " + readable + " not " + c.Str("path"));
            }
        }
        NoFailures(failures);
    }
}
