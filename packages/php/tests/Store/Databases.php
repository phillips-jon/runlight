<?php

declare(strict_types=1);

namespace Runlight\Tests\Store;

use Runlight\Db\Connect;
use Runlight\Db\PdoDb;
use Runlight\Store\SqlStore;
use Runlight\Store\Stores;

/**
 * The databases the store tests run on: SQLite always; Postgres when RUNLIGHT_TEST_PG holds a connection
 * string (each test gets a schema of its own); MySQL 8.4 and MariaDB 11.4 when RUNLIGHT_TEST_MYSQL is set
 * (each test gets a database of its own). RUNLIGHT_TEST_MYSQL may hold the URLs, separated by spaces or
 * commas; any other value means the two local test servers.
 */
final class Databases
{
    public const MYSQL_URLS = [
        'mysql' => 'mysql://root:runlight@127.0.0.1:33084/runlight_test',
        'mariadb' => 'mysql://root:runlight@127.0.0.1:33114/runlight_test',
    ];

    /** @var list<\Closure(): void> */
    private static array $cleanups = [];

    /** @return array<string, array{0: string}> kind => [kind], for a data provider */
    public static function kinds(): array
    {
        $kinds = ['sqlite' => ['sqlite']];
        if (self::pgUrl() !== null) {
            $kinds['postgres'] = ['postgres'];
        }
        foreach (self::mysqlUrls() as $name => $_) {
            $kinds[$name] = [$name];
        }
        return $kinds;
    }

    public static function pgUrl(): ?string
    {
        $url = getenv('RUNLIGHT_TEST_PG');
        return is_string($url) && $url !== '' ? $url : null;
    }

    /** @return array<string, string> */
    public static function mysqlUrls(): array
    {
        $value = getenv('RUNLIGHT_TEST_MYSQL');
        if (!is_string($value) || $value === '') {
            return [];
        }
        $urls = array_values(array_filter(preg_split('/[\s,]+/', $value) ?: [], static fn (string $u): bool => str_contains($u, '://')));
        if (!$urls) {
            return self::MYSQL_URLS;
        }
        $out = [];
        foreach ($urls as $i => $url) {
            $out[$i === 0 ? 'mysql' : "mysql$i"] = $url;
        }
        return $out;
    }

    /** A fresh, empty store of a kind, dropped by cleanup(). */
    public static function fresh(string $kind): SqlStore
    {
        if ($kind === 'sqlite') {
            return Stores::sqlite(':memory:');
        }
        $name = 'rl_test_' . bin2hex(random_bytes(5));
        if ($kind === 'postgres') {
            $url = (string) self::pgUrl();
            $admin = Connect::postgres($url);
            $admin->run("CREATE SCHEMA $name");
            $store = Stores::postgres($url, ['schema' => $name]);
            self::$cleanups[] = static function () use ($store, $admin, $name): void {
                $store->close();
                $admin->run("DROP SCHEMA $name CASCADE");
                $admin->close();
            };
            return $store;
        }
        $url = self::mysqlUrls()[$kind];
        $store = Stores::mysql(self::mysqlDatabase($url, $name));
        self::$cleanups[] = static function () use ($store): void {
            $store->close();
        };
        return $store;
    }

    /** Makes a database of its own on a MySQL server, dropped by cleanup(), and gives its URL. */
    public static function mysqlDatabase(string $url, string $name): string
    {
        $admin = Connect::mysql($url);
        $admin->run("CREATE DATABASE $name");
        self::$cleanups[] = static function () use ($admin, $name): void {
            $admin->run("DROP DATABASE IF EXISTS $name");
            $admin->close();
        };
        return (string) preg_replace('#/[^/?]*(\?|$)#', "/$name$1", $url, 1);
    }

    /** Postgres URL and schema, for a test that opens several connections to one schema. */
    public static function pgSchema(): string
    {
        $name = 'rl_test_' . bin2hex(random_bytes(5));
        $admin = Connect::postgres((string) self::pgUrl());
        $admin->run("CREATE SCHEMA $name");
        self::$cleanups[] = static function () use ($admin, $name): void {
            $admin->run("DROP SCHEMA $name CASCADE");
            $admin->close();
        };
        return $name;
    }

    /** Drops what the tests made, newest first, so each store closes before its database goes. */
    public static function cleanup(): void
    {
        while (self::$cleanups) {
            $fn = array_pop(self::$cleanups);
            try {
                $fn();
            } catch (\Throwable $error) {
                fwrite(STDERR, 'cleanup: ' . $error->getMessage() . "\n");
            }
        }
    }

    /** The PdoDb under a store. */
    public static function pdoDb(SqlStore $store): PdoDb
    {
        $db = $store->db;
        if (!$db instanceof PdoDb) {
            throw new \LogicException('not a PdoDb');
        }
        return $db;
    }
}
