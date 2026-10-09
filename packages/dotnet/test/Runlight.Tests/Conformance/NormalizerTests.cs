using Xunit;

namespace Runlight.Tests.ConformanceRunner;

/// <summary>The normalizer against cases run through normalize() in http-conformance.ts (tests/fixtures/conformance-normalize.json).</summary>
public sealed class NormalizerTests
{
    [Fact]
    public void Normalizes_as_TypeScript_does()
    {
        var cases = (System.Collections.Generic.List<object?>)Json.Parse(System.IO.File.ReadAllText(Fixtures.FixturePath("conformance-normalize.json")))!;
        Assert.NotEmpty(cases);
        var failures = new System.Collections.Generic.List<string>();
        for (int i = 0; i < cases.Count; i++)
        {
            var c = (JsObject)cases[i]!;
            string expected = Normalizer.Canonical(c.Get("output"));
            string actual = Normalizer.Canonical(Normalizer.Normalize(c.Get("input")));
            if (expected != actual)
            {
                failures.Add("case " + (i + 1) + ": " + Fixtures.Label(c.Get("input")) + " gave " + Fixtures.Label(actual));
            }
        }
        Fixtures.NoFailures(failures);
    }

    [Fact]
    public void Keeps_objects_and_arrays_apart()
    {
        Assert.Equal("{\"a\":{},\"b\":[]}", Json.Stringify(Normalizer.Normalize(new JsObject { ["a"] = new JsObject(), ["b"] = new System.Collections.Generic.List<object?>() })));
    }

    [Fact]
    public void Cookie_shape()
    {
        Assert.Equal("rl_session=<value>; Path=/; HttpOnly", Normalizer.CookieShape("rl_session=abc123; Path=/; HttpOnly"));
        Assert.Equal("rl_session=; Path=/; Max-Age=0", Normalizer.CookieShape("rl_session=; Path=/; Max-Age=0"));
        Assert.Equal("a=<value>", Normalizer.CookieShape("a=b=c"));
        Assert.Equal("no value here", Normalizer.CookieShape("no value here"));
        Assert.Equal("=x; Path=/", Normalizer.CookieShape("=x; Path=/"));
    }

    [Fact]
    public void Canonical_ignores_key_order_and_number_form()
    {
        Assert.Equal(
            Normalizer.Canonical(Json.Parse("{\"b\":1,\"a\":[{\"y\":2.0,\"x\":null}]}")),
            Normalizer.Canonical(Json.Parse("{\"a\":[{\"x\":null,\"y\":2}],\"b\":1.0}")));
        Assert.NotEqual(Normalizer.Canonical(Json.Parse("{\"a\":{}}")), Normalizer.Canonical(Json.Parse("{\"a\":[]}")));
        Assert.NotEqual(Normalizer.Canonical(Json.Parse("[1,2]")), Normalizer.Canonical(Json.Parse("[2,1]")));
    }
}
