using System;
using System.Collections.Generic;
using System.Linq;

namespace Runlight.Tests.ConformanceRunner;

/// <summary>conformance/http.json, read once, with objects as JsObject so {} and [] stay apart.</summary>
public static class Scenarios
{
    public static JsObject File() => Fixtures.Conformance("http");

    public static List<JsObject> All() => File().Arr("scenarios")!.Cast<JsObject>().ToList();

    public static JsObject Named(string name) =>
        All().FirstOrDefault(s => s.Str("name") == name) ?? throw new ArgumentException("No scenario is named " + name);
}
