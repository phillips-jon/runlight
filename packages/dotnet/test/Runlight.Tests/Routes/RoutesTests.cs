using System;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Runlight.Http;
using Xunit;
using static Runlight.Tests.Routes.Make;

namespace Runlight.Tests.Routes;

/// <summary>
/// routes.test.ts, ported as the PHP's tests/Routes/RoutesTest.php ports it, then the unit checks of the routes'
/// own helpers: cookies, bearer tokens, JSON-only writes, and the dashboard's page.
/// </summary>
public sealed class RoutesTests : RoutesTestCase
{
    [Fact]
    public async Task The_tracker_is_public_cached_and_answers_304_to_its_etag()
    {
        var routes = (await RunlightAsync()).Routes(new RoutesOptions { Token = "secret" });
        var first = await routes.HandleAsync(Req("/runlight/s.js"));
        Assert.Equal(200, first.Status);
        Assert.Matches("javascript", first.Headers.Get("content-type") ?? "");
        Assert.Matches("sendBeacon", first.Text());
        string etag = first.Headers.Get("etag") ?? "";
        Assert.StartsWith("\"" + Assets.Build.Str("trackerHash") + "-", etag, StringComparison.Ordinal); // the etag covers the script and its click rules
        var again = await routes.HandleAsync(Req("/runlight/s.js", "GET", H(("if-none-match", etag))));
        Assert.Equal(304, again.Status);
    }

    [Fact]
    public async Task Stats_need_the_token_as_a_bearer_or_through_the_cookie()
    {
        var routes = (await RunlightAsync()).Routes(new RoutesOptions { Token = "secret" });
        Assert.Equal(401, (await routes.HandleAsync(Req("/runlight/api/stats"))).Status);
        Assert.Equal(401, (await routes.HandleAsync(Req("/runlight/api/stats", "GET", H(("authorization", "Bearer wrong"))))).Status);
        Assert.Equal(200, (await routes.HandleAsync(Req("/runlight/api/stats", "GET", H(("authorization", "Bearer secret"))))).Status);

        var signIn = await routes.HandleAsync(Req("/runlight/?token=secret"));
        Assert.Equal(303, signIn.Status);
        Assert.Equal("/runlight/", signIn.Headers.Get("location"));
        string cookie = signIn.Headers.Get("set-cookie") ?? "";
        Assert.Contains("HttpOnly", cookie, StringComparison.Ordinal);
        Assert.Contains("Secure", cookie, StringComparison.Ordinal);
        Assert.DoesNotContain("secret", cookie, StringComparison.Ordinal); // the cookie holds a digest, not the token
        string value = cookie.Split(';')[0];
        Assert.Equal(200, (await routes.HandleAsync(Req("/runlight/api/stats", "GET", H(("cookie", value))))).Status);
        Assert.Equal(200, (await routes.HandleAsync(Req("/runlight/", "GET", H(("cookie", value))))).Status);
    }

    [Fact]
    public async Task With_no_token_everything_but_development_refuses_writes_included()
    {
        foreach (string? value in new[] { "production", null, "staging" })
        {
            Environment.SetEnvironmentVariable("NODE_ENV", value);
            var routes = (await RunlightAsync()).Routes(new RoutesOptions());
            Assert.Equal(503, (await routes.HandleAsync(Req("/runlight/api/stats"))).Status);
            var minted = await routes.HandleAsync(Req("/runlight/api/tokens", "POST", H(("content-type", "application/json")), Json.Stringify(new JsObject { ["name"] = "x" })));
            Assert.Equal(503, minted.Status); // nobody can make a token on an install with no token
        }
        Environment.SetEnvironmentVariable("NODE_ENV", "development");
        Assert.Equal(200, (await (await RunlightAsync()).Routes(new RoutesOptions()).HandleAsync(Req("/runlight/api/stats"))).Status);
    }

