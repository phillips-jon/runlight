using System.Threading.Tasks;
using Microsoft.Data.Sqlite;
using MySqlConnector;
using Npgsql;
using Runlight.Db;
using Runlight.Store;

namespace Runlight.Tests.ConformanceRunner;

/// <summary>
/// Fresh, empty stores for the conformance scenarios, as the PHP's TestStores makes them: SQLite in memory
/// always, a Postgres schema of its own inside runlight_test_dotnet when RUNLIGHT_TEST_PG is set, and MySQL
/// 8.4 and MariaDB 11.4 when RUNLIGHT_TEST_MYSQL is set. MySQL has one database for the port's tests
/// (runlight_test_dotnet), so each scenario there empties it of Runlight's tables first. Everything is
/// closed and dropped by <see cref="Databases.CleanupAsync"/>.
/// </summary>
public static class TestStores
{
    /// <summary>The database for a fresh store of this kind.</summary>
    public static async Task<IDb> DbAsync(string kind)
    {
        AdoDb db;
        if (kind == "sqlite")
        {
            db = new AdoDb(SqliteFactory.Instance.CreateDataSource("Data Source=:memory:"), "sqlite", owned: true);
        }
        else if (kind == "postgres")
        {
            string schema = await Databases.PgSchemaAsync();
            db = new AdoDb(NpgsqlDataSource.Create(Databases.PgConnectionString(Databases.PgUrl()!, schema)), "postgres", owned: true);
        }
        else
        {
            await Databases.DropMysqlTablesAsync(kind);
            db = new AdoDb(new MySqlDataSource(Databases.MysqlConnectionString(Databases.MysqlUrls()[kind])), "mysql", owned: true);
        }
        Databases.OnCleanup(() => db.DisposeAsync().AsTask());
        return db;
    }

    /// <summary>A fresh store of this kind, through Stores.FromDb, which wraps an open IDb as Stores.Sqlite, Stores.Postgres, and Stores.MySql wrap theirs.</summary>
    public static async Task<SqlStore> StoreAsync(string kind) => Stores.FromDb(await DbAsync(kind));
}
