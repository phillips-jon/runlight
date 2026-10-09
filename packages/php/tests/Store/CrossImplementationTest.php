<?php

declare(strict_types=1);

namespace Runlight\Tests\Store;

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Runlight\Json;
use Runlight\Store\SqlStore;
use Runlight\Store\Stores;

/**
 * One database, both implementations. tests/fixtures/store.db was built by the TypeScript SDK and
 * tests/fixtures/store.json holds what its SqlStore reads answered (scripts/php-fixtures-store.mts); the PHP
 * store must answer the same over a copy of that file, and over the same rows copied into Postgres and MySQL.
 * Then the other way: PHP writes a database and the TypeScript store reads it, when node is at hand.
 */
final class CrossImplementationTest extends TestCase
{
    private static ?array $fixture = null;
    /** @var list<string>|null The answers as JSON, read with objects kept apart from lists. */
    private static ?array $expected = null;
    /** @var list<string> */
    private array $files = [];

    protected function tearDown(): void
    {
        Databases::cleanup();
        foreach ($this->files as $file) {
            @unlink($file);
        }
    }

    private static function fixture(): array
    {
        return self::$fixture ??= Json::decode((string) file_get_contents(__DIR__ . '/../fixtures/store.json'), true);
    }

    /** @return list<string> */
    private static function expected(): array
    {
        return self::$expected ??= array_map(static fn (\stdClass $call): string => Json::encode($call->result), Json::decode((string) file_get_contents(__DIR__ . '/../fixtures/store.json'))->calls);
    }

    private function copy(): string
    {
        $file = tempnam(sys_get_temp_dir(), 'rl-store-') . '.db';
        copy(__DIR__ . '/../fixtures/store.db', $file);
        $this->files[] = $file;
        array_push($this->files, "$file-wal", "$file-shm");
        return $file;
    }

    /** A read's answer in JSON's terms, as the script writes it. */
    private static function answer(SqlStore $store, array $call): mixed
    {
        $result = $store->{$call['method']}(...$call['args']);
        if ($call['method'] === 'rollupDays') {
            sort($result);
        }
        if (in_array($call['method'], ['goalTotalsAll', 'siteOverrides'], true)) {
            $result = Json::object(array_map(static fn ($v) => is_array($v) && !array_is_list($v) ? $v : Json::object($v), $result));
        }
        return $result;
    }

    private function assertAnswers(SqlStore $store, string $label): void
    {
        $failures = [];
        foreach (self::fixture()['calls'] as $i => $call) {
            $expected = self::expected()[$i];
            try {
                $actual = Json::encode(self::answer($store, $call));
            } catch (\Throwable $error) {
                $actual = get_class($error) . ': ' . $error->getMessage();
            }
            if ($actual !== $expected) {
                $failures[] = "#$i {$call['method']}(" . substr(Json::encode($call['args']), 0, 300) . ")\n  expected $expected\n  actual   $actual";
            }
        }
        $this->assertSame([], array_slice($failures, 0, 15), "$label: " . count($failures) . ' of ' . count(self::fixture()['calls']) . ' reads differ');
    }

    public function testTheFixtureCoversEveryKindOfRead(): void
    {
        $methods = array_unique(array_column(self::fixture()['calls'], 'method'));
        $this->assertGreaterThan(1500, count(self::fixture()['calls']));
        foreach (['stats', 'series', 'hourly', 'breakdown', 'goalTotalsAll', 'goalSeries', 'funnelCounts', 'journeyPages', 'eventPropKeys', 'eventPropValues', 'links', 'linkSeries', 'realtime'] as $method) {
            $this->assertContains($method, $methods);
        }
    }

    public function testPhpReadsADatabaseTheTypeScriptSdkWroteAndAnswersTheSame(): void
    {
        $store = Stores::sqlite($this->copy());
        $store->migrate();
        $this->assertAnswers($store, 'sqlite');
        // Opening it changed nothing a reader would see: the schema is the same version.
        $this->assertSame([['value' => '11']], $store->db->all('SELECT value FROM rl_meta WHERE "key" = \'schema\''));
        $store->close();
    }

    /** @return array<string, array{0: string}> */
    public static function servers(): array
    {
        $kinds = Databases::kinds();
        unset($kinds['sqlite']);
        return $kinds ?: ['none' => ['none']];
    }

    #[DataProvider('servers')]
    public function testTheSameRowsInPostgresAndMysqlAnswerTheSame(string $kind): void
    {
        if ($kind === 'none') {
            $this->markTestSkipped('Set RUNLIGHT_TEST_PG or RUNLIGHT_TEST_MYSQL to compare Postgres and MySQL too.');
        }
        $source = Stores::sqlite($this->copy());
        $target = Databases::fresh($kind);
        $target->migrate();
        $tables = ['rl_meta', 'rl_sites', 'rl_salts', 'rl_sessions', 'rl_events', 'rl_links', 'rl_link_domains', 'rl_shares', 'rl_goals', 'rl_settings', 'rl_reports', 'rl_tokens', 'rl_funnels', 'rl_rollup_days', 'rl_rollups'];
        $target->transaction(function (SqlStore $into) use ($source, $tables): void {
            foreach ($tables as $table) {
                $into->db->run("DELETE FROM $table");
                foreach ($source->db->all("SELECT * FROM $table") as $row) {
                    $columns = array_map(static fn (string $c): string => "\"$c\"", array_keys($row));
                    $into->db->run("INSERT INTO $table (" . implode(', ', $columns) . ') VALUES (' . implode(', ', array_fill(0, count($row), '?')) . ')', array_values($row));
                }
            }
        });
        $this->assertAnswers($target, $kind);
        $source->close();
    }

    public function testTheTypeScriptSdkReadsADatabasePhpWroteAndAnswersTheSame(): void
    {
        $node = Node::binary();
        if ($node === null) {
            $this->markTestSkipped('node 22 or later, with the repository installed, reads the PHP database; neither was found.');
        }
        $file = tempnam(sys_get_temp_dir(), 'rl-php-') . '.db';
        array_push($this->files, $file, "$file-wal", "$file-shm");
        $store = Stores::sqlite($file);
        $calls = Seed::everything($store);
        $mine = array_map(static fn (array $call): mixed => self::answer($store, $call), $calls);
        $store->db->run('PRAGMA journal_mode = DELETE');
        $store->close();

        $callsFile = tempnam(sys_get_temp_dir(), 'rl-calls-');
        $this->files[] = $callsFile;
        file_put_contents($callsFile, Json::encode($calls));
        [$status, $out, $err] = Node::store($node, ['read', $file, $callsFile]);
        $this->assertSame(0, $status, $err);
        // Objects kept apart from lists, so {} and [] are compared as written.
        $theirs = Json::tryDecode((string) $out);
        $this->assertIsArray($theirs, substr((string) $out, 0, 500) . "\n" . $err);
        $this->assertCount(count($calls), $theirs);
        $failures = [];
        foreach ($calls as $i => $call) {
            $a = Json::encode($mine[$i]);
            $b = Json::encode($theirs[$i]);
            if ($a !== $b) {
                $failures[] = "#$i {$call['method']}\n  php $a\n  ts  $b";
            }
        }
        $this->assertSame([], array_slice($failures, 0, 15), count($failures) . ' reads differ');
        $this->assertGreaterThan(100, count($calls));
    }
}
