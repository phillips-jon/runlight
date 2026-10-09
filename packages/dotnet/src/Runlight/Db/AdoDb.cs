using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Data;
using System.Data.Common;
using System.Globalization;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace Runlight.Db;

/// <summary>
/// An <see cref="IDb"/> over an ADO.NET <see cref="DbDataSource"/>, for SQLite
/// (Microsoft.Data.Sqlite), Postgres (Npgsql), and MySQL or MariaDB (MySqlConnector), doing per
/// connection what the TypeScript drivers do (stores/sqlite.ts, stores/postgres.ts, and
/// stores/mysql.ts). No driver is a dependency: the app's data source brings its own.
/// </summary>
/// <remarks>
/// SQL is written for SQLite and Postgres with <c>?</c> placeholders. SQLite numbers them
/// (<c>?1</c>), Postgres takes <c>$1</c> with every value sent as untyped text, as node-postgres
/// sends it, so the server reads each by where it stands. On MySQL each statement goes through
/// <see cref="MysqlText"/> first: a "quoted" name in backticks, and a backslash inside 'text'
/// doubled, since MySQL reads it as an escape where standard SQL takes it literally.
///
/// SQLite is one connection, kept open and used by one statement at a time, as better-sqlite3 is
/// in the SDK. Postgres and MySQL take a connection from the data source's pool for each
/// statement, and hold one for a transaction or a lock. A transaction is joined, not nested, by
/// anything the code inside it runs.
/// </remarks>
public sealed class AdoDb : IDb
{
    /// <summary>Arbitrary but fixed, so every Runlight process takes the same lock to create tables.</summary>
    public const long MigrationLock = 7_331_906;

    /// <summary>One lock per MySQL database, so installs sharing a server do not wait on each other.</summary>
    private const string MysqlLock = "CONCAT('runlight:', LEFT(SHA2(COALESCE(DATABASE(), ''), 256), 48))";

    private readonly DbDataSource _source;
    private readonly bool _owned;
    private readonly int _statementTimeout;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly AsyncLocal<Scope?> _scope = new();
    private readonly ConcurrentDictionary<string, string> _texts = new(StringComparer.Ordinal);
    private DbConnection? _sqlite;
    private bool? _mariadb;
    private bool _closed;

    private sealed class Scope(DbConnection connection)
    {
        public DbConnection Connection { get; } = connection;

        public DbTransaction? Transaction { get; set; }
    }

    /// <param name="source">The database's data source.</param>
    /// <param name="dialect">"sqlite", "postgres", or "mysql".</param>
    /// <param name="owned">Whether closing this closes the data source too (never one the app keeps using).</param>
    /// <param name="statementTimeout">
    /// Postgres and MySQL: the longest one statement may run, in milliseconds, set on each connection
    /// as it is taken; 0 (the default) leaves the server's own.
    /// </param>
    public AdoDb(DbDataSource source, string dialect, bool owned = false, int statementTimeout = 0)
    {
        if (dialect is not ("sqlite" or "postgres" or "mysql"))
        {
            throw new ArgumentException("Runlight: unknown database dialect " + dialect);
        }
        _source = source;
        Dialect = dialect;
        _owned = owned;
        _statementTimeout = statementTimeout;
    }

    public string Dialect { get; }

    /// <summary>The dialect a data source's connections speak, read from their type's name.</summary>
    public static string DialectOf(DbDataSource source)
    {
        string name = source.GetType().FullName ?? "";
        using var connection = source.CreateConnection();
        string type = connection.GetType().Name;
        if (type.Contains("Sqlite", StringComparison.OrdinalIgnoreCase) || name.Contains("Sqlite", StringComparison.OrdinalIgnoreCase))
        {
            return "sqlite";
        }
        if (type.Contains("Npgsql", StringComparison.OrdinalIgnoreCase) || name.Contains("Npgsql", StringComparison.OrdinalIgnoreCase))
        {
            return "postgres";
        }
        if (type.Contains("MySql", StringComparison.OrdinalIgnoreCase) || name.Contains("MySql", StringComparison.OrdinalIgnoreCase))
        {
            return "mysql";
        }
        throw new ArgumentException("Runlight: cannot tell the database of a " + type + "; use Stores.Sqlite, Stores.Postgres, or Stores.MySql");
    }