    [Fact]
    public async Task Authorize_replaces_the_token()
    {
        var routes = (await RunlightAsync()).Routes(new RoutesOptions { Authorize = (r, _) => Task.FromResult<object>(r.Headers.Get("x-admin") == "yes") });
        Assert.Equal(401, (await routes.HandleAsync(Req("/runlight/api/sites"))).Status);
        Assert.Equal(200, (await routes.HandleAsync(Req("/runlight/api/sites", "GET", H(("x-admin", "yes"))))).Status);
    }

    [Fact]
    public async Task The_element_picker_sends_its_choice_only_to_the_dashboard_its_ticket_names()
    {
        long now = Utc(2026, 10, 7, 12);
        var rl = await RunlightAsync(sites: [Site("blog", hostnames: ["blog.example.com"])], now: () => now);
        var routes = rl.Routes(new RoutesOptions { Token = "secret" });
        Task<Response> Ask(object body, string auth = "secret") => routes.HandleAsync(Owner("/runlight/api/pick?site=blog", "POST", body, auth));
        async Task<string?> Target(string ticket)
        {
            string script = (await routes.HandleAsync(Req("/runlight/pick.js?runlight=pick&runlight_ticket=" + Uri.EscapeDataString(ticket)))).Text();
            var m = Regex.Match(script, "var \\w+=\"([^\"]*)\";if\\(");
            return m.Success ? m.Groups[1].Value : null;
        }

        Assert.Equal(401, (await Ask(new JsObject { ["origin"] = "https://stats.example.com" }, "wrong")).Status); // only the owner gets a ticket
        Assert.Equal(400, (await Ask(new JsObject { ["origin"] = "javascript:alert(1)" })).Status);
        string ticket = Obj(await Ask(new JsObject { ["origin"] = "https://stats.example.com" })).Str("ticket")!;
        Assert.Equal("https://stats.example.com", await Target(ticket));
        // A page that opens the site some other way has no ticket, or only a changed one, and the picker sends nowhere.
        Assert.Equal("", await Target(""));
        string evil = Convert.ToHexStringLower(System.Text.Encoding.UTF8.GetBytes("https://evil.example"));
        Assert.Equal("", await Target(new Regex("\\.[a-f0-9]+\\.").Replace(ticket, "." + evil + ".", 1)));
        Assert.Equal("no-store", (await routes.HandleAsync(Req("/runlight/pick.js"))).Headers.Get("cache-control"));
        now += 31 * 60_000;
        Assert.Equal("", await Target(ticket)); // a ticket runs out after half an hour

        // The script also learns the site the ticket is for, and does nothing on any other site's pages.
        string fresh = Obj(await Ask(new JsObject { ["origin"] = "https://stats.example.com" })).Str("ticket")!;
        string script = (await routes.HandleAsync(Req("/runlight/pick.js?runlight_ticket=" + Uri.EscapeDataString(fresh)))).Text();
        Assert.Contains(Json.Stringify(Json.Stringify(L("blog.example.com"))), script, StringComparison.Ordinal);
        Assert.DoesNotContain("__RUNLIGHT_PICK_HOSTS__", script, StringComparison.Ordinal);

        // A hub's manage token gets one only for the hub it connected from, recorded when it did.
        var made = Obj(await routes.HandleAsync(Owner("/runlight/api/tokens", "POST", new JsObject { ["name"] = "Hub", ["scope"] = "manage", ["site"] = "blog" })));
        string manage = made.Str("secret")!;
        var refused = await Ask(new JsObject { ["origin"] = "https://hub.example.net" }, manage);
        Assert.Equal(403, refused.Status);
        Assert.Equal("pick_hub", Obj(refused).Str("code"));
        await rl.Store.SetSettingAsync("token-origin:" + made.Obj("token")!.Str("id"), "https://hub.example.net");
        Assert.Equal(403, (await Ask(new JsObject { ["origin"] = "https://evil.example" }, manage)).Status); // never another origin
        string hub = Obj(await Ask(new JsObject { ["origin"] = "https://hub.example.net" }, manage)).Str("ticket")!;
        Assert.Equal("https://hub.example.net", await Target(hub));
    }

