using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using Xunit;
using static Runlight.Tests.Fixtures;

namespace Runlight.Tests;

/// <summary>
/// Goals and funnels checked from the dashboard against fixtures/goals.json, and journeys as
/// journeys.test.ts tests them and against fixtures/journeys.json.
/// </summary>
public sealed class GoalsJourneysTests
{
    /// <summary>The answer as the fixture writes it: the row with a new id as "&lt;random&gt;", or the error.</summary>
    private static string Outcome(Func<JsObject> fn, bool fresh)
    {
        try
        {
            var value = fn();
            if (fresh && Regex.IsMatch(value.Str("id") ?? "", "^[0-9a-f]{24}\\z"))
            {
                value["id"] = "<random>";
            }
            return J(new JsObject { ["value"] = value });
        }
        catch (GoalError e)
        {
            return J(new JsObject { ["error"] = new JsObject { ["message"] = e.Message, ["code"] = e.Code, ["params"] = e.Params } });
        }
        catch (FunnelError e)
        {
            return J(new JsObject { ["error"] = new JsObject { ["message"] = e.Message, ["code"] = e.Code, ["params"] = e.Params } });
        }
    }

    [Fact]
    public void Goals_are_checked_as_the_TypeScript_SDK_checks_them()
    {
        var fixture = Load("goals");
        var existing = fixture.Arr("existing")!.Cast<JsObject>().ToList();
        var cases = fixture.Arr("goals")!.Cast<JsObject>().ToList();
        Assert.True(cases.Count > 50);
        var failures = new List<string>();
        for (int i = 0; i < cases.Count; i++)
        {
            var c = cases[i];
            string? id = c.Str("id");
            string got = Outcome(() => Goals.GoalFrom(c.Obj("input")!, "s", existing, 1000, id), id == null);
            if (got != J(c.Get("result")))
            {
                failures.Add("#" + i + " " + J(c.Get("input")) + ": " + got + ", want " + J(c.Get("result")));
            }
        }
        NoFailures(failures);
    }

    [Fact]
    public void Funnels_are_checked_as_the_TypeScript_SDK_checks_them()
    {
        var fixture = Load("goals");
        var existing = fixture.Arr("existingFunnels")!.Cast<JsObject>().ToList();
        var failures = new List<string>();
        var cases = fixture.Arr("funnels")!.Cast<JsObject>().ToList();
        for (int i = 0; i < cases.Count; i++)
        {
            var c = cases[i];
            string? id = c.Str("id");
            string got = Outcome(() => Funnels.FunnelFrom(c.Obj("input")!, "s", existing, 1000, id), id == null);
            if (got != J(c.Get("result")))
            {
                failures.Add("#" + i + " " + J(c.Get("input")) + ": " + got + ", want " + J(c.Get("result")));
            }
        }
        NoFailures(failures);
    }

    [Fact]
    public void Page_patterns_and_click_rules()
    {
        var fixture = Load("goals");
        foreach (JsObject c in fixture.Arr("patterns")!)
        {
            Assert.Equal(c.Str("result"), Goals.PagePattern(c.Str("input")!));
        }
        static JsObject Goal(string id, JsObject g) => new JsObject
        {
            ["id"] = id,
            ["site"] = "s",
            ["name"] = id,
            ["kind"] = "event",
            ["match"] = id,
            ["clickBy"] = "",
            ["valueMode"] = "none",
            ["value"] = 0L,
            ["valueProp"] = "",
            ["currency"] = "USD",
            ["createdAt"] = 5L,
        }.With(g);
        static JsObject Site(string id, string name, params string[] hosts) =>
            new() { ["id"] = id, ["name"] = name, ["hostnames"] = hosts.Cast<object?>().ToList(), ["timezone"] = "UTC" };
        var rules = Goals.ClickRules(
            [Site("s", "S", "www.example.com", "shop.example.com"), Site("t", "T"), Site("u", "U", "u.example")],
            [
                Goal(new string('c', 24), new JsObject { ["name"] = "Buy", ["kind"] = "click", ["match"] = ".buy", ["clickBy"] = "selector" }),
                Goal(new string('d', 24), new JsObject { ["name"] = "Out", ["kind"] = "click", ["match"] = "https://x.example/*", ["clickBy"] = "link", ["site"] = "t" }),
                Goal(new string('e', 24), new JsObject { ["name"] = "E", ["site"] = "u" }),
            ]);
        Assert.Equal(J(fixture.Get("rules")), J(rules));
    }

