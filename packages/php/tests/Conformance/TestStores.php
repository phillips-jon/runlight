<?php

declare(strict_types=1);

namespace Runlight\Tests\Conformance;

use Runlight\Db\Connect;
use Runlight\Db\Db;
use Runlight\Store\Stores;

/**
 * Fresh, empty stores for the conformance scenarios: SQLite in memory always,
 * a Postgres schema of its own when RUNLIGHT_TEST_PG is set, and a MySQL or
 * MariaDB database of its own when RUNLIGHT_TEST_MYSQL is set. Each variable
 * holds a connection URL; set to anything else (such as 1), the URLs the port
 * conventions name are used, both MySQL 8.4 and MariaDB 11.4 for MySQL.
 */
final class TestStores
{
    public const PG_URL = 'postgres://joncphillips@127.0.0.1:5432/runlight_test';
    public const MYSQL_URLS = [
        'mysql' => 'mysql://root:runlight@127.0.0.1:33084/runlight_test',
        'mariadb' => 'mysql://root:runlight@127.0.0.1:33114/runlight_test',
    ];

    /** @var list<\Closure(): void> */
    private array $cleanups = [];

    /**
     * The stores to play on, by name, each with the URL it reaches (empty for SQLite).
     *
     * @return array<string, string>
     */
    public static function kinds(): array
    {
        $kinds = ['sqlite' => ''];
        $pg = self::env('RUNLIGHT_TEST_PG');
        if ($pg !== null) {
            $kinds['postgres'] = str_contains($pg, '://') ? $pg : self::PG_URL;
        }
        $mysql = self::env('RUNLIGHT_TEST_MYSQL');
        if ($mysql !== null) {
            if (str_contains($mysql, '://')) {
                $kinds['mysql'] = $mysql;
            } else {
                $kinds += self::MYSQL_URLS;
            }
        }
        return $kinds;
    }

    /** The database for a fresh store of this kind, made empty for it and dropped by cleanup(). */
    public function db(string $kind, string $url): Db
    {
        $name = 'rl_conf_' . bin2hex(random_bytes(5));
        if ($kind === 'sqlite') {
            return Connect::sqlite(':memory:');
        }
        if ($kind === 'postgres') {
            $admin = Connect::postgres($url);
            $admin->run('CREATE SCHEMA ' . Connect::quoteName($name, '"'));
            $db = Connect::postgres($url, schema: $name);
            $this->cleanups[] = static function () use ($admin, $db, $name): void {
                $db->close();
                $admin->run('DROP SCHEMA IF EXISTS ' . Connect::quoteName($name, '"') . ' CASCADE');
                $admin->close();
            };
            return $db;
        }
        $admin = Connect::mysql($url);
        $admin->run('CREATE DATABASE ' . Connect::quoteName($name, '`'));
        $db = Connect::mysql(self::withDatabase($url, $name));
        $this->cleanups[] = static function () use ($admin, $db, $name): void {
            $db->close();
            $admin->run('DROP DATABASE IF EXISTS ' . Connect::quoteName($name, '`'));
            $admin->close();
        };
        return $db;
    }

    /**
     * A fresh store of this kind. Written against Runlight\Store\Stores::fromDb(Db $db), which wraps an
     * open Db as Stores::sqlite(), Stores::postgres(), and Stores::mysql() wrap the ones they open.
     */
    public function store(string $kind, string $url): mixed
    {
        return Stores::fromDb($this->db($kind, $url));
    }

    public function cleanup(): void
    {
        while ($this->cleanups !== []) {
            $clean = array_pop($this->cleanups);
            try {
                $clean();
            } catch (\Throwable $error) {
                error_log('Runlight conformance: could not drop a test database: ' . $error->getMessage());
            }
        }
    }

    /** The URL with its path naming another database. */
    public static function withDatabase(string $url, string $database): string
    {
        return (string) preg_replace('#^([a-z]+://[^/?\#]*)(/[^?\#]*)?#i', '$1/' . $database, $url, 1);
    }

    private static function env(string $name): ?string
    {
        $value = getenv($name);
        if ($value === false) {
            $value = $_ENV[$name] ?? $_SERVER[$name] ?? null;
        }
        return is_string($value) && trim($value) !== '' ? trim($value) : null;
    }
}