    [Fact]
    public async Task The_check_endpoint_takes_the_cron_secret()
    {
        var routes = (await RunlightAsync()).Routes(new RoutesOptions { Token = "secret", CronSecret = "cron" });
        Assert.Equal(401, (await routes.HandleAsync(Req("/runlight/api/check", "POST", H(("content-type", "application/json"))))).Status);
        Assert.Equal(200, (await routes.HandleAsync(Req("/runlight/api/check", "POST", H(("authorization", "Bearer cron"))))).Status);
        Assert.Equal(200, (await routes.HandleAsync(Req("/runlight/api/check", "POST", H(("authorization", "Bearer secret"))))).Status);
        routes = (await RunlightAsync()).Routes(new RoutesOptions { Token = "secret", CronSecret = "cron" });
        Assert.Equal(200, (await routes.HandleAsync(Req("/runlight/api/check", "GET", H(("authorization", "Bearer cron"))))).Status); // Vercel Cron sends GET
        Assert.Equal(401, (await routes.HandleAsync(Req("/runlight/api/check"))).Status);
    }

    [Fact]
    public async Task Base_path_moves_everything()
    {
        var routes = (await RunlightAsync()).Routes(new RoutesOptions { Token = "secret", BasePath = "/admin/runlight/" });
        Assert.Equal(200, (await routes.HandleAsync(Req("/admin/runlight/s.js"))).Status);
        Assert.Equal(404, (await routes.HandleAsync(Req("/runlight/s.js"))).Status);
        var info = Obj(await routes.HandleAsync(Req("/admin/runlight/api")));
        Assert.Equal("runlight", info.Str("name"));
        Assert.Equal("Runlight", info.Str("library"));
        Assert.Equal("dotnet", info.Str("language"));
    }

    [Fact]
    public async Task Bad_queries_are_400s_with_a_reason()
    {
        var routes = (await RunlightAsync()).Routes(new RoutesOptions { Token = null });
        foreach (string path in new[] { "/runlight/api/stats?period=forever", "/runlight/api/stats?filter=nope", "/runlight/api/stats?filter=page:like:x", "/runlight/api/breakdown?dimension=shoe_size" })
        {
            var response = await routes.HandleAsync(Req(path));
            Assert.Equal(400, response.Status);
            Assert.False(string.IsNullOrEmpty(Obj(response).Str("error")), path);
        }
    }

    [Fact]
    public async Task The_dashboard_page_loads_its_hashed_assets_under_a_strict_csp()
    {
        string hash = Assets.Build.Str("dashboardHash")!;
        string locales = Assets.Build.Str("localesHash")!;
        var routes = (await RunlightAsync()).Routes(new RoutesOptions { Token = "secret", BasePath = "/admin/runlight" });
        var page = await routes.HandleAsync(Req("/admin/runlight/"));
        Assert.Equal(200, page.Status); // the shell holds no data, so it loads signed out
        Assert.Matches("script-src 'self'", page.Headers.Get("content-security-policy") ?? "");
        string html = page.Text();
        Assert.Contains("/admin/runlight/assets/app." + hash + ".js", html, StringComparison.Ordinal);
        Assert.Contains("data-base=\"/admin/runlight\"", html, StringComparison.Ordinal);
        var js = await routes.HandleAsync(Req("/admin/runlight/assets/app." + hash + ".js"));
        Assert.Equal(200, js.Status);
        Assert.Matches("immutable", js.Headers.Get("cache-control") ?? "");
        Assert.Equal(200, (await routes.HandleAsync(Req("/admin/runlight/assets/app." + hash + ".css"))).Status);
        Assert.Equal(404, (await routes.HandleAsync(Req("/admin/runlight/assets/app.old.js"))).Status);
        Assert.Contains("/admin/runlight/assets/locale.fr." + locales + ".json", html, StringComparison.Ordinal); // the page lists its languages
        var french = await routes.HandleAsync(Req("/admin/runlight/assets/locale.fr." + locales + ".json"));
        Assert.Equal(200, french.Status);
        Assert.Equal("Filtrer", Obj(french).Str("filter.button"));
        Assert.Equal(404, (await routes.HandleAsync(Req("/admin/runlight/assets/locale.xx." + locales + ".json"))).Status);
        Assert.Equal(401, (await routes.HandleAsync(Req("/admin/runlight/api/stats"))).Status); // the data stays behind the token
    }

