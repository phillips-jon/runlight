using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace Runlight.Importers;

/// <summary>Link imports from other shorteners, a step at a time.</summary>
public static class Index
{
    /// <summary>The sources a link import can read, by name, each made with the Runlight's fetcher and clock.</summary>
    public static readonly IReadOnlyDictionary<string, Func<Http, Func<long>, IImporter>> Importers = new Dictionary<string, Func<Http, Func<long>, IImporter>>(StringComparer.Ordinal)
    {
        ["umami"] = (http, now) => new Umami(http, now),
        ["dub"] = (http, now) => new Dub(http, now),
        ["bitly"] = (http, now) => new Bitly(http, now),
        ["shortio"] = (http, now) => new Shortio(http, now),
        ["rebrandly"] = (http, now) => new Rebrandly(http, now),
    };

    /// <summary>
    /// One step of an import: fetch the next few links from the source, write each with its history, and
    /// report progress. The cursor carries where to pick up, so the page calls this until the cursor comes
    /// back null.
    /// </summary>
    /// <remarks>
    /// Each importer makes its requests through the Runlight's fetcher, and reads the Runlight's clock as its
    /// <c>now</c>: the date of a link the source gives none for, and where Umami's history ends.
    /// </remarks>
    /// <returns>{ cursor, done, total, links, clicks, skipped, failed: [{ slug, reason, code?, params? }] }.</returns>
    public static async Task<JsObject> ImportStepAsync(Runlight runlight, string site, string source, JsObject credentials, string? cursor, double done, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(runlight);
        if (!Importers.TryGetValue(source, out var make))
        {
            throw new ImportError("Runlight cannot import from " + source, "import_source", new JsObject { ["source"] = source });
        }
        await runlight.InitAsync(cancellationToken).ConfigureAwait(false);
        var importer = make(new Http(runlight.Fetcher), runlight.Now);
        async Task<bool> Known(string sourceId, string? slug, string? url)
        {
            if (await runlight.Store.LinkByIdAsync(Write.ImportedLinkId(source, sourceId), cancellationToken).ConfigureAwait(false) != null)
            {
                return true;
            }
            if (string.IsNullOrEmpty(slug) || string.IsNullOrEmpty(url))
            {
                return false;
            }
            var taken = await runlight.Store.LinkBySlugAsync(slug, cancellationToken).ConfigureAwait(false);
            return taken != null && Write.SameUrl(taken.Str("url")!, url);
        }
        var result = await importer.StepAsync(credentials, cursor, Known, cancellationToken).ConfigureAwait(false);
        // A total that is not a number is as good as none.
        object? total = result.Get("total") is long or double && double.IsFinite(result.Num("total")) ? result.Get("total") : null;
        object? next = result.Get("cursor") is Undefined ? null : result.Get("cursor");
        double stepDone = done;
        long links = 0;
        long clicks = 0;
        long skipped = 0;
        var failed = new List<object?>();
        foreach (var item in (result.Get("links") as List<object?> ?? []).OfType<JsObject>())
        {
            if (Js.Truthy(item.Get("known")))
            {
                stepDone++;
                skipped++;
                continue;
            }
            var link = item.Obj("link")!;
            var written = await Write.WriteLinkAsync(runlight, site, source, link, item, cancellationToken).ConfigureAwait(false);
            stepDone++;
            switch (written.Str("status"))
            {
                case "created":
                    links++;
                    clicks += written.Long("clicks");
                    break;
                case "skipped":
                    skipped++;
                    break;
                default:
                    var failure = new JsObject { ["slug"] = link.Get("slug"), ["reason"] = written.Str("reason") ?? "" };
                    if (written.Has("code"))
                    {
                        failure["code"] = written.Get("code");
                        failure["params"] = written.Obj("params") ?? new JsObject();
                    }
                    failed.Add(failure);
                    break;
            }
        }
        // Links the source skipped (deleted ones) still count toward progress.
        if (string.IsNullOrEmpty(next as string) && total != null)
        {
            stepDone = Math.Max(stepDone, Js.Num(total));
        }
        return new JsObject
        {
            ["cursor"] = next,
            ["done"] = Js.IsInteger(stepDone) && Math.Abs(stepDone) < Js.MaxSafeInteger ? (object)(long)stepDone : stepDone,
            ["total"] = total,
            ["links"] = links,
            ["clicks"] = clicks,
            ["skipped"] = skipped,
            ["failed"] = failed,
        };
    }
}