    [Fact]
    public void Goal_checks_say_what_is_wrong()
    {
        var made = Goals.GoalFrom(new JsObject { ["name"] = "X", ["kind"] = "event", ["match"] = "X" }, "default", [], 1);
        var codes = new List<string>();
        foreach (var (input, existing) in new (JsObject, List<JsObject>)[]
        {
            (new JsObject { ["name"] = "x", ["kind"] = "event", ["match"] = "Y" }, [made]),
            (new JsObject { ["name"] = "Y", ["kind"] = "event", ["match"] = "Y", ["currency"] = "dollars" }, []),
            (new JsObject { ["name"] = "Z", ["kind"] = "event", ["match"] = "Z", ["valueMode"] = "fixed", ["value"] = -1L }, []),
            (new JsObject { ["name"] = "W", ["kind"] = "event", ["match"] = "W", ["valueMode"] = "prop", ["valueProp"] = "a b" }, []),
            (new JsObject { ["name"] = "P", ["kind"] = "page", ["match"] = "/p", ["valueMode"] = "prop" }, []),
        })
        {
            try
            {
                Goals.GoalFrom(input, "default", existing, 1);
                codes.Add("none");
            }
            catch (GoalError e)
            {
                codes.Add(e.Code);
            }
        }
        Assert.Equal(["goal_exists", "goal_currency", "goal_amount", "goal_prop_name", "goal_prop_kind"], codes);
        var renamed = Goals.GoalFrom(new JsObject { ["name"] = "Renamed", ["kind"] = "event", ["match"] = "X" }, "default", [made], 99, made.Str("id"));
        Assert.Equal(made.Str("id"), renamed.Str("id"));
        Assert.Equal(1L, renamed.Get("createdAt"));
    }

    private static List<JsObject> Rows(params (string Session, string[] Pages)[] visits) =>
        visits.SelectMany(v => v.Pages.Select(p => new JsObject { ["session"] = v.Session, ["path"] = p })).ToList();

    private static JsObject Item(string value, long visits) => new() { ["value"] = value, ["visits"] = visits };

    [Fact]
    public void Journeys_line_paths_up_by_step_with_flows_and_follow_a_start_an_end_and_one_page()
    {
        var data = Rows(
            ("a", ["/", "/pricing", "/signup"]),
            ("b", ["/", "/pricing", "/pricing", "/docs"]),
            ("c", ["/", "/blog"]),
            ("d", ["/blog", "/", "/pricing"]),
            ("e", ["/docs"]));
        var all = Journeys.Of(data, new JsObject { ["steps"] = 3L });
        Assert.Equal(5L, all.Get("visits"));
        var columns = all.Arr("columns")!.Cast<JsObject>().ToList();
        Assert.Equal(J(new JsObject { ["items"] = new List<object?> { Item("/", 3), Item("/blog", 1), Item("/docs", 1) }, ["visits"] = 5L, ["left"] = 1L }), J(columns[0]));
        Assert.Equal(J(Item("/pricing", 2)), J(columns[1].Arr("items")![0])); // a refresh counts once
        var fromHome = all.Arr("links")!.Cast<JsObject>().Where(l => (long)l["step"]! == 0 && l.Str("from") == "/").Select(l => l.Str("to") + " " + Js.String(l.Get("visits"))).ToList();
        Assert.Equal(["/pricing 2", "/blog 1"], fromHome);
        Assert.Equal(5, all.Arr("paths")!.Count);
        // With two steps, visits a, b, and d go on to a third page, so only c went no further than step two.
        var two = Journeys.Of(data, new JsObject { ["steps"] = 2L });
        var second = (JsObject)two.Arr("columns")![1]!;
        Assert.Equal((4L, 1L), ((long)second["visits"]!, (long)second["left"]!));
        Assert.Equal(J(new JsObject { ["pages"] = new List<object?> { "/", "/blog" }, ["visits"] = 1L }), J(all.Arr("paths")![0])); // ties in a fixed order

        var fromPricing = Journeys.Of(data, new JsObject { ["steps"] = 3L, ["start"] = "/pricing" });
        Assert.Equal(3L, fromPricing.Get("visits"));
        Assert.Equal(J(new List<object?> { Item("/pricing", 3) }), J(((JsObject)fromPricing.Arr("columns")![0]!).Get("items")));

        var toSignup = Journeys.Of(data, new JsObject { ["steps"] = 4L, ["end"] = "/signup" });
        Assert.Equal(J(new List<object?> { new JsObject { ["pages"] = new List<object?> { "/", "/pricing", "/signup" }, ["visits"] = 1L } }), J(toSignup.Get("paths")));

        var through = Journeys.Of(data, new JsObject { ["steps"] = 3L, ["through"] = new JsObject { ["step"] = 1L, ["value"] = "/blog" } });
        Assert.Equal(1L, through.Get("visits"));
    }

    [Fact]
    public void Journey_fixtures_match()
    {
        var fixture = Load("journeys");
        var datasets = fixture.Arr("datasets")!;
        var failures = new List<string>();
        foreach (JsObject run in fixture.Arr("runs")!)
        {
            var options = run.Obj("options")!.Clone();
            if (options.Get("steps") is "NaN")
            {
                options["steps"] = double.NaN;
            }
            var rows = ((List<object?>)datasets[(int)run.Num("dataset")]!).Cast<JsObject>();
            string got = J(Journeys.Of(rows, options));
            if (got != J(run.Get("result")))
            {
                failures.Add("dataset " + Js.String(run.Get("dataset")) + " with " + J(run.Get("options")) + ": " + got);
            }
        }
        NoFailures(failures);
    }
}