    [Fact]
    public async Task A_sites_name_and_timezone_can_be_changed_and_survive_a_restart()
    {
        var store = await Databases.FreshAsync("sqlite");
        var first = await RunlightAsync(site: Site(name: "From code", timezone: "UTC"), store: store);
        var routes = first.Routes(new RoutesOptions { Token = null });
        Task<Response> Patch(object body, string type = "application/json") => routes.HandleAsync(Req("/runlight/api/sites/default", "PATCH", H(("content-type", type)), Json.Stringify(body)));
        Assert.Equal(200, (await Patch(new JsObject { ["name"] = "Jon's site", ["timezone"] = "America/Toronto" })).Status);
        Assert.Equal(400, (await Patch(new JsObject { ["timezone"] = "Mars/Olympus" })).Status);
        Assert.Equal(400, (await Patch(new JsObject { ["name"] = "" })).Status);
        Assert.Equal(415, (await Patch(new JsObject { ["name"] = "x" }, "text/plain")).Status);
        Assert.Equal(404, (await routes.HandleAsync(Req("/runlight/api/sites/nope", "PATCH", H(("content-type", "application/json")), "{}"))).Status);
        var listed = Obj(await routes.HandleAsync(Req("/runlight/api/sites")));
        var row = (JsObject)listed.Arr("sites")![0]!;
        Assert.Equal("Jon's site", row.Str("name"));
        Assert.Null(row.Get("lastSeen"));
        Assert.True(row.Has("lastSeen"));

        // Code still says "From code"; the dashboard's change wins after a restart.
        var again = await RunlightAsync(site: Site(name: "From code", timezone: "UTC"), store: store);
        await again.InitAsync();
        Assert.Equal("Jon's site", again.Site("default")!.Str("name"));
        Assert.Equal("America/Toronto", again.Site("default")!.Str("timezone"));
    }

    [Fact]
    public async Task A_share_reads_one_sites_reports_and_nothing_else_until_it_is_deleted()
    {
        var rl = await RunlightAsync(sites: [Site("a", "Site A", ["a.com"], "UTC"), Site("b", "Site B", ["b.com"], "UTC")]);
        var routes = rl.Routes(new RoutesOptions { Token = "secret" });

        Assert.Equal(401, (await routes.HandleAsync(Req("/runlight/api/shares?site=a", "POST", H(("content-type", "application/json")), "{}"))).Status);
        var made = await routes.HandleAsync(Owner("/runlight/api/shares?site=a", "POST", new JsObject { ["name"] = "Client" }));
        Assert.Equal(201, made.Status);
        var share = Obj(made).Obj("share")!;
        string id = share.Str("id")!;
        Assert.Matches("^[a-f0-9]{32}$", id);
        Assert.Equal("/runlight/share/" + id, share.Str("path"));

        var page = await routes.HandleAsync(Req(share.Str("path")!));
        Assert.Equal(200, page.Status);
        Assert.Contains("data-share=\"" + id + "\"", page.Text(), StringComparison.Ordinal);
        Assert.Equal("no-referrer", page.Headers.Get("referrer-policy"));

        var @as = H(("x-runlight-share", id));
        Assert.Equal(200, (await routes.HandleAsync(Req("/runlight/api/stats?site=b", "GET", @as))).Status);
        Assert.Equal("a", Obj(await routes.HandleAsync(Req("/runlight/api/stats?site=b", "GET", @as))).Str("site")); // a share is pinned to its own site whatever is asked
        var sites = Obj(await routes.HandleAsync(Req("/runlight/api/sites", "GET", @as)));
        Assert.Equal("[[\"a\",[]]]", Json.Stringify(sites.Arr("sites")!.Select(s => (object?)L(((JsObject)s!).Get("id"), ((JsObject)s!).Get("hostnames"))).ToList()));
        Assert.Equal(401, (await routes.HandleAsync(Req("/runlight/api/links?site=a", "GET", @as))).Status); // links need the token
        Assert.Equal(401, (await routes.HandleAsync(Req("/runlight/api/shares?site=a", "GET", @as))).Status); // a share cannot list shares
        Assert.Equal(404, (await routes.HandleAsync(Req("/runlight/api/stats", "GET", H(("x-runlight-share", new string('0', 32)))))).Status);

        var renamed = await routes.HandleAsync(Owner("/runlight/api/shares/" + id + "?site=a", "PATCH", new JsObject { ["name"] = "Board" }));
        Assert.Equal("Board", Obj(renamed).Obj("share")!.Str("name"));
        Assert.Equal(404, (await routes.HandleAsync(Owner("/runlight/api/shares/" + id + "?site=b", "DELETE"))).Status); // only from its own site
        Assert.Equal(200, (await routes.HandleAsync(Owner("/runlight/api/shares/" + id + "?site=a", "DELETE"))).Status);
        Assert.Equal(404, (await routes.HandleAsync(Req("/runlight/api/stats", "GET", @as))).Status);
        Assert.Equal(404, (await routes.HandleAsync(Req(share.Str("path")!))).Status);
    }