    public async Task<List<JsObject>> AllAsync(string sql, IReadOnlyList<object?>? args = null, CancellationToken cancellationToken = default) =>
        await WithAsync(
            async (c, tx) =>
            {
                using var cmd = Command(c, tx, sql, args);
                var reader = await cmd.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
                await using (reader.ConfigureAwait(false))
                {
                    var rows = new List<JsObject>();
                    if (reader.FieldCount == 0)
                    {
                        return rows;
                    }
                    var names = new string[reader.FieldCount];
                    for (int i = 0; i < names.Length; i++)
                    {
                        names[i] = reader.GetName(i);
                    }
                    while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
                    {
                        var row = new JsObject();
                        for (int i = 0; i < names.Length; i++)
                        {
                            row.Set(names[i], await reader.IsDBNullAsync(i, cancellationToken).ConfigureAwait(false) ? null : Value(reader.GetValue(i)));
                        }
                        rows.Add(row);
                    }
                    return rows;
                }
            },
            cancellationToken).ConfigureAwait(false);

    public async Task RunAsync(string sql, IReadOnlyList<object?>? args = null, CancellationToken cancellationToken = default) =>
        await AffectedAsync(sql, args, cancellationToken).ConfigureAwait(false);

    public Task<long> AffectedAsync(string sql, IReadOnlyList<object?>? args = null, CancellationToken cancellationToken = default) =>
        WithAsync(
            async (c, tx) =>
            {
                using var cmd = Command(c, tx, sql, args);
                return (long)await cmd.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
            },
            cancellationToken);

    public async Task<T> TransactionAsync<T>(Func<IDb, Task<T>> fn, CancellationToken cancellationToken = default)
    {
        var scope = _scope.Value;
        if (scope?.Transaction != null)
        {
            return await fn(this).ConfigureAwait(false);
        }
        if (scope != null)
        {
            // Inside a lock: the transaction runs on its connection.
            return await InTransactionAsync(scope, fn, cancellationToken).ConfigureAwait(false);
        }
        return await HoldAsync(s => InTransactionAsync(s, fn, cancellationToken), cancellationToken).ConfigureAwait(false);
    }

    private async Task<T> InTransactionAsync<T>(Scope scope, Func<IDb, Task<T>> fn, CancellationToken cancellationToken)
    {
        // On MySQL, as Postgres does by default: each statement sees what was committed before it
        // began, and InnoDB takes no gap locks, so two writers to neighbouring rows do not deadlock.
        var tx = Dialect == "mysql"
            ? await scope.Connection.BeginTransactionAsync(IsolationLevel.ReadCommitted, cancellationToken).ConfigureAwait(false)
            : await scope.Connection.BeginTransactionAsync(cancellationToken).ConfigureAwait(false);
        await using (tx.ConfigureAwait(false))
        {
            scope.Transaction = tx;
            try
            {
                T result = await fn(this).ConfigureAwait(false);
                await tx.CommitAsync(cancellationToken).ConfigureAwait(false);
                return result;
            }
            catch
            {
                try
                {
                    await tx.RollbackAsync(CancellationToken.None).ConfigureAwait(false);
                }
                catch (Exception)
                {
                    // A connection that could not roll back is dropped with the scope.
                }
                throw;
            }
            finally
            {
                scope.Transaction = null;
            }
        }
    }

