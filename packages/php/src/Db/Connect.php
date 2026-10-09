<?php

declare(strict_types=1);

namespace Runlight\Db;

use Runlight\Json;

/**
 * Opens the database a store keeps its tables in, set up per connection as the TypeScript drivers set up
 * theirs. Tables are prefixed `rl_`, so the database can be the app's own.
 */
final class Connect
{
    /** A SQLite file, or ":memory:", with the pragmas stores/sqlite.ts sets. */
    public static function sqlite(string $path): PdoDb
    {
        return new PdoDb(static function () use ($path): \PDO {
            // better-sqlite3 waits up to five seconds for a lock from the moment it opens, pragmas included.
            $pdo = new \PDO("sqlite:$path", null, null, [\PDO::ATTR_TIMEOUT => 5]);
            $pdo->exec('PRAGMA journal_mode = WAL');
            $pdo->exec('PRAGMA synchronous = NORMAL');
            $pdo->exec('PRAGMA busy_timeout = 5000');
            return $pdo;
        }, 'sqlite');
    }

    /**
     * Postgres from a URL like postgres://user:pass@host:5432/db?sslmode=require. `$statementTimeout`
     * stops any one statement after that many milliseconds; 0 turns it off. It is set when the connection
     * starts, as pg's `statement_timeout` option sets it, so `RESET statement_timeout` comes back to it.
     * `$schema`, when given, is the search path, as `options=-c search_path=...` sets it for pg.
     */
    public static function postgres(string $url, int $statementTimeout = 120_000, ?string $schema = null): PdoDb
    {
        $parts = self::parts($url);
        return new PdoDb(static function () use ($parts, $statementTimeout, $schema): \PDO {
            $dsn = sprintf('pgsql:host=%s;port=%d;dbname=%s', $parts['host'], $parts['port'] ?: 5432, $parts['database']);
            if (isset($parts['query']['sslmode'])) {
                $dsn .= ';sslmode=' . $parts['query']['sslmode'];
            }
            // Settings in the URL's own `options` (`?options=-c search_path=x`), as pg takes them, come first.
            $options = isset($parts['query']['options']) ? [$parts['query']['options']] : [];
            if ($statementTimeout > 0) {
                $options[] = '-c statement_timeout=' . $statementTimeout;
            }
            if ($schema !== null) {
                $options[] = '-c search_path=' . self::option($schema);
            }
            if ($options) {
                $dsn .= ";options='" . implode(' ', $options) . "'";
            }
            // A connection waits at most 10 seconds for the server, as the pool waits for a connection.
            return new \PDO($dsn, $parts['user'], $parts['password'], [\PDO::ATTR_TIMEOUT => 10]);
        }, 'postgres');
    }

    /**
     * MySQL 8.4 or MariaDB 11.4 and later from a URL like mysql://user:pass@host:3306/db (or mariadb://).
     * The session is the one mysql2 opens: utf8mb4 with the server's default collation for it, and the
     * server's own SQL mode with IGNORE_SPACE added, which mysql2 asks for when it connects. Runlight's
     * tables carry their own binary collation, so text compares and sorts by code point. `$statementTimeout`
     * is set per connection as stores/mysql.ts sets it; 0 turns it off.
     */
    public static function mysql(string $url, int $statementTimeout = 120_000): PdoDb
    {
        $parts = self::parts((string) preg_replace('/^mariadb:/i', 'mysql:', $url));
        return new PdoDb(static function () use ($parts, $statementTimeout): \PDO {
            $dsn = sprintf('mysql:host=%s;port=%d;dbname=%s;charset=utf8mb4', $parts['host'], $parts['port'] ?: 3306, $parts['database']);
            $ignoreSpace = defined('Pdo\Mysql::ATTR_IGNORE_SPACE') ? \Pdo\Mysql::ATTR_IGNORE_SPACE : \PDO::MYSQL_ATTR_IGNORE_SPACE;
            $pdo = new \PDO($dsn, $parts['user'], $parts['password'], [\PDO::ATTR_TIMEOUT => 10, $ignoreSpace => true]);
            if ($statementTimeout > 0) {
                $mariadb = (bool) preg_match('/mariadb/i', (string) $pdo->query('SELECT VERSION() AS v')->fetchColumn());
                $pdo->exec($mariadb
                    ? 'SET SESSION max_statement_time = ' . Json::number($statementTimeout / 1000)
                    : 'SET SESSION max_execution_time = ' . $statementTimeout);
            }
            return $pdo;
        }, 'mysql', true, $statementTimeout);
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

    /** A value inside libpq's `options`, where a space or backslash is escaped with a backslash. */
    private static function option(string $value): string
    {
        return (string) preg_replace('/([\\\\\s\'])/', '\\\\$1', $value);
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
