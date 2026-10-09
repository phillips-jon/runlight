<?php

declare(strict_types=1);

namespace Runlight\Tests\Store;

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Runlight\Db\Connect;
use Runlight\Db\Db;
use Runlight\Store\Sql;
use Runlight\Store\SqlStore;
use Runlight\Store\Stores;

/**
 * Creating and upgrading the tables, and what each connection is set up to do: storage.test.ts,
 * postgres.test.ts, and mysql.test.ts, with the tables compared against the ones the TypeScript SDK makes.
 */
final class MigrateTest extends TestCase
{
    /** @var list<string> */
    private array $files = [];

    protected function tearDown(): void
    {
        Databases::cleanup();
        foreach ($this->files as $file) {
            if (file_exists($file)) {
                @chmod($file, 0o644);
                @unlink($file);
            }
        }
    }

    /** @return array<string, array{0: string}> */
    public static function kinds(): array
    {
        return Databases::kinds();
    }

    /** @return array<string, array{0: string}> */
    public static function servers(): array
    {
        $kinds = Databases::kinds();
        unset($kinds['sqlite']);
        return $kinds ?: ['none' => ['none']];
    }

    private function file(): string
    {
        $file = tempnam(sys_get_temp_dir(), 'rl-migrate-') . '.db';
        array_push($this->files, $file, "$file-wal", "$file-shm");
        return $file;
    }

    /** A store on a database of the kind, and a function that opens another store on the same one. */
    private function shared(string $kind): array
    {
        if ($kind === 'sqlite') {
            $file = $this->file();
            return [Stores::sqlite($file), static fn (): SqlStore => Stores::sqlite($file), ['sqlite', $file]];
        }
        if ($kind === 'postgres') {
            $schema = Databases::pgSchema();
            $url = (string) Databases::pgUrl();
            return [Stores::postgres($url, ['schema' => $schema]), static fn (): SqlStore => Stores::postgres($url, ['schema' => $schema]), ['postgres', $url, $schema]];
        }
        $url = Databases::mysqlDatabase(Databases::mysqlUrls()[$kind], 'rl_test_' . bin2hex(random_bytes(5)));
        return [Stores::mysql($url), static fn (): SqlStore => Stores::mysql($url), ['mysql', $url]];
    }

    private static function tables(Db $db): int
    {
        $sql = match ($db->dialect()) {
            'sqlite' => "SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'table' AND name LIKE 'rl\\_%' ESCAPE '\\'",
            'postgres' => 'SELECT COUNT(*) AS n FROM information_schema.tables WHERE table_schema = current_schema()',
            default => 'SELECT COUNT(*) AS n FROM information_schema.tables WHERE table_schema = DATABASE()',
        };
        return (int) $db->all($sql)[0]['n'];
    }

    #[DataProvider('kinds')]
    public function testMigratingIsSafeAnyNumberOfTimesAndRecordsTheSchemaVersion(string $kind): void
    {
        $store = Databases::fresh($kind);
        $store->migrate();
        $store->migrate();
        (new SqlStore($store->db))->migrate();
        $this->assertSame(15, self::tables($store->db));
        $this->assertSame([['value' => '11']], $store->db->all('SELECT value FROM rl_meta WHERE "key" = \'schema\''));
    }

    #[DataProvider('kinds')]
    public function testAnUpgradeThatStoppedAfterAddingAColumnButBeforeRecordingItsVersionStartsTheNextTime(string $kind): void
    {
        if ($kind === 'mysql') {
            // MySQL 8.4 refuses the version 10 upgrade's TEXT column with a default, in TypeScript too; no MySQL
            // database was ever at version 9, since MySQL support came with version 11.
            $this->markTestSkipped('MySQL tables start at version 11');
        }
        [$store, $again] = $this->shared($kind);
        $store->migrate();
        // As an upgrade from version 9 leaves things when it stops between its two steps.
        $store->db->run('UPDATE rl_meta SET value = \'9\' WHERE "key" = \'schema\'');
        $store->close();
        $next = $again();
        $next->migrate();
        $this->assertSame([['value' => '11']], $next->db->all('SELECT value FROM rl_meta WHERE "key" = \'schema\''));
        $next->close();
    }