    public async Task<T> ExclusiveAsync<T>(Func<IDb, Task<T>> fn, CancellationToken cancellationToken = default)
    {
        if (Dialect == "sqlite" || _scope.Value != null)
        {
            // SQLite's file lock already serialises its writers.
            return await fn(this).ConfigureAwait(false);
        }
        return await HoldAsync(
            async scope =>
            {
                if (Dialect == "postgres")
                {
                    // Asked for again and again rather than waited on: a waiting statement would hold up
                    // an index being built CONCURRENTLY by whoever has the lock, and the two would wait
                    // on each other for good.
                    while (!Truthy((await AllAsync("SELECT pg_try_advisory_lock(?) AS ok", [MigrationLock], cancellationToken).ConfigureAwait(false))[0].Get("ok")))
                    {
                        await Task.Delay(100, cancellationToken).ConfigureAwait(false);
                    }
                    try
                    {
                        return await fn(this).ConfigureAwait(false);
                    }
                    finally
                    {
                        try
                        {
                            await RunAsync("SELECT pg_advisory_unlock(?)", [MigrationLock], CancellationToken.None).ConfigureAwait(false);
                        }
                        catch (Exception)
                        {
                            // A lost connection ends its session, and the lock with it.
                        }
                    }
                }
                while (true)
                {
                    object? ok = (await AllAsync("SELECT GET_LOCK(" + MysqlLock + ", 5) AS ok", null, cancellationToken).ConfigureAwait(false))[0].Get("ok");
                    if (ok == null)
                    {
                        throw new InvalidOperationException("Runlight: MySQL refused the lock for creating tables");
                    }
                    if (Js.Num(ok) == 1)
                    {
                        break;
                    }
                    // Not got within 5 seconds: another process is creating the tables. Ask again.
                }
                try
                {
                    // An index on a big table takes a while to build, so the build may run past the statement timeout.
                    if (_statementTimeout > 0)
                    {
                        await LimitStatementsAsync(scope.Connection, 0, cancellationToken).ConfigureAwait(false);
                    }
                    T result = await fn(this).ConfigureAwait(false);
                    if (_statementTimeout > 0)
                    {
                        await LimitStatementsAsync(scope.Connection, _statementTimeout, cancellationToken).ConfigureAwait(false);
                    }
                    return result;
                }
                finally
                {
                    try
                    {
                        await RunAsync("DO RELEASE_LOCK(" + MysqlLock + ")", null, CancellationToken.None).ConfigureAwait(false);
                    }
                    catch (Exception)
                    {
                        // A lost connection ends its session, and the lock with it.
                    }
                }
            },
            cancellationToken).ConfigureAwait(false);
    }

    private static bool Truthy(object? v) => v is true || (Json.TryNumberOf(v, out double n) && n != 0) || v is "t" or "true";

