using System;
using System.Collections.Generic;
using System.Linq;

namespace Runlight;

/// <summary>
/// Journeys: the paths visits take through a site, page by page. Each visit's pages are read in
/// order, a page seen twice in a row (a refresh) counts once, and the path is cut to a number of
/// steps, from a start page and to an end page when those are chosen. The answer lines the paths up
/// in columns, one per step, with the flows between them, as Umami's journeys do.
/// </summary>
/// <remarks>
/// Options: steps, and optionally start, end, and through ({ step, value }: only paths that show
/// this page at this step, 0-based, to follow one page).
///
/// The answer: visits; columns, each with items (the pages seen at this step, most visits first,
/// with the rest as "" for other pages), visits (that reached this step), and left (that went no
/// further); links, visits moving from a page at one step to a page at the next, "" being any other
/// page; and paths, the commonest whole paths.
/// </remarks>
public static class Journeys
{
    /// <summary>How many pages of a visit to read: enough to find a start page and still have the steps after it.</summary>
    public const int PagesPerVisit = 40;

    private const int Top = 8;

    /// <param name="rows">Each { session, path }, in the order the pages were seen.</param>
    /// <param name="options">steps, and optionally start, end, and through.</param>
    public static JsObject Of(IEnumerable<JsObject> rows, JsObject options)
    {
        ArgumentNullException.ThrowIfNull(rows);
        ArgumentNullException.ThrowIfNull(options);
        double floor = Math.Floor(Js.Number(options.Prop("steps")));
        int steps = (int)Math.Min(Math.Max(double.IsNaN(floor) || floor == 0 ? 5 : floor, 2), 8);
        // Group each visit's pages, dropping refreshes.
        var visits = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        var order = new List<List<string>>();
        foreach (var row in rows)
        {
            string key = Js.String(row.Get("session"));
            string path = Js.String(row.Get("path"));
            if (!visits.TryGetValue(key, out var pages))
            {
                pages = [];
                visits[key] = pages;
                order.Add(pages);
            }
            if (pages.Count == 0 || pages[^1] != path)
            {
                pages.Add(path);
            }
        }
        string? start = options.Get("start") as string;
        string? end = options.Get("end") as string;
        var through = options.Get("through") as JsObject;
        var sequences = new List<List<string>>();
        // Visits that went on past the last step shown, so they never count as having gone no further.
        var cut = new List<bool>();
        foreach (var all in order)
        {
            var pages = all;
            if (!string.IsNullOrEmpty(start))
            {
                int at = pages.IndexOf(start);
                if (at < 0)
                {
                    continue;
                }
                pages = pages[at..];
            }
            if (!string.IsNullOrEmpty(end))
            {
                int at = pages.IndexOf(end);
                if (at < 0)
                {
                    continue;
                }
                pages = pages[..(at + 1)];
            }
            bool more = pages.Count > steps;
            pages = pages.Take(steps).ToList();
            if (through != null && !Equals(At(pages, through.Prop("step")), through.Prop("value")))
            {
                continue;
            }
            cut.Add(more);
            sequences.Add(pages);
        }

        var columns = new List<object?>();
        var kept = new List<HashSet<string>>();
        for (int i = 0; i < steps; i++)
        {
            var counts = new Dictionary<string, long>(StringComparer.Ordinal);
            var seen = new List<string>();
            long reached = 0;
            long left = 0;
            for (int n = 0; n < sequences.Count; n++)
            {
                var s = sequences[n];
                if (s.Count <= i)
                {
                    continue;
                }
                reached++;
                if (s.Count == i + 1 && !cut[n])
                {
                    left++;
                }
                if (!counts.TryGetValue(s[i], out long c))
                {
                    seen.Add(s[i]);
                }
                counts[s[i]] = c + 1;
            }
            var sorted = seen.Select(p => (Page: p, Count: counts[p])).OrderByDescending(e => e.Count).ThenBy(e => e.Page, StringComparer.Ordinal).ToList();
            var top = sorted.Take(Top).ToList();
            long rest = sorted.Skip(Top).Sum(e => e.Count);
            kept.Add(top.Select(e => e.Page).ToHashSet(StringComparer.Ordinal));
            if (reached == 0)
            {
                break;
            }
            var items = top.Select(e => (object?)new JsObject { ["value"] = e.Page, ["visits"] = e.Count }).ToList();
            if (rest != 0)
            {
                items.Add(new JsObject { ["value"] = "", ["visits"] = rest });
            }
            columns.Add(new JsObject { ["items"] = items, ["visits"] = reached, ["left"] = left });
        }

        var linkCounts = new Dictionary<(int, string, string), JsObject>();
        var links = new List<JsObject>();
        foreach (var s in sequences)
        {
            for (int i = 0; i + 1 < s.Count && i + 1 < columns.Count; i++)
            {
                string from = kept[i].Contains(s[i]) ? s[i] : "";
                string to = kept[i + 1].Contains(s[i + 1]) ? s[i + 1] : "";
                if (!linkCounts.TryGetValue((i, from, to), out var link))
                {
                    link = new JsObject { ["step"] = (long)i, ["from"] = from, ["to"] = to, ["visits"] = 0L };
                    linkCounts[(i, from, to)] = link;
                    links.Add(link);
                }
                link["visits"] = (long)link["visits"]! + 1;
            }
        }
        // Ties go by page, as the columns and paths do, so the order never follows the visits' random ids.
        links = links
            .OrderBy(l => (long)l["step"]!)
            .ThenByDescending(l => (long)l["visits"]!)
            .ThenBy(l => (string)l["from"]!, StringComparer.Ordinal)
            .ThenBy(l => (string)l["to"]!, StringComparer.Ordinal)
            .ToList();

        var pathCounts = new Dictionary<string, (List<string> Pages, long Visits)>(StringComparer.Ordinal);
        var pathOrder = new List<string>();
        foreach (var s in sequences)
        {
            string key = string.Join('\0', s);
            if (pathCounts.TryGetValue(key, out var entry))
            {
                pathCounts[key] = (entry.Pages, entry.Visits + 1);
            }
            else
            {
                pathCounts[key] = (s, 1);
                pathOrder.Add(key);
            }
        }
        var paths = pathOrder
            .OrderByDescending(k => pathCounts[k].Visits)
            .ThenBy(k => k, StringComparer.Ordinal)
            .Take(20)
            .Select(k => (object?)new JsObject { ["pages"] = pathCounts[k].Pages.Cast<object?>().ToList(), ["visits"] = pathCounts[k].Visits })
            .ToList();

        return new JsObject
        {
            ["visits"] = (long)sequences.Count,
            ["columns"] = columns,
            ["links"] = links.Cast<object?>().ToList(),
            ["paths"] = paths,
        };
    }

    /// <summary>pages[step], which is undefined for a step that is not a whole number in range.</summary>
    private static object? At(List<string> pages, object? step)
    {
        double n = Js.Num(step);
        if (!Js.IsInteger(n) || n < 0 || n >= pages.Count)
        {
            return Undefined.Value;
        }
        return pages[(int)n];
    }
}
