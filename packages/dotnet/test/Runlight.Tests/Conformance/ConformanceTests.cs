using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Xunit;

namespace Runlight.Tests.ConformanceRunner;

/// <summary>
/// Replays conformance/http.json against the .NET core on every store, as http-conformance.test.ts does
/// against the TypeScript one: each step's answer must equal the one the file holds.
/// </summary>
public sealed class ConformanceTests : IAsyncLifetime
{
    public static TheoryData<string, string> ScenarioData()
    {
        var data = new TheoryData<string, string>();
        foreach (string kind in Databases.Kinds())
        {
            foreach (var scenario in Scenarios.All())
            {
                data.Add(kind, scenario.Str("name")!);
            }
        }
        return data;
    }

    public ValueTask InitializeAsync() => ValueTask.CompletedTask;

    public async ValueTask DisposeAsync() => await Databases.CleanupAsync();

    [Theory]
    [MemberData(nameof(ScenarioData))]
    public async Task Scenario(string kind, string name)
    {
        var scenario = Scenarios.Named(name);
        var store = await TestStores.StoreAsync(kind);
        var answers = await new Player().PlayAsync(scenario, options => new CoreTarget(options), store);
        AssertAnswers(scenario, answers, kind);
    }

    /// <summary>
    /// Compares answer by answer and fails on the first that differs, with the two side by side and the
    /// scenario, step, method, and path it belongs to.
    /// </summary>
    internal static void AssertAnswers(JsObject scenario, List<JsObject> answers, string kind = "fake")
    {
        var steps = scenario.Arr("steps")!.Cast<JsObject>().ToList();
        var differ = new List<int>();
        for (int i = 0; i < steps.Count; i++)
        {
            if (Normalizer.Canonical(steps[i].Get("expect")) != Normalizer.Canonical(i < answers.Count ? answers[i] : null))
            {
                differ.Add(i);
            }
        }
        string name = scenario.Str("name")!;
        Assert.True(steps.Count == answers.Count, $"{name} ({kind}): one answer for each step");
        if (differ.Count == 0)
        {
            return;
        }
        int at = differ[0];
        var step = steps[at];
        string others = differ.Count > 1 ? " Steps " + string.Join(", ", differ.Skip(1).Select(n => n + 1)) + " differ too." : "";
        Assert.Fail(
            $"{name} ({kind}): step {at + 1}, {step.Str("method")} {step.Str("path")} answered differently.{others}\n"
            + "expected:\n" + Normalizer.Canonical(step.Get("expect")) + "\nactual:\n" + Normalizer.Canonical(answers[at]));
    }
}