    public function testADatabaseThatCanOnlyBeReadStillAnswersReports(): void
    {
        $file = $this->file();
        $first = Stores::sqlite($file);
        $first->migrate();
        $site = ['id' => 'default', 'name' => 'Example', 'hostnames' => ['example.com'], 'timezone' => 'UTC'];
        $first->upsertSite($site, 1);
        $first->close();
        chmod($file, 0o444);
        $store = Stores::sqlite($file);
        $store->migrate();
        $store->upsertSite($site, 2);
        $this->assertSame(0, $store->stats(['site' => 'default', 'from' => 0, 'to' => 1, 'filters' => []])['visits']);
        $store->close();
    }

    #[DataProvider('servers')]
    public function testProcessesStartingAtOnceCreateTheTablesOnce(string $kind): void
    {
        if ($kind === 'none') {
            $this->markTestSkipped('Set RUNLIGHT_TEST_PG or RUNLIGHT_TEST_MYSQL.');
        }
        [$store, , $args] = $this->shared($kind);
        $processes = [];
        for ($i = 0; $i < 4; $i++) {
            $processes[] = proc_open([PHP_BINARY, __DIR__ . '/../Support/migrate.php', ...$args], [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
            $outputs[] = $pipes;
        }
        foreach ($processes as $i => $process) {
            $out = stream_get_contents($outputs[$i][1]);
            $err = stream_get_contents($outputs[$i][2]);
            $this->assertSame(0, proc_close($process), "$out $err");
            $this->assertSame("ok\n", $out);
        }
        $this->assertSame(15, self::tables($store->db));
        $store->close();
    }

    public function testTheTablesAreTheOnesTheTypeScriptSdkMakesOnSqlite(): void
    {
        $theirs = Stores::sqlite(__DIR__ . '/../fixtures/store.db');
        $mine = Stores::sqlite(':memory:');
        $mine->migrate();
        $schema = static fn (SqlStore $s): array => $s->db->all("SELECT type, name, tbl_name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name");
        $this->assertSame($schema($theirs), $schema($mine));
        $theirs->close();
    }

    #[DataProvider('servers')]
    public function testTheTablesAreTheOnesTheTypeScriptSdkMakesOnPostgresAndMysql(string $kind): void
    {
        if ($kind === 'none') {
            $this->markTestSkipped('Set RUNLIGHT_TEST_PG or RUNLIGHT_TEST_MYSQL to compare the tables there too.');
        }
        $node = Node::binary();
        if ($node === null) {
            $this->markTestSkipped('node 22 or later, with the repository installed, makes the TypeScript tables; neither was found.');
        }
        [$mine] = $this->shared($kind);
        $mine->migrate();
        if ($kind === 'postgres') {
            $schema = Databases::pgSchema();
            $url = (string) Databases::pgUrl();
            $theirsUrl = $url . (str_contains($url, '?') ? '&' : '?') . 'options=' . rawurlencode("-c search_path=$schema");
            $theirs = Stores::postgres($url, ['schema' => $schema]);
        } else {
            $theirsUrl = Databases::mysqlDatabase(Databases::mysqlUrls()[$kind], 'rl_test_' . bin2hex(random_bytes(5)));
            $theirs = Stores::mysql($theirsUrl);
        }
        [$status, , $err] = Node::store($node, ['migrate', $theirsUrl]);
        $this->assertSame(0, $status, $err);
        $describe = static function (SqlStore $store): array {
            if ($store->db->dialect() === 'postgres') {
                $columns = $store->db->all('SELECT table_name, column_name, ordinal_position, data_type, is_nullable, column_default FROM information_schema.columns WHERE table_schema = current_schema() ORDER BY table_name, ordinal_position');
                $indexes = $store->db->all("SELECT tablename, indexname, regexp_replace(indexdef, ' ON [a-z0-9_]+\\.', ' ON ') AS def FROM pg_indexes WHERE schemaname = current_schema() ORDER BY indexname");
            } else {
                $columns = $store->db->all('SELECT table_name, column_name, ordinal_position, column_type, is_nullable, column_default, collation_name, extra, generation_expression FROM information_schema.columns WHERE table_schema = DATABASE() ORDER BY table_name, ordinal_position');
                $indexes = $store->db->all('SELECT table_name, index_name, non_unique, seq_in_index, column_name, sub_part FROM information_schema.statistics WHERE table_schema = DATABASE() ORDER BY table_name, index_name, seq_in_index');
                $tables = $store->db->all('SELECT table_name, table_collation, engine FROM information_schema.tables WHERE table_schema = DATABASE() ORDER BY table_name');
                return [$columns, $indexes, $tables];
            }
            return [$columns, $indexes];
        };
        $expected = $describe($theirs);
        $this->assertCount(15, array_unique(array_column($expected[0], array_key_exists('table_name', $expected[0][0]) ? 'table_name' : 'TABLE_NAME')));
        $this->assertEquals($expected, $describe($mine));
        $theirs->close();
        $mine->close();
    }

    public function testPostgresKeepsItsStatementTimeoutAfterBuildingTablesAndDropsAnIndexABuildLeftUnusable(): void
    {
        if (Databases::pgUrl() === null) {
            $this->markTestSkipped('RUNLIGHT_TEST_PG is not set');
        }
        $store = Databases::fresh('postgres');
        $this->assertSame('2min', $store->db->all('SHOW statement_timeout')[0]['statement_timeout']);
        $store->migrate();
        $this->assertSame('2min', $store->db->all('SHOW statement_timeout')[0]['statement_timeout'], 'RESET comes back to the timeout the connection started with');
        try {
            $store->db->run("UPDATE pg_index SET indisvalid = false WHERE indexrelid = 'rl_events_link'::regclass");
        } catch (\PDOException) {
            $this->markTestSkipped('marking an index unusable needs a superuser');
        }
        $this->assertSame([['valid' => false]], $store->db->all("SELECT indisvalid AS valid FROM pg_index WHERE indexrelid = 'rl_events_link'::regclass"));
        (new SqlStore($store->db))->migrate();
        $this->assertSame([['valid' => true]], $store->db->all("SELECT indisvalid AS valid FROM pg_index WHERE indexrelid = 'rl_events_link'::regclass"), 'dropped, and built again');
        $none = Stores::postgres((string) Databases::pgUrl(), ['statementTimeout' => 0]);
        $this->assertSame('0', $none->db->all('SHOW statement_timeout')[0]['statement_timeout']);
        $none->close();
    }

    #[DataProvider('servers')]
    public function testAMysqlSessionIsTheOneMysql2Opens(string $kind): void
    {
        if ($kind === 'none' || $kind === 'postgres') {
            $this->markTestSkipped('MySQL only');
        }
        $store = Databases::fresh($kind);
        $row = $store->db->all('SELECT @@sql_mode AS mode, @@character_set_client AS charset, VERSION() AS version')[0];
        $modes = explode(',', (string) $row['mode']);
        $this->assertContains('IGNORE_SPACE', $modes, 'mysql2 asks for it when it connects');
        $this->assertNotContains('ANSI_QUOTES', $modes);
        $this->assertNotContains('NO_BACKSLASH_ESCAPES', $modes);
        $this->assertSame('utf8mb4', $row['charset']);
        $mariadb = str_contains(strtolower((string) $row['version']), 'mariadb');
        $limit = $store->db->all($mariadb ? 'SELECT @@max_statement_time AS t' : 'SELECT @@max_execution_time AS t')[0]['t'];
        $this->assertEquals($mariadb ? 120 : 120_000, $limit);

        // Names in double quotes are names, and a backslash in quoted text is a backslash.
        $store->migrate();
        $store->setSetting('a\\b', 'c\\d');
        $this->assertSame([['key' => 'a\\b', 'value' => 'c\\d']], $store->db->all("SELECT \"key\", value FROM rl_settings WHERE \"key\" LIKE 'a\\b' ESCAPE '|'"));
        $this->assertSame([['b' => '\\']], $store->db->all("SELECT '\\' AS b"));

        // One lock per database while the tables are made, with the statement timeout lifted meanwhile.
        $seen = null;
        $store->db->exclusive(function (Db $db) use (&$seen, $mariadb): void {
            $seen = $db->all("SELECT IS_USED_LOCK(CONCAT('runlight:', LEFT(SHA2(COALESCE(DATABASE(), ''), 256), 48))) IS NOT NULL AS held, " . ($mariadb ? '@@max_statement_time' : '@@max_execution_time') . ' AS t')[0];
        });
        $this->assertSame(1, (int) $seen['held']);
        $this->assertEquals(0, $seen['t']);
        $this->assertEquals($mariadb ? 120 : 120_000, $store->db->all($mariadb ? 'SELECT @@max_statement_time AS t' : 'SELECT @@max_execution_time AS t')[0]['t'], 'and put back after');
        $this->assertNull($store->db->all("SELECT IS_USED_LOCK(CONCAT('runlight:', LEFT(SHA2(COALESCE(DATABASE(), ''), 256), 48))) AS id")[0]['id']);

        // Sums arrive as numbers the store can read, and a transaction reads what was committed before each statement.
        $this->assertSame('3', (string) $store->db->all('SELECT SUM(x) AS s FROM (SELECT 1 AS x UNION ALL SELECT 2) t')[0]['s']);
        $level = $store->db->transaction(static fn (Db $db) => $db->all('SELECT @@transaction_isolation AS level')[0]['level'] ?? null);
        $this->assertContains($level, ['READ-COMMITTED', 'REPEATABLE-READ']);
    }

    #[DataProvider('servers')]
    public function testAConnectionTheServerDropsIsReplacedAndTheProcessCarriesOn(string $kind): void
    {
        if ($kind === 'none') {
            $this->markTestSkipped('Set RUNLIGHT_TEST_PG or RUNLIGHT_TEST_MYSQL.');
        }
        $store = Databases::fresh($kind);
        $store->migrate();
        if ($kind === 'postgres') {
            $id = $store->db->all('SELECT pg_backend_pid() AS id')[0]['id'];
            $admin = Connect::postgres((string) Databases::pgUrl());
            $admin->all('SELECT pg_terminate_backend(?)', [(int) $id]);
        } else {
            $id = $store->db->all('SELECT CONNECTION_ID() AS id')[0]['id'];
            $admin = Connect::mysql(Databases::mysqlUrls()[$kind]);
            $admin->run('KILL ' . (int) $id);
        }
        $admin->close();
        usleep(200_000);
        $logged = ini_get('error_log');
        $log = tempnam(sys_get_temp_dir(), 'rl-log-');
        ini_set('error_log', (string) $log);
        try {
            set_error_handler(static fn (): bool => true);
            try {
                $sites = $store->sites();
            } finally {
                restore_error_handler();
            }
            $this->assertSame([], $sites);
            $this->assertStringContainsString('connection was lost', (string) file_get_contents((string) $log), 'the lost connection was reported');
        } finally {
            ini_set('error_log', (string) $logged);
            @unlink((string) $log);
        }
        $this->assertNotEquals($id, $store->db->all($kind === 'postgres' ? 'SELECT pg_backend_pid() AS id' : 'SELECT CONNECTION_ID() AS id')[0]['id']);
    }

    public function testTheSchemaVersionIsTheTypeScriptOne(): void
    {
        $this->assertSame(11, Sql::SCHEMA_VERSION);
        $this->assertSame('utf8mb4_0900_bin', SqlStore::MYSQL_COLLATION);
    }
}
