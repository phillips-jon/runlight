using System;
using System.Globalization;
using System.Runtime.CompilerServices;

namespace Runlight.Tests;

/// <summary>
/// Runs the suite under the culture RUNLIGHT_CULTURE names (CI uses tr-TR, which writes 1,5 and
/// folds I to a dotless i), so a format or comparison that reads the culture fails.
/// </summary>
internal static class CultureSetup
{
    [ModuleInitializer]
    internal static void Init()
    {
        string? name = Environment.GetEnvironmentVariable("RUNLIGHT_CULTURE");
        if (!string.IsNullOrEmpty(name))
        {
            var culture = CultureInfo.GetCultureInfo(name);
            CultureInfo.DefaultThreadCurrentCulture = culture;
            CultureInfo.DefaultThreadCurrentUICulture = culture;
            CultureInfo.CurrentCulture = culture;
        }
    }
}
