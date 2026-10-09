using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Runlight.Http;
using Runlight.Store;

namespace Runlight;

/// <summary>
/// Short links: create, change, delete, and import, with the rules every route shares.
/// </summary>
/// <remarks>
/// A LinkInput is a JsObject with <c>url</c>, and optionally <c>name</c>, <c>slug</c>, and
/// <c>domain</c> (a link domain added in Settings, or "" for the app's own). A key left out is
/// TypeScript's undefined.
/// </remarks>
/// <param name="store">The Runlight's store.</param>
/// <param name="now">The Runlight's clock, in epoch milliseconds.</param>
/// <param name="init">The Runlight's init (migrating the store), run before each change; none when null.</param>
public sealed class Links(SqlStore store, Func<long> now, Func<CancellationToken, Task>? init = null)
{
    public static readonly Regex SlugPattern = new("^[A-Za-z0-9][A-Za-z0-9_-]{0,99}\\z", RegexOptions.CultureInvariant);
    private const string Alphabet = "abcdefghijkmnpqrstuvwxyz23456789";

    /// <summary>Six characters from an alphabet without look-alikes (no 0/o, 1/l).</summary>
    public static string RandomSlug()
    {
        var chars = new char[6];
        byte[] bytes = RandomNumberGenerator.GetBytes(6);
        for (int i = 0; i < 6; i++)
        {
            chars[i] = Alphabet[bytes[i] % Alphabet.Length];
        }
        return new string(chars);
    }

    private static string CleanUrl(object? value)
    {
        string text = Js.Trim(Js.String(value ?? ""));
        var url = Url.Parse(text) ?? throw new LinkError("The destination must be a full URL, starting with https://", "link_url");
        if (url.Protocol != "https:" && url.Protocol != "http:")
        {
            throw new LinkError("The destination must start with http:// or https://", "link_protocol");
        }
        if (text.Length > 2000)
        {
            throw new LinkError("The destination is longer than 2,000 characters", "link_long");
        }
        return url.Href;
    }

    private static string DefaultName(string url)
    {
        var u = new Url(url);
        return Js.Slice(Sources.StripWww(u.Hostname) + (u.Pathname == "/" ? "" : u.Pathname), 0, 100);
    }

    /// <summary>Whether the key holds a value that is not undefined.</summary>
    private static bool Given(JsObject input, string key) => input.Prop(key) is not Undefined;

    private async Task<string> DomainForAsync(string site, object? value, CancellationToken cancellationToken)
    {
        string domain = Sources.StripWww(Js.Trim(Js.String(value ?? "")));
        if (domain.Length == 0)
        {
            return "";
        }
        foreach (var d in await store.LinkDomainsAsync(cancellationToken).ConfigureAwait(false))
        {
            if (d.Str("domain") == domain && d.Str("site") == site)
            {
                return domain;
            }
        }
        throw new LinkError("Add " + domain + " as a link domain in Settings first", "link_domain", new JsObject { ["domain"] = domain });
    }

    /// <summary>Slugs are unique across every domain, so a link can always fall back to the app's own path.</summary>
    private async Task<string> FreeSlugAsync(string? wanted, string? except, CancellationToken cancellationToken)
    {
        if (!string.IsNullOrEmpty(wanted))
        {
            if (!SlugPattern.IsMatch(wanted))
            {
                throw new LinkError("A slug is letters, digits, dashes, and underscores, up to 100", "link_slug");
            }
            var taken = await store.LinkBySlugAsync(wanted, cancellationToken).ConfigureAwait(false);
            if (taken != null && taken.Str("id") != except)
            {
                throw new LinkError("/" + wanted + " is already taken", "link_taken", new JsObject { ["slug"] = wanted });
            }
            return wanted;
        }
        for (int i = 0; i < 8; i++)
        {
            string slug = RandomSlug();
            if (await store.LinkBySlugAsync(slug, cancellationToken).ConfigureAwait(false) == null)
            {
                return slug;
            }
        }
        throw new LinkError("Could not find a free slug; try again", "link_no_slug");
    }

    private async Task InitAsync(CancellationToken cancellationToken)
    {
        if (init != null)
        {
            await init(cancellationToken).ConfigureAwait(false);
        }
    }

