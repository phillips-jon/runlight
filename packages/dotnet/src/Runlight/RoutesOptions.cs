using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Runlight.Accounts;
using Runlight.Http;

namespace Runlight;

/// <summary>
/// What <see cref="Runlight.Routes(RoutesOptions?)"/> takes, with the TypeScript option names. Leave a property
/// unset for its default.
/// </summary>
public sealed class RoutesOptions
{
    private string? _token;
    private bool _tokenGiven;

    /// <summary>Where the routes are mounted. Default "/runlight".</summary>
    public string? BasePath { get; init; }

    /// <summary>
    /// Required to read stats. Send it as <c>Authorization: Bearer &lt;token&gt;</c>, or open the dashboard once
    /// with <c>?token=&lt;token&gt;</c> and a cookie is set. Left unset, RUNLIGHT_TOKEN is read. Without one, the
    /// dashboard and API are open only when NODE_ENV is "development", and answer 503 everywhere else. Set it to
    /// null to leave them open everywhere, for example behind your own auth middleware.
    /// </summary>
    public string? Token
    {
        get => _token;
        init
        {
            _token = value;
            _tokenGiven = true;
        }
    }

    /// <summary>Whether <see cref="Token"/> was set at all (to null too), as TS tells "token" in options apart.</summary>
    public bool TokenGiven => _tokenGiven;

    /// <summary>
    /// Your own check instead of a token: true is full access, "member" changes everything but the install-wide
    /// controls (the mail service, the assistant's settings, and deleting a site), "read" reads every site's stats
    /// and changes nothing (as an API token can), and false is no access.
    /// </summary>
    public Func<Request, CancellationToken, Task<object>>? Authorize { get; init; }

    /// <summary>Also accepted as a bearer token on POST /api/check. Defaults to CRON_SECRET.</summary>
    public string? CronSecret { get; init; }

    /// <summary>Lets another site report AI agent fetches to POST /api/observe. Defaults to RUNLIGHT_OBSERVE_KEY.</summary>
    public string? ObserveKey { get; init; }

    /// <summary>A link the dashboard shows to sign out. The standalone server sets it.</summary>
    public string? SignOut { get; init; }

    /// <summary>A link the dashboard shows to sign in. The standalone server sets it.</summary>
    public string? SignIn { get; init; }

    /// <summary>True for sign-in accounts (TypeScript's <c>accounts: true</c>).</summary>
    public bool Accounts { get; init; }

    /// <summary>Accounts of your own (TypeScript's <c>accounts: AccountsWeb</c>); wins over <see cref="Accounts"/>.</summary>
    public Web? AccountsWeb { get; init; }

    /// <summary>Credits DB-IP in the dashboard's footer.</summary>
    public bool GeoCredit { get; init; }

    /// <summary>The address people open the app at, such as https://example.com.</summary>
    public string? Origin { get; init; }

    /// <summary>More names the dashboard is reached at.</summary>
    public Func<IEnumerable<string>>? OwnHosts { get; init; }

    /// <summary>The account a request comes from (internal, for the standalone server).</summary>
    public Func<Request, CancellationToken, Task<string?>>? AccountOf { get; init; }

    /// <summary>Notes who made a token, and false takes it back (internal, for the standalone server).</summary>
    public Func<JsObject, string, CancellationToken, Task<bool>>? TokenMade { get; init; }
}
