using System.Collections.Generic;
using System.Threading.Tasks;
using Runlight.Http;
using Xunit;
using static Runlight.Tests.Core.Router;
using static Runlight.Tests.Fixtures;

namespace Runlight.Tests.Core;

/// <summary>
/// The core's part of connecting an install through its consent page, as the PHP's Core/ConnectTest.php tests it:
/// the site the hub adds and the connection it keeps. The consent flow itself is in ConnectTests.
/// </summary>
public sealed class ConnectCoreTests : CoreTestCase
{
    private const string App = "http://127.0.0.1:4100/runlight";

    private static List<object?> L(params object?[] items) => [.. items];

    [Fact]
    public async Task A_hub_connects_an_app_through_its_consent_page_for_the_one_site_the_owner_picked()
    {
        var router = new Router(
            R("/\\.well-known/oauth-authorization-server$", () => new JsObject
            {
                ["authorization_endpoint"] = App + "/oauth/authorize",
                ["token_endpoint"] = App + "/oauth/token",
                ["registration_endpoint"] = App + "/oauth/register",
                ["scopes_supported"] = L("read", "manage"),
            }),
            R("/oauth/register$", () => (201, (object?)new JsObject { ["client_id"] = "c1" })),
            R("/oauth/token$", () => new JsObject { ["access_token"] = "rl_manage", ["site"] = "blog" }),
            R("/api/sites$", () => new JsObject
            {
                ["sites"] = L(
                    new JsObject { ["id"] = "shop", ["name"] = "Shop", ["timezone"] = "UTC", ["hostnames"] = L("shop.example.com") },
                    new JsObject { ["id"] = "blog", ["name"] = "Blog", ["timezone"] = "Asia/Tokyo", ["hostnames"] = L("blog.example.com") }),
            }),
            R("/api/token$", () => new JsObject { ["scope"] = "manage", ["site"] = "blog" }));
        long now = 1_791_288_000_000;
        var hub = new Runlight(new RunlightOptions { Store = await Databases.FreshAsync("sqlite"), ManagedSites = true, Secret = new string('k', 32), Fetcher = router, Now = () => now });
        await hub.InitAsync();
        const string back = "http://localhost:4900/runlight/api/sites/connect/done";
        var consent = new Url(await Connect.StartConnectAsync(hub.Store, hub.Fetcher, hub.Now, App + "/", back));
        string state = consent.SearchParams.Get("state")!;

        string id = await Connect.FinishConnectAsync(hub.Store, hub.Fetcher, hub.Now, input => hub.AddSiteAsync(input), new SearchParams { { "state", state }, { "code", "the-code" } });
        Assert.Equal("blog.example.com", id);
        Assert.Equal("{\"url\":\"" + App + "\",\"token\":\"rl_manage\",\"site\":\"blog\",\"hostnames\":[\"blog.example.com\"],\"scope\":\"manage\"}", J(hub.Remote(id)));
        Assert.Equal("{\"id\":\"blog.example.com\",\"name\":\"Blog\",\"hostnames\":[],\"timezone\":\"Asia/Tokyo\"}", J(hub.Site(id)));
    }
}
