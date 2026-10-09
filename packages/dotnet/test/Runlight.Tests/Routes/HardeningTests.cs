using System.Threading.Tasks;
using Runlight.Http;
using Xunit;
using static Runlight.Tests.Routes.Make;

namespace Runlight.Tests.Routes;

/// <summary>The route-level part of hardening.test.ts: a link domain's check. The rest belongs to the core, safefetch, and the stores.</summary>
public sealed class HardeningTests : RoutesTestCase
{
    [Fact]
    public async Task A_link_domains_check_says_where_the_domain_should_point_for_its_setup_steps()
    {
        var answers404 = new FakeFetcher((_, _) => new Response("no", 404));
        var rl = await RunlightAsync(site: Site(hostnames: ["example.com"]), fetcher: answers404);
        await rl.InitAsync();
        await rl.Store.AddLinkDomainAsync("go.example.net", "default", 0);
        var check = Obj(await rl.Routes(new RoutesOptions { Token = "secret" }).HandleAsync(Owner("/runlight/api/link-domains/go.example.net/check")));
        Assert.Equal("example.com", check.Obj("target")!.Str("host")); // this dashboard's own name, for a CNAME
        Assert.NotNull(check.Obj("target")!.Arr("addresses"));
        Assert.False(check.Bool("working"));
        Assert.True(check.Has("working"));
    }
}
