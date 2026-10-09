using System;
using System.Data.Common;
using Runlight.Db;

namespace Runlight.Store;

/// <summary>
/// The stores stores/sqlite.ts, stores/postgres.ts, and stores/mysql.ts make, over ADO.NET. Tables
/// are prefixed <c>rl_</c>, so the database can be the app's own, and a database made by the
/// TypeScript SDK or the PHP package opens here. No database driver is a dependency of this
/// package: the app hands over a <see cref="DbDataSource"/> from its own (Microsoft.Data.Sqlite,
/// Npgsql, or MySqlConnector), and Runlight shares its pool.
/// </summary>
public static class Stores
{
    /// <summary>Runlight's tables in a SQLite database, in WAL mode, as better-sqlite3 opens it.</summary>
    public static SqlStore Sqlite(DbDataSource source) => new(new AdoDb(source, "sqlite"));

    /// <summary>
    /// Runlight's tables in a SQLite file (or ":memory:"), from Microsoft.Data.Sqlite's factory
    /// (<c>SqliteFactory.Instance</c>). A file in a folder that is not there yet gets the folder.
    /// </summary>
    public static SqlStore Sqlite(DbProviderFactory factory, string path)
    {
        if (path.Length > 0 && path != ":memory:" && !path.StartsWith("file:", StringComparison.Ordinal))
        {
            string? dir = System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(path));
            if (dir != null)
            {
                System.IO.Directory.CreateDirectory(dir);
            }
        }
        var builder = factory.CreateConnectionStringBuilder() ?? new DbConnectionStringBuilder();
        builder["Data Source"] = path;
        // better-sqlite3 waits up to five seconds for a lock.
        builder["Default Timeout"] = 5;
        return new SqlStore(new AdoDb(factory.CreateDataSource(builder.ConnectionString), "sqlite", owned: true));
    }

    /// <summary>
    /// Runlight's tables in Postgres, over Npgsql's data source. <paramref name="statementTimeout"/> stops
    /// any one statement after that many milliseconds; 0 (the default, for a pool the app keeps) leaves
    /// the server's own.
    /// </summary>
    public static SqlStore Postgres(DbDataSource source, int statementTimeout = 0) => new(new AdoDb(source, "postgres", statementTimeout: statementTimeout));

    /// <summary>
    /// Runlight's tables in MySQL 8.4 or MariaDB 11.4 and later, over MySqlConnector's data source.
    /// Text is utf8mb4 with a binary collation, so it compares and sorts by code point, case and
    /// trailing spaces included, as SQLite and Postgres do.
    /// </summary>
    public static SqlStore MySql(DbDataSource source, int statementTimeout = 0) => new(new AdoDb(source, "mysql", statementTimeout: statementTimeout));

    /// <summary>The store for a data source, its database read from the type of its connections.</summary>
    public static SqlStore For(DbDataSource source) => new(new AdoDb(source, AdoDb.DialectOf(source)));

    /// <summary>A store over any <see cref="IDb"/>.</summary>
    public static SqlStore FromDb(IDb db) => new(db);

    /// <summary>SQL written for SQLite and Postgres as MySQL and MariaDB read it, each <c>?</c> filled in as mysql2 escapes it.</summary>
    public static string MysqlText(string sql, System.Collections.Generic.IReadOnlyList<object?>? args = null, Func<object?, string>? escape = null) =>
        AdoDb.MysqlText(sql, args, escape);
}
