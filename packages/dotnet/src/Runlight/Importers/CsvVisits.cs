using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using Runlight.Http;

namespace Runlight.Importers;

/// <summary>
/// Visit history from a CSV file, in one of two shapes: Umami's data export
/// (one row per pageview or event, as in its website_event table) or Runlight's
/// own, documented on the dashboard docs page. The dashboard reads the file,
/// sorts it with <see cref="RowTime"/>, and sends it in batches; the server turns each row
/// into a hit with <see cref="CsvHit"/>. Nothing here touches a database.
/// </summary>
/// <remarks>A format is "umami" or "runlight". A hit is an ImportedHit object (see Visits).</remarks>
public static partial class CsvVisits
{
    /// <summary>At most this many rows in one request.</summary>
    public const int CsvBatch = 2000;

    [GeneratedRegex("^[0-9]+(\\.[0-9]+)?\\z", RegexOptions.CultureInvariant)]
    private static partial Regex UnixTime();

    [GeneratedRegex("[zZ]|[+-][0-9][0-9]:?[0-9][0-9]\\z", RegexOptions.CultureInvariant)]
    private static partial Regex Zoned();

    [GeneratedRegex("T[0-9]", RegexOptions.CultureInvariant)]
    private static partial Regex Timed();

    [GeneratedRegex("^[a-zA-Z][a-zA-Z0-9+.-]*://", RegexOptions.CultureInvariant)]
    private static partial Regex Scheme();

    /// <summary>Which shape a file is, from its header row (lower case, as the dashboard reads it).</summary>
    public static string? CsvFormat(IReadOnlyCollection<string> columns)
    {
        bool Has(string c) => columns.Contains(c, StringComparer.Ordinal);
        if (Has("created_at") && Has("url_path"))
        {
            return "umami";
        }
        if (Has("time") && (Has("path") || Has("url")))
        {
            return "runlight";
        }
        return null;
    }

    /// <summary>
    /// A row's time in milliseconds, or NaN. ISO 8601 with or without a zone, "2024-05-01 12:34:56"
    /// (both read as UTC when no zone is given, as Umami writes them), or a Unix time in seconds or milliseconds.
    /// </summary>
    public static double RowTime(JsObject row, string format)
    {
        string text = row.Get(format == "umami" ? "created_at" : "time") is string s ? Js.Trim(s) : "";
        if (text.Length == 0)
        {
            return double.NaN;
        }
        if (UnixTime().IsMatch(text))
        {
            double n = Js.Number(text);
            return n < 1e12 ? Js.Round(n * 1000) : Js.Round(n);
        }
        int space = text.IndexOf(' ', StringComparison.Ordinal);
        string iso = space < 0 ? text : text[..space] + "T" + text[(space + 1)..];
        return Http.ParseDate(Zoned().IsMatch(iso) || !Timed().IsMatch(iso) ? iso : iso + "Z");
    }

    private static string Cell(JsObject row, params string[] names)
    {
        foreach (string n in names)
        {
            if (row.Get(n) is string s && Js.Trim(s).Length > 0)
            {
                return Js.Trim(s);
            }
        }
        return "";
    }

    /// <summary>A row with no visitor is its own visit, keyed by its whole content so a second import gives it the same ids.</summary>
    private static string OwnKey(JsObject row)
    {
        var entries = row.OrderBy(e => e.Key, StringComparer.Ordinal).Select(e => (object?)Js.List(e.Key, e.Value)).ToList();
        return "row:" + Json.Stringify(entries);
    }

    /// <summary>A referrer as a full address: a bare domain gains https://.</summary>
    private static string FullReferrer(string value) => value.Length == 0 ? "" : Scheme().IsMatch(value) ? value : "https://" + value;

