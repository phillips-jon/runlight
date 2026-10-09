using System;
using System.Data.Common;
using System.Globalization;
using System.Text.RegularExpressions;

namespace Runlight.Server;

/// <summary>
/// DATABASE_URL as the drivers' connection strings: a postgres:// URL as Npgsql reads one, and a mysql:// or
/// mariadb:// URL as MySqlConnector reads one, the way node-postgres and mysql2 read the same URL in the Node server.
/// Only the parts written as text are read here, so the Runlight package needs neither driver.
/// </summary>
public static partial class DatabaseUrl
{
    [GeneratedRegex("^postgres(ql)?://", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex PostgresScheme();

    [GeneratedRegex("^(mysql|mariadb)://", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex MysqlScheme();

    /// <summary>Which database a URL names: "postgres", "mysql", or null for neither.</summary>
    public static string? Kind(string url)
    {
        ArgumentNullException.ThrowIfNull(url);
        return PostgresScheme().IsMatch(url) ? "postgres" : MysqlScheme().IsMatch(url) ? "mysql" : null;
    }

    /// <summary>A postgres:// URL as an Npgsql connection string. <c>?sslmode=</c> carries over.</summary>
    public static string Postgres(string url)
    {
        var uri = Parse(url);
        var b = new DbConnectionStringBuilder
        {
            ["Host"] = uri.Host.Trim('[', ']'),
            ["Port"] = (uri.Port > 0 ? uri.Port : 5432).ToString(CultureInfo.InvariantCulture),
        };
        string database = Uri.UnescapeDataString(uri.AbsolutePath.TrimStart('/'));
        if (database.Length > 0)
        {
            b["Database"] = database;
        }
        User(uri, b, "Username");
        foreach (var (name, value) in new Http.SearchParams(uri.Query.TrimStart('?')))
        {
            if (name == "sslmode")
            {
                b["SSL Mode"] = Js.Lower(value) switch
                {
                    "disable" => "Disable",
                    "allow" => "Allow",
                    "prefer" => "Prefer",
                    "require" or "no-verify" => "Require",
                    "verify-ca" => "VerifyCA",
                    "verify-full" => "VerifyFull",
                    _ => throw new ArgumentException("Runlight: sslmode " + value + " is not one Postgres knows"),
                };
            }
        }
        return b.ConnectionString;
    }

    /// <summary>A mysql:// or mariadb:// URL as a MySqlConnector connection string, in utf8mb4.</summary>
    public static string MySql(string url)
    {
        var uri = Parse(url);
        var b = new DbConnectionStringBuilder
        {
            ["Server"] = uri.Host.Trim('[', ']'),
            ["Port"] = (uri.Port > 0 ? uri.Port : 3306).ToString(CultureInfo.InvariantCulture),
            ["Database"] = Uri.UnescapeDataString(uri.AbsolutePath.TrimStart('/')),
            ["Character Set"] = "utf8mb4",
            ["Allow User Variables"] = "true",
        };
        User(uri, b, "User ID");
        return b.ConnectionString;
    }

    private static Uri Parse(string url)
    {
        ArgumentNullException.ThrowIfNull(url);
        // Uri knows neither scheme's default port, so each is read as a URL of its own kind.
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Host.Length == 0)
        {
            throw new ArgumentException("Runlight: DATABASE_URL is not a URL, such as postgres://user:password@localhost:5432/runlight");
        }
        return uri;
    }

    private static void User(Uri uri, DbConnectionStringBuilder b, string key)
    {
        if (uri.UserInfo.Length == 0)
        {
            return;
        }
        string[] user = uri.UserInfo.Split(':', 2);
        if (user[0].Length > 0)
        {
            b[key] = Uri.UnescapeDataString(user[0]);
        }
        if (user.Length > 1)
        {
            b["Password"] = Uri.UnescapeDataString(user[1]);
        }
    }
}
