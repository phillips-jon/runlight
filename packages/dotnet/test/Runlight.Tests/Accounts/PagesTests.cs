using System.Linq;
using Runlight.Accounts;
using Xunit;
using static Runlight.Tests.Fixtures;

namespace Runlight.Tests.Accounts;

/// <summary>The account pages against tests/fixtures/pages.json, the TypeScript's HTML for the same inputs.</summary>
public sealed class PagesTests
{
    [Fact]
    public void Styles_and_script_match()
    {
        var fixture = Load("pages");
        Assert.True(fixture.Str("css") == Pages.AuthCss);
        Assert.True(fixture.Str("js") == Pages.AuthJs);
    }

    /// <summary>A page by the TypeScript function's name and its options object.</summary>
    private static string Render(string fn, string basePath, JsObject? o) => fn switch
    {
        "loginPage" => Pages.LoginPage(basePath, o!.Str("forgot")!, o.Str("error"), o.Str("email"), o.Str("next")),
        "codePage" => Pages.CodePage(basePath, o!.Str("pending")!, o.Str("next")!, o.Str("error")),
        "invitePage" => Pages.InvitePage(basePath, o!.Str("code")!, o.Str("email")!, o.Str("role")!, o.Str("host")!, o.Str("error")),
        "inviteGonePage" => Pages.InviteGonePage(basePath),
        "setupPage" => Pages.SetupPage(basePath, o!.Str("code")!, o.Str("error"), o.Str("email"), o.Bool("askCode")),
        "setupLockedPage" => Pages.SetupLockedPage(basePath),
        "setupNeedsTokenPage" => Pages.SetupNeedsTokenPage(basePath),
        _ => throw new Xunit.Sdk.XunitException("unknown page " + fn),
    };

    [Fact]
    public void Pages_match()
    {
        var fixture = Load("pages");
        foreach (var c in fixture.Arr("pages")!.Cast<JsObject>())
        {
            string html = Render(c.Str("fn")!, c.Str("base")!, c.Obj("opts"));
            Assert.True(c.Str("html") == html, c.Str("fn") + " at \"" + c.Str("base") + "\"");
        }
        foreach (var c in fixture.Arr("roles")!.Cast<JsObject>())
        {
            Assert.Equal(c.Str("text"), Pages.RoleText(c.Str("role")!));
        }
    }

    [Fact]
    public void Setup_asks_for_the_token_when_told()
    {
        string page = Pages.SetupPage("/runlight", "", askCode: true);
        Assert.Contains("RUNLIGHT_TOKEN", page);
        Assert.Contains("action=\"/runlight/setup\"", page);
        Assert.Contains("href=\"/runlight/auth.css\"", page);
        Assert.Contains("as a member", Pages.InvitePage("", "c", "a@b.c", "member", "x"));
    }
}
