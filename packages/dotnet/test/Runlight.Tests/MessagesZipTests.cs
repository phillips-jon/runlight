using System;
using System.Collections.Generic;
using System.Linq;
using Xunit;
using static Runlight.Tests.Fixtures;

namespace Runlight.Tests;

/// <summary>
/// The translator against fixtures/messages.json (Intl.PluralRules' forms and the TypeScript's
/// words), and CSV and ZIP output against fixtures/zip.json, byte for byte as the TypeScript SDK
/// writes them.
/// </summary>
public sealed class MessagesZipTests
{
    [Fact]
    public void Languages()
    {
        Assert.Equal(J(Load("messages").Get("languages")), J(Messages.Languages().Cast<object?>().ToList()));
    }

    [Fact]
    public void Plural_forms_match_Intl()
    {
        var fixture = Load("messages");
        // NaN and the infinities come as text, and so do whole numbers too long to write exactly.
        var numbers = fixture.Arr("numbers")!.Select(n => n is string s ? Js.Number(s) : Js.Num(n)).ToList();
        var failures = new List<string>();
        foreach (var (lang, forms) in fixture.Obj("plural")!)
        {
            var list = (List<object?>)forms!;
            for (int i = 0; i < numbers.Count; i++)
            {
                string got = Messages.Plural(lang, numbers[i]);
                if (got != (string)list[i]!)
                {
                    failures.Add(lang + " " + Label(fixture.Arr("numbers")![i]) + ": " + got + ", want " + list[i]);
                }
            }
        }
        NoFailures(failures);
    }

    [Fact]
    public void Words_match()
    {
        foreach (JsObject set in Load("messages").Arr("words")!)
        {
            var words = Messages.Translator(set.Str("lang")!);
            Assert.Equal(set.Str("code"), words.Lang);
            foreach (JsObject c in set.Arr("t")!)
            {
                Assert.Equal(c.Str("text"), words.T(c.Str("key")!, c.Obj("vars")));
            }
            foreach (JsObject c in set.Arr("tn")!)
            {
                double n = c.Num("n");
                Assert.Equal(c.Str("text"), words.Tn(c.Str("key")!, n, new JsObject { ["n"] = c.Get("n"), ["name"] = "x" }));
            }
        }
    }

    [Fact]
    public void French_counts_zero_as_one()
    {
        Assert.Equal("one", Messages.Plural("fr", 0));
        Assert.Equal("one", Messages.Plural("fr", 1.5));
        Assert.Equal("many", Messages.Plural("fr", 1_000_000));
        Assert.Equal("other", Messages.Plural("en", 0));
    }

    /// <summary>A cell back from its fixture form: {"js": "NaN"} and the like become the values JSON cannot carry.</summary>
    private static object? Cell(object? cell)
    {
        if (cell is JsObject o && o.Count == 1 && o.Has("js"))
        {
            return o.Str("js") switch
            {
                "undefined" => Undefined.Value,
                "NaN" => double.NaN,
                "Infinity" => double.PositiveInfinity,
                "-Infinity" => double.NegativeInfinity,
                "-0" => -0.0,
                _ => throw new InvalidOperationException(o.Str("js")),
            };
        }
        return cell is List<object?> list ? list.Select(Cell).ToList() : cell;
    }

    [Fact]
    public void Spreadsheet_formulas_are_defused()
    {
        Assert.Equal("'=SUM(A1),'+1,-2,\"a,b\",\"say \"\"hi\"\"\",12", Zip.CsvRow(["=SUM(A1)", "+1", "-2", "a,b", "say \"hi\"", 12L]));
    }

    [Fact]
    public void Rows()
    {
        foreach (JsObject c in Load("zip").Arr("rows")!)
        {
            Assert.Equal(c.Str("row"), Zip.CsvRow([Cell(c.Get("cell"))]));
        }
    }

    [Fact]
    public void Csvs()
    {
        foreach (JsObject c in Load("zip").Arr("csvs")!)
        {
            var rows = c.Arr("rows")!.Select(r => ((List<object?>)r!).Select(Cell).ToList()).ToList();
            Assert.Equal(c.Str("csv"), Zip.Csv(c.Arr("header")!.Cast<string>(), rows));
        }
    }

    [Fact]
    public void Zips()
    {
        foreach (JsObject c in Load("zip").Arr("zips")!)
        {
            var files = c.Arr("files")!.Cast<JsObject>().Select(f => (f.Str("name")!, f.Str("text")!));
            Assert.Equal(c.Str("base64"), Convert.ToBase64String(Zip.Archive(files, (long)c.Num("now"))));
        }
    }

    [Fact]
    public void A_zip_starts_like_one()
    {
        byte[] bytes = Zip.Archive([("overview.csv", "a\r\n")], 0);
        Assert.Equal("PK\x03\x04", Js.Decode(bytes.AsSpan(0, 4)));
        Assert.Contains("overview.csv", Js.Decode(bytes), StringComparison.Ordinal);
    }
}