    /// <summary>Makes a link. Throws a <see cref="LinkError"/> saying what is wrong with the input.</summary>
    /// <returns>The LinkRow.</returns>
    public async Task<JsObject> CreateAsync(string site, JsObject input, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(input);
        await InitAsync(cancellationToken).ConfigureAwait(false);
        string url = CleanUrl(input.Get("url"));
        string domain = await DomainForAsync(site, input.Get("domain"), cancellationToken).ConfigureAwait(false);
        object? wanted = input.Get("slug");
        string slug = await FreeSlugAsync(wanted is null or Undefined ? null : Js.Trim(Js.String(wanted)), null, cancellationToken).ConfigureAwait(false);
        long at = now();
        object? given = input.Get("name");
        string name = given is null or Undefined ? "" : Js.Trim(Js.String(given));
        var link = new JsObject
        {
            ["id"] = Hash.RandomId(),
            ["site"] = site,
            ["domain"] = domain,
            ["slug"] = slug,
            ["name"] = Js.Slice(name.Length > 0 ? name : DefaultName(url), 0, 100),
            ["url"] = url,
            ["createdAt"] = at,
            ["updatedAt"] = at,
        };
        await store.InsertLinkAsync(link, cancellationToken).ConfigureAwait(false);
        return link;
    }

    /// <summary>Changes a link: keys left out are left alone.</summary>
    /// <exception cref="ArgumentOutOfRangeException">For an unknown link (a RangeError in TypeScript).</exception>
    public async Task<JsObject> UpdateAsync(string id, JsObject input, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(input);
        await InitAsync(cancellationToken).ConfigureAwait(false);
        var link = await store.LinkByIdAsync(id, cancellationToken).ConfigureAwait(false) ?? throw UnknownLink();
        var next = link.Clone();
        if (Given(input, "url"))
        {
            next["url"] = CleanUrl(input.Get("url"));
        }
        if (Given(input, "name"))
        {
            string name = Js.Slice(Js.Trim(Js.String(input.Get("name"))), 0, 100);
            next["name"] = name.Length > 0 ? name : DefaultName(next.Str("url") ?? "");
        }
        // Keeping a link's domain needs no check, even while that domain is removed.
        if (Given(input, "domain") && Sources.StripWww(Js.Trim(Js.String(input.Get("domain")))) != link.Str("domain"))
        {
            next["domain"] = await DomainForAsync(link.Str("site") ?? "", input.Get("domain"), cancellationToken).ConfigureAwait(false);
        }
        if (Given(input, "slug"))
        {
            next["slug"] = await FreeSlugAsync(Js.Trim(Js.String(input.Get("slug"))), link.Str("id"), cancellationToken).ConfigureAwait(false);
        }
        next["updatedAt"] = now();
        await store.UpdateLinkAsync(next, cancellationToken).ConfigureAwait(false);
        return next;
    }

    /// <summary>Deletes a link.</summary>
    /// <exception cref="ArgumentOutOfRangeException">For an unknown link (a RangeError in TypeScript).</exception>
    public async Task RemoveAsync(string id, CancellationToken cancellationToken = default)
    {
        await InitAsync(cancellationToken).ConfigureAwait(false);
        if (await store.LinkByIdAsync(id, cancellationToken).ConfigureAwait(false) == null)
        {
            throw UnknownLink();
        }
        await store.DeleteLinkAsync(id, now(), cancellationToken).ConfigureAwait(false);
    }

    private static ArgumentOutOfRangeException UnknownLink() => new(null, "Unknown link");

    /// <summary>
    /// Creates many links at once, as from a CSV. Rows that fail are reported with their reason and
    /// the rest go in. Headers match the Umami fork's export: name or link_name, url or
    /// destination_url, slug or link_slug, domain or tracking_domain.
    /// </summary>
    /// <returns>{ created, failed: [{ row, reason, code, params }] }.</returns>
    public async Task<JsObject> ImportAsync(string site, IEnumerable<object?> rows, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(rows);
        var failed = new List<object?>();
        long created = 0;
        int i = 0;
        foreach (object? item in rows)
        {
            i++;
            var raw = item as JsObject ?? [];
            string? Pick(params string[] keys)
            {
                foreach (string key in keys)
                {
                    if (raw.Get(key) is string value && Js.Trim(value).Length > 0)
                    {
                        return Js.Trim(value);
                    }
                }
                return null;
            }
            var input = new JsObject { ["url"] = Pick("url", "destination_url") ?? "" };
            foreach (var (field, keys) in new[] { ("name", new[] { "name", "link_name" }), ("slug", new[] { "slug", "link_slug" }), ("domain", new[] { "domain", "tracking_domain" }) })
            {
                string? value = Pick(keys);
                if (value != null)
                {
                    input[field] = value;
                }
            }
            try
            {
                await CreateAsync(site, input, cancellationToken).ConfigureAwait(false);
                created++;
            }
            catch (LinkError error)
            {
                // A bad row is reported and skipped; a failing database stops the whole import.
                failed.Add(new JsObject { ["row"] = (long)i, ["reason"] = error.Message, ["code"] = error.Code, ["params"] = error.Params });
            }
        }
        return new JsObject { ["created"] = created, ["failed"] = failed };
    }
}