    /// <summary>
    /// One row as a hit and the namespace its ids are made in, or null for a row that is not a pageview or a
    /// named event, or has no time. Umami rows use the namespace the Umami API import does, so the same visits
    /// brought in both ways get the same ids.
    /// </summary>
    public static (string Ns, JsObject Hit)? CsvHit(JsObject row, string format)
    {
        double ts = RowTime(row, format);
        if (!double.IsFinite(ts))
        {
            return null;
        }
        if (format == "umami")
        {
            string type = Cell(row, "event_type");
            type = type.Length > 0 ? type : "1";
            string name = Cell(row, "event_name");
            if (type != "1" && !(type == "2" && name.Length > 0))
            {
                return null;
            }
            string website = Cell(row, "website_id");
            string domain = Cell(row, "referrer_domain");
            string query = Cell(row, "referrer_query");
            string referrerPath = Cell(row, "referrer_path");
            string key = Cell(row, "session_id", "visit_id");
            string path = Cell(row, "url_path");
            return (website.Length > 0 ? "umami-visits:" + website : "umami-csv", new JsObject
            {
                ["ts"] = ts,
                ["key"] = key.Length > 0 ? key : OwnKey(row),
                ["kind"] = type == "1" ? "pageview" : "event",
                ["hostname"] = Cell(row, "hostname"),
                ["path"] = path.Length > 0 ? path : "/",
                ["query"] = Cell(row, "url_query"),
                ["referrer"] = domain.Length == 0 ? "" : "https://" + domain + (referrerPath.Length > 0 ? referrerPath : "/") + (query.Length > 0 ? "?" + (query.StartsWith('?') ? query[1..] : query) : ""),
                ["title"] = Cell(row, "page_title"),
                ["name"] = type == "2" ? name : "",
                ["country"] = Cell(row, "country"),
                ["region"] = Cell(row, "subdivision1", "region"),
                ["city"] = Cell(row, "city"),
                ["browser"] = Cell(row, "browser"),
                ["os"] = Cell(row, "os"),
                ["device"] = Cell(row, "device"),
                ["screen"] = Cell(row, "screen"),
                ["language"] = Cell(row, "language"),
            });
        }
        // Runlight's own shape: a full url, or a path (with its query) and a hostname.
        string hostname = Cell(row, "hostname");
        string ownPath = Cell(row, "path");
        string ownQuery = "";
        string url = Cell(row, "url");
        if (url.Length > 0)
        {
            var u = Url.Parse(Scheme().IsMatch(url) ? url : "https://" + url);
            if (u == null)
            {
                return null;
            }
            hostname = hostname.Length > 0 ? hostname : u.Hostname;
            ownPath = u.Pathname;
            ownQuery = Js.Slice(u.Search, 1);
        }
        else
        {
            int at = ownPath.IndexOf('?', StringComparison.Ordinal);
            if (at >= 0)
            {
                (ownPath, ownQuery) = (ownPath[..at], ownPath[(at + 1)..]);
            }
        }
        if (!ownPath.StartsWith('/'))
        {
            ownPath = "/" + ownPath;
        }
        string eventName = Cell(row, "event");
        string visitor = Cell(row, "visitor");
        return ("csv", new JsObject
        {
            ["ts"] = ts,
            // Without a visitor column every row is its own visit.
            ["key"] = visitor.Length > 0 ? visitor : OwnKey(row),
            ["kind"] = eventName.Length > 0 ? "event" : "pageview",
            ["hostname"] = hostname,
            ["path"] = ownPath,
            ["query"] = ownQuery,
            ["referrer"] = FullReferrer(Cell(row, "referrer")),
            ["title"] = Cell(row, "title"),
            ["name"] = eventName,
            ["country"] = Cell(row, "country"),
            ["region"] = Cell(row, "region"),
            ["city"] = Cell(row, "city"),
            ["browser"] = Cell(row, "browser"),
            ["os"] = Cell(row, "os"),
            ["device"] = Cell(row, "device"),
            ["screen"] = Cell(row, "screen"),
            ["language"] = Cell(row, "language"),
        });
    }
}