    [Fact]
    public async Task A_cms_plugin_reports_ai_agent_fetches_with_its_own_key_which_reads_nothing()
    {
        var rl = await RunlightAsync(site: Site(hostnames: ["blog.example.com"]));
        var routes = rl.Routes(new RoutesOptions { Token = "secret", ObserveKey = "agents" });
        Task<Response> Send(string key, object body) => routes.HandleAsync(Owner("/runlight/api/observe", "POST", body, key));
        const string gpt = "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; ChatGPT-User/1.0; +https://openai.com/bot";
        Assert.Equal(401, (await Send("wrong", new JsObject { ["url"] = "https://blog.example.com/post", ["userAgent"] = gpt })).Status);
        Assert.Equal(400, (await Send("agents", new JsObject { ["url"] = "not a url", ["userAgent"] = gpt })).Status);
        Assert.Equal(204, (await Send("agents", new JsObject { ["url"] = "https://blog.example.com/post", ["userAgent"] = gpt })).Status);
        Assert.Equal(204, (await Send("agents", new JsObject { ["url"] = "https://blog.example.com/style.css", ["userAgent"] = gpt })).Status); // assets are ignored, quietly
        Assert.Equal(204, (await Send("agents", new JsObject { ["url"] = "https://elsewhere.example/post", ["userAgent"] = gpt })).Status); // other sites are ignored, quietly
        Assert.Equal(401, (await routes.HandleAsync(Owner("/runlight/api/stats", "GET", null, "agents"))).Status); // the observe key reads nothing
        var rows = Obj(await routes.HandleAsync(Owner("/runlight/api/breakdown?period=today&dimension=ai_page")));
        Assert.Equal("[\"/post\"]", Json.Stringify(Column(rows.Get("rows"), "value")));
    }

    [Fact]
    public async Task A_gone_share_link_says_so_in_the_visitors_language_and_a_read_tokens_write_is_refused_with_a_code()
    {
        var rl = await RunlightAsync(sites: [Site("blog", hostnames: ["blog.example.com"])]);
        var routes = rl.Routes(new RoutesOptions { Token = "secret" });
        var gone = await routes.HandleAsync(Req("/runlight/share/" + new string('a', 32), "GET", H(("accept-language", "fr-CA,fr;q=0.9,en;q=0.8"))));
        Assert.Equal(404, gone.Status);
        Assert.Matches("^text/html", gone.Headers.Get("content-type") ?? "");
        string page = gone.Text();
        Assert.Contains("<html lang=\"fr\">", page, StringComparison.Ordinal);
        Assert.Contains("Ce lien de partage ne fonctionne plus", page, StringComparison.Ordinal);
        Assert.Contains("This share link no longer works", (await routes.HandleAsync(Req("/runlight/share/" + new string('a', 32)))).Text(), StringComparison.Ordinal);

        string read = Obj(await routes.HandleAsync(Owner("/runlight/api/tokens", "POST", new JsObject { ["name"] = "Script" }))).Str("secret")!;
        var write = await routes.HandleAsync(Owner("/runlight/api/goals?site=blog", "POST", new JsObject { ["name"] = "X", ["kind"] = "event", ["match"] = "X" }, read));
        Assert.Equal(403, write.Status);
        Assert.Equal("token_read_only", Obj(write).Str("code"));
    }

