<?php

declare(strict_types=1);

namespace Runlight\Db;

/**
 * Opens the database a store keeps its tables in. Tables are prefixed `rl_`,
 * so the database can be the app's own.
 */
final class Connect
{
    /** A SQLite file, or ":memory:". */
    public static function sqlite(string $path): PdoDb
    {
        return new PdoDb(static function () use ($path): \PDO {
            $pdo = new \PDO("sqlite:$path");
            $pdo->exec('PRAGMA journal_mode = WAL');
            $pdo->exec('PRAGMA synchronous = NORMAL');
            $pdo->exec('PRAGMA busy_timeout = 5000');
            return $pdo;
        }, 'sqlite');
    }

    /**
     * Postgres from a URL like postgres://user:pass@host:5432/db?sslmode=require. `$statementTimeout`
     * stops any one statement after that many milliseconds; 0 turns it off.
     */
    public static function postgres(string $url, int $statementTimeout = 120_000, ?string $schema = null): PdoDb
    {
        $parts = self::parts($url);
        return new PdoDb(static function () use ($parts, $statementTimeout, $schema): \PDO {
            $dsn = sprintf('pgsql:host=%s;port=%d;dbname=%s', $parts['host'], $parts['port'] ?: 5432, $parts['database']);
            if (isset($parts['query']['sslmode'])) {
                $dsn .= ';sslmode=' . $parts['query']['sslmode'];
            }
            $pdo = new \PDO($dsn, $parts['user'], $parts['password'], [\PDO::ATTR_TIMEOUT => 10]);
            if ($statementTimeout > 0) {
                $pdo->exec('SET statement_timeout = ' . (int) $statementTimeout);
            }
            if ($schema !== null) {
                $pdo->exec('SET search_path TO ' . self::quoteName($schema, '"'));
            }
            return $pdo;
        }, 'postgres');
    }

    /** MySQL or MariaDB from a URL like mysql://user:pass@host:3306/db. */
    public static function mysql(string $url, int $statementTimeout = 120_000): PdoDb
    {
        $parts = self::parts($url);
        return new PdoDb(static function () use ($parts, $statementTimeout): \PDO {
            $dsn = sprintf('mysql:host=%s;port=%d;dbname=%s;charset=utf8mb4', $parts['host'], $parts['port'] ?: 3306, $parts['database']);
            $pdo = new \PDO($dsn, $parts['user'], $parts['password'], [\PDO::ATTR_TIMEOUT => 10]);
            $pdo->exec("SET NAMES utf8mb4 COLLATE utf8mb4_bin, time_zone = '+00:00', sql_mode = CONCAT(@@sql_mode, ',ANSI_QUOTES,NO_BACKSLASH_ESCAPES')");
            if ($statementTimeout > 0) {
                $version = (string) $pdo->query('SELECT VERSION()')->fetchColumn();
                // MariaDB counts seconds for read statements; MySQL counts milliseconds for SELECTs.
                $pdo->exec(str_contains(strtolower($version), 'mariadb')
                    ? 'SET SESSION max_statement_time = ' . ($statementTimeout / 1000)
                    : 'SET SESSION max_execution_time = ' . (int) $statementTimeout);
            }
            return $pdo;
        }, 'mysql');
    }

    /** Picks the database from a URL's scheme: sqlite:, file:, postgres:, postgresql:, mysql:, or mariadb:. */
    public static function url(string $url): PdoDb
    {
        $scheme = strtolower((string) parse_url($url, PHP_URL_SCHEME));
        return match ($scheme) {
            'postgres', 'postgresql' => self::postgres($url),
            'mysql', 'mariadb' => self::mysql($url),
            'sqlite', 'file' => self::sqlite(preg_replace('#^(sqlite|file):(//)?#i', '', $url) ?? $url),
            default => throw new \InvalidArgumentException('Runlight: DATABASE_URL must start with postgres://, mysql://, mariadb://, or sqlite:'),
        };
    }

    public static function quoteName(string $name, string $quote): string
    {
        return $quote . str_replace($quote, $quote . $quote, $name) . $quote;
    }

    /** @return array{host: string, port: int, user: ?string, password: ?string, database: string, query: array<string, string>} */
    private static function parts(string $url): array
    {
        $parts = parse_url($url);
        if ($parts === false || !isset($parts['host'])) {
            throw new \InvalidArgumentException('Runlight: the database URL could not be read');
        }
        parse_str($parts['query'] ?? '', $query);
        return [
            'host' => $parts['host'],
            'port' => (int) ($parts['port'] ?? 0),
            'user' => isset($parts['user']) ? rawurldecode($parts['user']) : null,
            'password' => isset($parts['pass']) ? rawurldecode($parts['pass']) : null,
            'database' => rawurldecode(ltrim($parts['path'] ?? '', '/')),
            'query' => array_map('strval', $query),
        ];
    }
}
