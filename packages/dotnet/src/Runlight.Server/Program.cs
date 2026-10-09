using System;
using System.IO;
using System.Threading.Tasks;
using Microsoft.Data.Sqlite;
using MySqlConnector;
using Npgsql;
using Runlight.AspNetCore;
using Runlight.Server;
using Runlight.Store;

namespace Runlight.ServerTool;

/// <summary>
/// The runlight tool: the standalone server and its commands, with every database driver Runlight reads, so
/// DATABASE_URL picks Postgres, MySQL, or MariaDB, and SQLite is the default.
/// </summary>
public static class Program
{
    public static Task<int> Main(string[] args) => Cli.RunAsync(
        args,
        Directory.GetCurrentDirectory(),
        openStore: Open,
        serve: (config, server, output) => StandaloneHost.RunAsync(config, server, output));

    /// <summary>The store DATABASE_URL names, or the SQLite file in the data folder when it is unset.</summary>
    public static SqlStore Open(string? url, string sqlite)
    {
        if (url == null)
        {
            return Stores.Sqlite(SqliteFactory.Instance, sqlite);
        }
        // The Node server's stores stop any one statement after two minutes.
        return DatabaseUrl.Kind(url) switch
        {
            "postgres" => Stores.Postgres(NpgsqlDataSource.Create(DatabaseUrl.Postgres(url)), 120_000),
            "mysql" => Stores.MySql(new MySqlDataSource(DatabaseUrl.MySql(url)), 120_000),
            _ => throw new InvalidOperationException("set DATABASE_URL to a postgres://, mysql://, or mariadb:// address, or leave it unset for SQLite"),
        };
    }
}