    /// <summary>Runs <paramref name="fn"/> with a connection of its own, which every statement inside it uses.</summary>
    private async Task<T> HoldAsync<T>(Func<Scope, Task<T>> fn, CancellationToken cancellationToken)
    {
        if (Dialect == "sqlite")
        {
            await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                var scope = new Scope(await SqliteAsync(cancellationToken).ConfigureAwait(false));
                _scope.Value = scope;
                try
                {
                    return await fn(scope).ConfigureAwait(false);
                }
                finally
                {
                    _scope.Value = null;
                }
            }
            finally
            {
                _gate.Release();
            }
        }
        var connection = await OpenAsync(cancellationToken).ConfigureAwait(false);
        await using (connection.ConfigureAwait(false))
        {
            var scope = new Scope(connection);
            _scope.Value = scope;
            try
            {
                return await fn(scope).ConfigureAwait(false);
            }
            finally
            {
                _scope.Value = null;
            }
        }
    }

    private async Task<T> WithAsync<T>(Func<DbConnection, DbTransaction?, Task<T>> fn, CancellationToken cancellationToken)
    {
        var scope = _scope.Value;
        if (scope != null)
        {
            return await fn(scope.Connection, scope.Transaction).ConfigureAwait(false);
        }
        if (Dialect == "sqlite")
        {
            await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                return await fn(await SqliteAsync(cancellationToken).ConfigureAwait(false), null).ConfigureAwait(false);
            }
            finally
            {
                _gate.Release();
            }
        }
        for (int attempt = 0; ; attempt++)
        {
            var connection = await OpenAsync(cancellationToken).ConfigureAwait(false);
            await using (connection.ConfigureAwait(false))
            {
                try
                {
                    return await fn(connection, null).ConfigureAwait(false);
                }
                catch (DbException e) when (attempt == 0 && Lost(e))
                {
                    // A connection the server dropped (a restart, a failover, an idle timeout) is
                    // replaced, as a pool replaces it, and the statement sent again: it never reached
                    // the server. Not inside a transaction or a lock, whose work went with the connection.
                    await Console.Error.WriteLineAsync("Runlight: a " + (Dialect == "mysql" ? "MySQL" : "Postgres") + " connection was lost; it reconnects on the next query. " + e.Message).ConfigureAwait(false);
                    ClearPool(connection);
                }
            }
        }
    }

    /// <summary>Whether an error says the connection is gone, rather than that the statement failed.</summary>
    private static bool Lost(DbException e)
    {
        string state = e.SqlState ?? "";
        if (state.StartsWith("08", StringComparison.Ordinal) || state is "57P01" or "57P02" or "57P03" || e.ErrorCode is 2006 or 2013 or 4031)
        {
            return true;
        }
        return Regex.IsMatch(e.Message, "server has gone away|lost connection|server closed the connection|no connection to the server|terminating connection", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    }

    private static void ClearPool(DbConnection connection)
    {
        var clear = connection.GetType().GetMethod("ClearPool", BindingFlags.Public | BindingFlags.Static, [connection.GetType()]);
        try
        {
            clear?.Invoke(null, [connection]);
        }
        catch (TargetInvocationException)
        {
            // The pool is the driver's; a broken connection is dropped by it anyway.
        }
    }

    private async Task<DbConnection> SqliteAsync(CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_closed, this);
        if (_sqlite != null)
        {
            return _sqlite;
        }
        var connection = await _source.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
        foreach (string pragma in new[] { "PRAGMA journal_mode = WAL", "PRAGMA synchronous = NORMAL", "PRAGMA busy_timeout = 5000" })
        {
            using var cmd = connection.CreateCommand();
            cmd.CommandText = pragma;
            await cmd.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
        }
        _sqlite = connection;
        return connection;
    }

    private async Task<DbConnection> OpenAsync(CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_closed, this);
        var connection = await _source.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
        if (_statementTimeout > 0 || Dialect == "mysql")
        {
            try
            {
                if (Dialect == "postgres")
                {
                    using var cmd = connection.CreateCommand();
                    cmd.CommandText = "SET statement_timeout = " + _statementTimeout.ToString(CultureInfo.InvariantCulture);
                    await cmd.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
                }
                else
                {
                    await LimitStatementsAsync(connection, _statementTimeout, cancellationToken, session: true).ConfigureAwait(false);
                }
            }
            catch
            {
                await connection.DisposeAsync().ConfigureAwait(false);
                throw;
            }
        }
        return connection;
    }

    /// <summary>
    /// The server's own SQL mode with IGNORE_SPACE added, which mysql2 asks for when it connects (as a
    /// client flag MySqlConnector does not send), so a session reads SQL as the SDK's does.
    /// </summary>
    private const string IgnoreSpace =
        "sql_mode = IF(FIND_IN_SET('IGNORE_SPACE', @@SESSION.sql_mode) > 0, @@SESSION.sql_mode, CONCAT_WS(',', NULLIF(@@SESSION.sql_mode, ''), 'IGNORE_SPACE'))";

    /// <summary>
    /// MySQL's statement timeout as a session setting, which MySQL and MariaDB name differently.
    /// MariaDB counts seconds and applies it to every statement; MySQL counts milliseconds and
    /// applies it to reads. With <paramref name="session"/>, a connection just taken from the pool
    /// is set up as mysql2 sets one up, in the same statement: the pool resets a connection's
    /// session when it goes back, so this is done each time one is taken.
    /// </summary>
    private async Task LimitStatementsAsync(DbConnection connection, int ms, CancellationToken cancellationToken, bool session = false)
    {
        var settings = new List<string>();
        if (session)
        {
            settings.Add(IgnoreSpace);
        }
        if (ms > 0 || !session)
        {
            if (_mariadb == null)
            {
                using var version = connection.CreateCommand();
                version.CommandText = "SELECT VERSION() AS v";
                string text = Convert.ToString(await version.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false), CultureInfo.InvariantCulture) ?? "";
                _mariadb = text.Contains("mariadb", StringComparison.OrdinalIgnoreCase);
            }
            settings.Add(_mariadb == true
                ? "max_statement_time = " + Json.Number(ms / 1000.0)
                : "max_execution_time = " + ms.ToString(CultureInfo.InvariantCulture));
        }
        using var cmd = connection.CreateCommand();
        cmd.CommandText = "SET SESSION " + string.Join(", SESSION ", settings);
        await cmd.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    public async ValueTask DisposeAsync()
    {
        if (_closed)
        {
            return;
        }
        _closed = true;
        if (_sqlite != null)
        {
            await _sqlite.DisposeAsync().ConfigureAwait(false);
            _sqlite = null;
        }
        if (_owned)
        {
            await _source.DisposeAsync().ConfigureAwait(false);
        }
        _gate.Dispose();
    }

    // ---- statements

    private static PropertyInfo? _npgsqlType;
    private static object? _npgsqlUnknown;

    private DbCommand Command(DbConnection connection, DbTransaction? tx, string sql, IReadOnlyList<object?>? args)
    {
        var cmd = connection.CreateCommand();
        cmd.Transaction = tx;
#pragma warning disable CA2100 // statements are the store's own text, values are bound
        cmd.CommandText = _texts.GetOrAdd(sql, s => Rewrite(s, Dialect));
#pragma warning restore CA2100
        if (_texts.Count > 2000)
        {
            _texts.Clear();
        }
        if (args == null)
        {
            return cmd;
        }
        for (int i = 0; i < args.Count; i++)
        {
            var p = cmd.CreateParameter();
            object? v = Bindable(args[i]);
            switch (Dialect)
            {
                case "sqlite":
                    p.ParameterName = "?" + (i + 1).ToString(CultureInfo.InvariantCulture);
                    p.Value = v ?? DBNull.Value;
                    break;
                case "postgres":
                    // Every value as untyped text, as node-postgres sends it: the server reads each by
                    // the place it stands in, so "5" compares with a number and "x" with text.
                    p.Value = v switch
                    {
                        null => DBNull.Value,
                        string s => s,
                        bool b => b ? "true" : "false",
                        long l => l.ToString(CultureInfo.InvariantCulture),
                        double d => Json.Number(d),
                        _ => Convert.ToString(v, CultureInfo.InvariantCulture) ?? "",
                    };
                    Untyped(p);
                    break;
                default:
                    p.Value = v ?? DBNull.Value;
                    break;
            }
            cmd.Parameters.Add(p);
        }
        return cmd;
    }

    /// <summary>Npgsql's NpgsqlDbType.Unknown on a parameter, found by name, since Npgsql is the app's dependency, not this package's.</summary>
    private static void Untyped(DbParameter p)
    {
        if (_npgsqlType == null)
        {
            var property = p.GetType().GetProperty("NpgsqlDbType");
            if (property == null)
            {
                return;
            }
            _npgsqlUnknown = Enum.Parse(property.PropertyType, "Unknown");
            _npgsqlType = property;
        }
        _npgsqlType.SetValue(p, _npgsqlUnknown);
    }

    /// <summary>A value as the drivers bind it: whole numbers as long, text without a lone surrogate (written as U+FFFD, as JavaScript writes text out).</summary>
    private static object? Bindable(object? v) => v switch
    {
        null or Undefined => null,
        string s => Js.WellFormed(s),
        long or bool => v,
        int i => (long)i,
        double d when double.IsFinite(d) && d == Math.Floor(d) && Math.Abs(d) <= Js.MaxSafeInteger => (long)d,
        double d => d,
        float f => (double)f,
        decimal m => (double)m,
        _ => Convert.ToString(v, CultureInfo.InvariantCulture),
    };

    /// <summary>A column's value as the store reads it: whole numbers as long, other numbers as double, text as string.</summary>
    private static object? Value(object v) => v switch
    {
        long or string or double or bool => v,
        int i => (long)i,
        short s => (long)s,
        byte b => (long)b,
        sbyte b => (long)b,
        ushort u => (long)u,
        uint u => (long)u,
        ulong u => u <= long.MaxValue ? (long)u : (double)u,
        // A single as the text Postgres writes it, as node-postgres reads a REAL: 9.99, not 9.989999771118164.
        float f => double.Parse(f.ToString(CultureInfo.InvariantCulture), CultureInfo.InvariantCulture),
        decimal m => m == decimal.Truncate(m) && m >= long.MinValue && m <= long.MaxValue ? (long)m : (double)m,
        byte[] bytes => Js.Decode(bytes),
        DateTime t => t.ToString("o", CultureInfo.InvariantCulture),
        _ => Convert.ToString(v, CultureInfo.InvariantCulture),
    };

    private static string Rewrite(string sql, string dialect) => dialect switch
    {
        "mysql" => MysqlText(sql),
        "postgres" => Number(sql, "$"),
        _ => Number(sql, "?"),
    };

    /// <summary>Each <c>?</c> outside quotes numbered: <c>?1</c> or <c>$1</c>.</summary>
    private static string Number(string sql, string mark)
    {
        var b = new StringBuilder(sql.Length + 16);
        int n = 0;
        char quote = '\0';
        foreach (char ch in sql)
        {
            if (quote != '\0')
            {
                if (ch == quote)
                {
                    quote = '\0';
                }
                b.Append(ch);
            }
            else if (ch is '\'' or '"' or '`')
            {
                quote = ch;
                b.Append(ch);
            }
            else if (ch == '?')
            {
                b.Append(mark).Append((++n).ToString(CultureInfo.InvariantCulture));
            }
            else
            {
                b.Append(ch);
            }
        }
        return b.ToString();
    }

    /// <summary>
    /// SQL written for SQLite and Postgres, as MySQL and MariaDB read it: a "quoted" identifier is
    /// quoted with backticks, and a backslash inside 'text' is doubled. With values, each <c>?</c>
    /// outside quotes becomes its value as mysql2 writes it; without, the placeholders stay.
    /// </summary>
    public static string MysqlText(string sql, IReadOnlyList<object?>? args = null, Func<object?, string>? escape = null)
    {
        var b = new StringBuilder(sql.Length + 16);
        int n = 0;
        char quote = '\0';
        foreach (char ch in sql)
        {
            if (quote != '\0')
            {
                if (ch == quote)
                {
                    quote = '\0';
                    b.Append(ch == '"' ? '`' : ch);
                }
                else if (quote == '\'' && ch == '\\')
                {
                    b.Append("\\\\");
                }
                else if (quote == '"' && ch == '`')
                {
                    b.Append("``");
                }
                else
                {
                    b.Append(ch);
                }
            }
            else if (ch is '\'' or '"' or '`')
            {
                quote = ch;
                b.Append(ch == '"' ? '`' : ch);
            }
            else if (ch == '?' && args != null)
            {
                if (n >= args.Count)
                {
                    throw new ArgumentException("Runlight: a statement has more placeholders than values");
                }
                b.Append((escape ?? Escape)(args[n++]));
            }
            else
            {
                b.Append(ch);
            }
        }
        if (args != null && n != args.Count)
        {
            throw new ArgumentException("Runlight: a statement has more values than placeholders");
        }
        return b.ToString();
    }

    /// <summary>A value as a MySQL literal, as mysql2's escape() writes the values Runlight binds.</summary>
    private static string Escape(object? value)
    {
        switch (Bindable(value))
        {
            case null:
                return "NULL";
            case bool b:
                return b ? "true" : "false";
            case long l:
                return l.ToString(CultureInfo.InvariantCulture);
            case double d:
                return Json.Number(d);
            case string s:
                {
                    var b = new StringBuilder(s.Length + 2).Append('\'');
                    foreach (char c in s)
                    {
                        b.Append(c switch
                        {
                            '\0' => "\\0",
                            '\b' => "\\b",
                            '\t' => "\\t",
                            (char)0x1a => "\\Z",
                            '\n' => "\\n",
                            '\r' => "\\r",
                            '"' => "\\\"",
                            '\'' => "\\'",
                            '\\' => "\\\\",
                            _ => c.ToString(),
                        });
                    }
                    return b.Append('\'').ToString();
                }
            default:
                return "NULL";
        }
    }
}
