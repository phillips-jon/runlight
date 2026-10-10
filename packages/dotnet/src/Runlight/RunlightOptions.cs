using System;
using System.Collections.Generic;
using Runlight.Http;
using Runlight.Store;

namespace Runlight;

/// <summary>A site this install counts, as the options give it.</summary>
public sealed class SiteOptions
{
    /// <summary>Stable id, stored with every row. Default "default" for the first site.</summary>
    public string? Id { get; init; }

    public string? Name { get; init; }

    /// <summary>
    /// Hostnames that belong to this site, without www. With one site, empty means any hostname. With
    /// several, each site needs at least one.
    /// </summary>
    public IReadOnlyList<string>? Hostnames { get; init; }

    /// <summary>IANA timezone for reports, such as "Europe/London". Default "UTC".</summary>
    public string? Timezone { get; init; }
}

/// <summary>
/// Whether to read the client's address from forwarding headers: true (every one, in order), false (the
/// connection's address only), or one header's name ("x-forwarded-for", "x-real-ip", "cf-connecting-ip").
/// A bool or a string converts to it, as TypeScript's <c>boolean | string</c> option takes either.
/// </summary>
public readonly record struct ProxyTrust(bool On, string? Header)
{
    public static implicit operator ProxyTrust(bool on) => new(on, null);

    public static implicit operator ProxyTrust(string header) => new(true, header);

    public static ProxyTrust FromBoolean(bool on) => new(on, null);

    public static ProxyTrust FromString(string header) => new(true, header);
}

/// <summary>Runlight's options, with the TypeScript names.</summary>
public sealed class RunlightOptions
{
    /// <summary>The store, such as Stores.Sqlite(SqliteFactory.Instance, "./data/runlight.db"). Required.</summary>
    public required SqlStore Store { get; init; }

    /// <summary>The site this install counts. Ignored when <see cref="Sites"/> is given.</summary>
    public SiteOptions? Site { get; init; }

    /// <summary>Several sites in one install, told apart by hostname.</summary>
    public IReadOnlyList<SiteOptions>? Sites { get; init; }

    /// <summary>
    /// Sites are added, changed, and deleted in the dashboard and kept in the database, as the standalone
    /// server does. <see cref="Site"/> and <see cref="Sites"/> are ignored.
    /// </summary>
    public bool ManagedSites { get; init; }

    /// <summary>Looks up a location ({ country, region, city }) for an IP when the platform sends no location headers.</summary>
    public Func<string, JsObject?>? Geo { get; init; }

    /// <summary>
    /// Read the client IP from forwarding headers: the last X-Forwarded-For entry, which the nearest proxy
    /// wrote, then X-Real-IP, then CF-Connecting-IP. Name one of them to read only that header, such as
    /// "cf-connecting-ip" behind Cloudflare and another proxy. Default true: analytics needs the visitor's
    /// address, and most apps sit behind a proxy. False reads only the connection's address, for an app
    /// nothing sits in front of. Left unset, it is true, and Runlight warns once if a request then comes
    /// straight from a public address with no forwarding header.
    /// </summary>
    public ProxyTrust? TrustProxy { get; init; }

    /// <summary>Where short links on the app's own domain live, as <c>{linkPath}/{slug}</c>. Default "/go".</summary>
    public string? LinkPath { get; init; }

    /// <summary>
    /// The mail service for email reports, in code: a Transports config plus <c>from</c> and <c>fromName</c>.
    /// When set, the dashboard shows it and cannot change it. Otherwise it is set up in Settings.
    /// </summary>
    public JsObject? Mail { get; init; }

    /// <summary>
    /// Encrypts the keys kept in the database: the mail service's, the AI Assistant's, and the tokens for
    /// connected installs. Default the RUNLIGHT_SECRET environment variable, then RUNLIGHT_TOKEN.
    /// </summary>
    public string? Secret { get; init; }

    /// <summary>
    /// Tracker requests allowed per visitor address per minute, counted in memory by each process. Default
    /// 120, which a real visitor never reaches; null (TypeScript's false), 0, or less turns the limit off.
    /// </summary>
    public double? RateLimit { get; init; } = 120;

    /// <summary>
    /// Lets a connected install be at http://localhost or http://127.0.0.1, for trying a hub and an app on
    /// one machine. Default false: otherwise anyone who can add a site could have this server ask services
    /// on its own machine, so other installs must be public https addresses.
    /// </summary>
    public bool LocalInstalls { get; init; }

    /// <summary>The clock, in epoch milliseconds. For tests.</summary>
    public Func<long>? Now { get; init; }

    /// <summary>Every outgoing request goes through it. Default a <see cref="HttpClientFetcher"/>.</summary>
    public IFetcher? Fetcher { get; init; }
}

/// <summary>
/// Handles a request on behalf of an adapter, given the connection's address when the request does not carry
/// it (TypeScript's RequestContext's ip).
/// </summary>
public delegate System.Threading.Tasks.Task<Response> RequestHandler(Request request, string? ip = null, System.Threading.CancellationToken cancellationToken = default);