    [Fact]
    public async Task Goal_funnel_site_and_assistant_refusals_carry_their_own_codes_and_params()
    {
        var rl = await RunlightAsync(managedSites: true);
        var routes = rl.Routes(new RoutesOptions { Token = "secret" });
        async Task<string> Send(string method, string path, object body)
        {
            var json = Obj(await routes.HandleAsync(Owner("/runlight" + path, method, body)));
            return Json.Stringify(new JsObject { ["code"] = json.Get("code"), ["params"] = json.Get("params") });
        }
        Assert.Equal("{\"code\":\"site_domain_invalid\",\"params\":{\"host\":\"nope\"}}", await Send("POST", "/api/sites", new JsObject { ["name"] = "Blog", ["hostnames"] = "nope" }));
        await Send("POST", "/api/sites", new JsObject { ["name"] = "Blog", ["hostnames"] = "blog.example.com" });
        Assert.Equal("{\"code\":\"site_domain_taken\",\"params\":{\"host\":\"blog.example.com\",\"site\":\"Blog\"}}", await Send("POST", "/api/sites", new JsObject { ["name"] = "Again", ["hostnames"] = "blog.example.com" }));
        await Send("POST", "/api/goals?site=blog.example.com", new JsObject { ["name"] = "Signup", ["kind"] = "event", ["match"] = "Signup" });
        Assert.Equal("{\"code\":\"goal_exists\",\"params\":{\"name\":\"signup\"}}", await Send("POST", "/api/goals?site=blog.example.com", new JsObject { ["name"] = "signup", ["kind"] = "event", ["match"] = "x" }));
        Assert.Equal("{\"code\":\"funnel_short\",\"params\":{}}", await Send("POST", "/api/funnels?site=blog.example.com", new JsObject { ["name"] = "F", ["steps"] = L(new JsObject { ["kind"] = "page", ["match"] = "/" }) }));
        Assert.Equal("{\"code\":\"assistant_provider\",\"params\":{}}", await Send("PUT", "/api/assistant", new JsObject { ["provider"] = "nope" }));
    }

    // The routes' own helpers.

    [Fact]
    public void Cookies_are_read_by_name_with_equals_signs_kept_in_their_values()
    {
        var request = Req("/", "GET", H(("cookie", "a=1; runlight_token=x=y=z ;  other=2")));
        Assert.Equal("x=y=z", global::Runlight.Routes.ReadCookie(request, "runlight_token"));
        Assert.Equal("2", global::Runlight.Routes.ReadCookie(request, "other"));
        Assert.Equal("", global::Runlight.Routes.ReadCookie(request, "missing"));
        Assert.Equal("", global::Runlight.Routes.ReadCookie(Req("/"), "a"));
        Assert.Equal(Hash.Sha256("runlight-cookie:secret"), global::Runlight.Routes.CookieValue("secret"));
    }

    [Fact]
    public void Bearer_tokens_are_read_whatever_the_schemes_case()
    {
        Assert.Equal("abc", global::Runlight.Routes.Bearer(Req("/", "GET", H(("authorization", "Bearer abc")))));
        Assert.Equal("abc", global::Runlight.Routes.Bearer(Req("/", "GET", H(("authorization", "bEaReR   abc  ")))));
        Assert.Equal("", global::Runlight.Routes.Bearer(Req("/", "GET", H(("authorization", "Basic abc")))));
        Assert.Equal("", global::Runlight.Routes.Bearer(Req("/")));
    }

