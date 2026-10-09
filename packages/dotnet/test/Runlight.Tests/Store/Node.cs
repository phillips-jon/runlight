using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace Runlight.Tests.Store;

/// <summary>Runs scripts/php-fixtures-store.mts with the TypeScript SDK, when node is at hand.</summary>
public static class Node
{
    /// <summary>node 22 or later on the PATH (or RUNLIGHT_NODE), with tsx installed at the repository root.</summary>
    public static string? Binary()
    {
        if (!Directory.Exists(Path.Combine(Fixtures.Root, "node_modules", "tsx")))
        {
            return null;
        }
        foreach (string? node in new[] { Environment.GetEnvironmentVariable("RUNLIGHT_NODE"), "node" }.Where(n => !string.IsNullOrEmpty(n)))
        {
            try
            {
                using var process = Process.Start(new ProcessStartInfo(node!, "--version") { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false });
                if (process == null)
                {
                    continue;
                }
                string version = process.StandardOutput.ReadToEnd().Trim();
                process.WaitForExit();
                var m = Regex.Match(version, "^v([0-9]+)\\.");
                if (m.Success && int.Parse(m.Groups[1].Value) >= 22)
                {
                    return node;
                }
            }
            catch (System.ComponentModel.Win32Exception)
            {
                // Not there.
            }
        }
        return null;
    }

    /// <summary>The script with these arguments: its exit status, what it wrote, and what it said on stderr.</summary>
    public static async Task<(int Status, string Out, string Err)> StoreAsync(string node, params string[] args)
    {
        var info = new ProcessStartInfo(node) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, WorkingDirectory = Fixtures.Root };
        foreach (string arg in new[] { "--import", "tsx", "scripts/php-fixtures-store.mts" }.Concat(args))
        {
            info.ArgumentList.Add(arg);
        }
        using var process = Process.Start(info);
        if (process == null)
        {
            return (-1, "", "node did not start");
        }
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();
        return (process.ExitCode, await output, await error);
    }
}