    [Fact]
    public void Only_a_json_media_type_counts_as_json()
    {
        foreach (var (type, want) in new[] { ("application/json", true), ("Application/JSON; charset=utf-8", true), (" application/json ", true), ("text/plain; application/json", false), ("application/json-patch+json", false), ("text/plain;charset=UTF-8", false) })
        {
            Assert.True(want == global::Runlight.Routes.IsJson(Req("/", "POST", H(("content-type", type)), "{}")), type);
        }
        Assert.False(global::Runlight.Routes.IsJson(Req("/", "POST")));
    }

    [Fact]
    public async Task Writes_must_be_json_unless_a_bearer_token_is_sent()
    {
        var routes = (await RunlightAsync(sites: [Site("blog", hostnames: ["blog.example.com"])])).Routes(new RoutesOptions { Token = null });
        // A form from another page cannot send JSON, so a cookie or an open install never lets it write.
        foreach (var (method, path) in new[] { ("POST", "/runlight/api/goals?site=blog"), ("PUT", "/runlight/api/mail"), ("PATCH", "/runlight/api/sites/blog") })
        {
            var answer = await routes.HandleAsync(Req(path, method, H(("content-type", "application/x-www-form-urlencoded")), "name=x"));
            Assert.Equal(415, answer.Status);
            Assert.Equal("{\"error\":\"Send JSON\",\"code\":\"send_json\"}", answer.Text());
        }
        Assert.Equal(415, (await routes.HandleAsync(Req("/runlight/api/check", "POST"))).Status); // even a write with no body
        Assert.Equal(200, (await routes.HandleAsync(Req("/runlight/api/check", "POST", H(("authorization", "Bearer x"))))).Status); // a bearer token is never sent by a browser on its own
        Assert.Equal(404, (await routes.HandleAsync(Req("/runlight/api/goals/nope?site=blog", "DELETE"))).Status); // a DELETE carries no body to check
    }

    [Fact]
    public void Errors_are_json_with_their_code_and_never_sniffed()
    {
        var answer = global::Runlight.Routes.Coded("Unknown site", "unknown_site", 404);
        Assert.Equal("{\"error\":\"Unknown site\",\"code\":\"unknown_site\"}", answer.Text());
        Assert.Equal("nosniff", answer.Headers.Get("x-content-type-options"));
        Assert.Equal("{\"error\":\"x\",\"code\":\"y\",\"params\":{}}", global::Runlight.Routes.Coded("x", "y", 400, []).Text()); // empty params are an object
        Assert.Equal("private, max-age=3600", global::Runlight.Routes.Coded("No icon", "icon_none", 404, null, H(("cache-control", "private, max-age=3600"))).Headers.Get("cache-control"));
    }

    [Fact]
    public async Task An_error_inside_a_route_is_an_internal_error_that_says_nothing_more()
    {
        var routes = (await RunlightAsync(sites: [Site("blog", hostnames: ["blog.example.com"])])).Routes(new RoutesOptions { Token = null });
        // A broken escape in a path makes decodeURIComponent throw, as it does in TypeScript.
        var answer = await routes.HandleAsync(Req("/runlight/api/goals/%E0%A4%A?site=blog", "DELETE"));
        Assert.Equal(500, answer.Status);
        Assert.Equal("{\"error\":\"Internal error\",\"code\":\"internal\"}", answer.Text());
    }

    [Fact]
    public void The_dashboard_shell_escapes_what_it_is_given()
    {
        string html = global::Runlight.Routes.Dashboard("/a\"b", "share<", "/out?x=1&y=2", true, true, "/in");
        Assert.Contains("data-base=\"/a&#34;b\"", html, StringComparison.Ordinal);
        Assert.Contains("data-share=\"share&#60;\"", html, StringComparison.Ordinal);
        Assert.Contains("data-sign-out=\"/out?x=1&#38;y=2\"", html, StringComparison.Ordinal);
        Assert.Contains("data-sign-in=\"/in\" data-geo-credit=\"\" data-accounts=\"\"", html, StringComparison.Ordinal);
        Assert.DoesNotContain("data-share", global::Runlight.Routes.Dashboard("/runlight"), StringComparison.Ordinal);
    }
}
