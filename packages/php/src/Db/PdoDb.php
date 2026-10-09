<?php

declare(strict_types=1);

namespace Runlight\Db;

use Runlight\Json;

/**
 * A Db over PDO, for SQLite, Postgres, and MySQL or MariaDB, doing per connection what the TypeScript
 * drivers do (stores/sqlite.ts, stores/postgres.ts, and stores/mysql.ts). The connection is opened on
 * first use, so a request that reads nothing never connects.
 *
 * SQL is written for SQLite and Postgres. On MySQL each statement goes through mysqlText() first, as the
 * TypeScript driver sends it: a "quoted" name in backticks, and a backslash inside 'text' doubled, since
 * MySQL reads it as an escape where standard SQL takes it literally. Values are filled in by PDO on the
 * client, as mysql2 fills them in.
 */
final class PdoDb implements Db
{
    /** Arbitrary but fixed, so every Runlight process takes the same lock to create tables. */
    public const MIGRATION_LOCK = 7_331_906;

    /** One lock per MySQL database, so installs sharing a server do not wait on each other. Lock names are 64 characters at most. */
    private const MYSQL_LOCK = "CONCAT('runlight:', LEFT(SHA2(COALESCE(DATABASE(), ''), 256), 48))";

    private ?\PDO $pdo;
    /** @var (\Closure(): \PDO)|null */
    private ?\Closure $connect;
    private int $depth = 0;
    /** @var array<string, \PDOStatement> */
    private array $statements = [];
    /** @var array<string, string> */
    private array $texts = [];
    private ?bool $mariadb = null;
    /** Above zero while exclusive() holds its lock on this connection. */
    private int $held = 0;

    /**
     * @param \PDO|(\Closure(): \PDO) $pdo a connection, or a function that opens one on first use
     * @param bool $owned whether close() may drop the connection (never one the app passed in)
     * @param int $statementTimeout MySQL only: the session's statement timeout in milliseconds, which
     *   exclusive() lifts while it builds tables and puts back after, as the TypeScript driver does for
     *   a pool it made. 0 when none was set.
     */
    public function __construct(\PDO|\Closure $pdo, private readonly string $dialect, private readonly bool $owned = true, private readonly int $statementTimeout = 0)
    {
        if (!in_array($dialect, ['sqlite', 'postgres', 'mysql'], true)) {
            throw new \InvalidArgumentException("Runlight: unknown database dialect $dialect");
        }
        $this->pdo = $pdo instanceof \PDO ? $pdo : null;
        $this->connect = $pdo instanceof \Closure ? $pdo : null;
        if ($this->pdo !== null) {
            $this->prepare($this->pdo);
        }
    }

    public function dialect(): string
    {
        return $this->dialect;
    }

    public function pdo(): \PDO
    {
        if ($this->pdo === null) {
            if ($this->connect === null) {
                throw new \RuntimeException('Runlight: the database connection is closed');
            }
            $this->pdo = ($this->connect)();
            $this->prepare($this->pdo);
        }
        return $this->pdo;
    }

    public function all(string $sql, array $params = []): array
    {
        $statement = $this->execute($sql, $params);
        // A statement that returns no rows (an INSERT through all(), as D1's driver allows) gives none.
        $rows = $statement->columnCount() > 0 ? $statement->fetchAll(\PDO::FETCH_ASSOC) : [];
        $statement->closeCursor();
        return $rows;
    }

    public function run(string $sql, array $params = []): void
    {
        $this->execute($sql, $params)->closeCursor();
    }

    /** Runs an UPDATE or DELETE and says how many rows it matched. The store asks this of MySQL, which has no RETURNING. */
    public function affected(string $sql, array $params = []): int
    {
        $statement = $this->execute($sql, $params);
        $count = $statement->rowCount();
        $statement->closeCursor();
        return $count;
    }

    public function transaction(callable $fn): mixed
    {
        if ($this->depth > 0) {
            return $fn($this);
        }
        $pdo = $this->pdo();
        if ($this->dialect === 'mysql') {
            // As Postgres does by default: each statement sees what was committed before it began, and
            // InnoDB takes no gap locks, so two writers to neighbouring rows do not deadlock.
            $pdo->exec('SET TRANSACTION ISOLATION LEVEL READ COMMITTED');
        }
        $pdo->beginTransaction();
        $this->depth++;
        try {
            $result = $fn($this);
            $this->depth--;
            $pdo->commit();
            return $result;
        } catch (\Throwable $error) {
            $this->depth = 0;
            try {
                if ($pdo->inTransaction()) {
                    $pdo->rollBack();
                }
            } catch (\Throwable) {
                // A connection still in its transaction must never be used again.
                $this->discard();
            }
            throw $error;
        }
    }

    public function exclusive(callable $fn): mixed
    {
        $this->held++;
        try {
            return $this->locked($fn);
        } finally {
            $this->held--;
        }
    }

    private function locked(callable $fn): mixed
    {
        if ($this->dialect === 'sqlite') {
            // SQLite's file lock already serialises its writers.
            return $fn($this);
        }
        if ($this->dialect === 'postgres') {
            // Asked for again and again rather than waited on: a waiting statement would hold up an index being
            // built CONCURRENTLY by whoever has the lock, and the two would wait on each other for good.
            while (!($this->all('SELECT pg_try_advisory_lock(?) AS ok', [self::MIGRATION_LOCK])[0]['ok'] ?? false)) {
                usleep(100_000);
            }
            try {
                return $fn($this);
            } finally {
                try {
                    $this->run('SELECT pg_advisory_unlock(?)', [self::MIGRATION_LOCK]);
                } catch (\Throwable) {
                    // A lost connection ends its session, and the lock with it.
                }
            }
        }
        $pdo = $this->pdo();
        for (;;) {
            $ok = $pdo->query('SELECT GET_LOCK(' . self::MYSQL_LOCK . ', 5) AS ok')->fetchColumn();
            if ($ok === null || $ok === false) {
                throw new \RuntimeException('Runlight: MySQL refused the lock for creating tables');
            }
            if ((int) $ok === 1) {
                break;
            }
            // Not got within 5 seconds: another process is creating the tables. Ask again.
        }
        try {
            // An index on a big table takes a while to build, so the build may run past the statement timeout.
            if ($this->statementTimeout > 0) {
                $this->limitStatements($pdo, 0);
            }
            $result = $fn($this);
            if ($this->statementTimeout > 0) {
                $this->limitStatements($pdo, $this->statementTimeout);
            }
            return $result;
        } catch (\Throwable $error) {
            // The session may be left without its statement timeout, so the connection goes.
            try {
                $pdo->exec('DO RELEASE_LOCK(' . self::MYSQL_LOCK . ')');
            } catch (\Throwable) {
            }
            $this->discard();
            throw $error;
        } finally {
            if ($this->pdo === $pdo) {
                try {
                    // A lost connection ends its session, and the lock with it.
                    $pdo->exec('DO RELEASE_LOCK(' . self::MYSQL_LOCK . ')');
                } catch (\Throwable) {
                }
            }
        }
    }

    public function close(): void
    {
        $this->statements = [];
        if ($this->owned) {
            $this->pdo = null;
        }
    }

    /**
     * MySQL's statement timeout as a session setting, which MySQL and MariaDB name differently. MariaDB
     * counts seconds and applies it to every statement; MySQL counts milliseconds and applies it to reads.
     */
    public function limitStatements(\PDO $pdo, int $ms): void
    {
        $this->mariadb ??= (bool) preg_match('/mariadb/i', (string) $pdo->query('SELECT VERSION() AS v')->fetchColumn());
        $pdo->exec($this->mariadb ? 'SET SESSION max_statement_time = ' . Json::number($ms / 1000) : "SET SESSION max_execution_time = $ms");
    }

    /**
     * SQL written for SQLite and Postgres, as MySQL and MariaDB read it: a "quoted" identifier is quoted with
     * backticks, and a backslash inside 'text' is doubled. With `$params`, each `?` outside quotes becomes its
     * value through `$escape`, as mysql2 fills them in; without, the placeholders stay for PDO.
     *
     * @param list<mixed>|null $params
     * @param (callable(mixed): string)|null $escape
     */
    public static function mysqlText(string $sql, ?array $params = null, ?callable $escape = null): string
    {
        $out = '';
        $n = 0;
        $quote = null;
        $length = strlen($sql);
        for ($i = 0; $i < $length; $i++) {
            $ch = $sql[$i];
            if ($quote !== null) {
                if ($ch === $quote) {
                    $quote = null;
                    $out .= $ch === '"' ? '`' : $ch;
                } elseif ($quote === "'" && $ch === '\\') {
                    $out .= '\\\\';
                } elseif ($quote === '"' && $ch === '`') {
                    $out .= '``';
                } else {
                    $out .= $ch;
                }
            } elseif ($ch === "'" || $ch === '"' || $ch === '`') {
                $quote = $ch;
                $out .= $ch === '"' ? '`' : $ch;
            } elseif ($ch === '?' && $params !== null) {
                if ($n >= count($params)) {
                    throw new \InvalidArgumentException('Runlight: a statement has more placeholders than values');
                }
                $out .= ($escape ?? self::escape(...))($params[$n++]);
            } else {
                $out .= $ch;
            }
        }
        if ($params !== null && $n !== count($params)) {
            throw new \InvalidArgumentException('Runlight: a statement has more values than placeholders');
        }
        return $out;
    }

    /** A value as a MySQL literal, as mysql2's escape() writes the values Runlight binds. */
    private static function escape(mixed $value): string
    {
        return match (true) {
            $value === null => 'NULL',
            is_bool($value) => $value ? 'true' : 'false',
            is_int($value) => (string) $value,
            is_float($value) => Json::number($value),
            default => "'" . strtr((string) $value, ["\0" => '\\0', "\x08" => '\\b', "\t" => '\\t', "\x1a" => '\\Z', "\n" => '\\n', "\r" => '\\r', '"' => '\\"', "'" => "\\'", '\\' => '\\\\']) . "'",
        };
    }

    /** Drops a connection left in a state it could not undo; the next statement opens a new one. */
    private function discard(): void
    {
        $this->statements = [];
        if ($this->connect !== null) {
            $this->pdo = null;
        }
    }

    private function execute(string $sql, array $params): \PDOStatement
    {
        try {
            return $this->attempt($sql, $params);
        } catch (\PDOException $error) {
            // A connection the server dropped (a restart, a failover, an idle timeout) is replaced, as a pool
            // replaces it, and the statement sent again: it never reached the server. Not inside a transaction
            // or a lock, whose work went with the connection.
            if ($this->depth > 0 || $this->held > 0 || $this->connect === null || $this->dialect === 'sqlite' || !self::lost($error)) {
                throw $error;
            }
            error_log('Runlight: a ' . ($this->dialect === 'mysql' ? 'MySQL' : 'Postgres') . ' connection was lost; it reconnects on the next query. ' . $error->getMessage());
            $this->discard();
            return $this->attempt($sql, $params);
        }
    }

    /** Whether an error says the connection is gone, rather than that the statement failed. */
    private static function lost(\PDOException $error): bool
    {
        $state = (string) ($error->errorInfo[0] ?? $error->getCode());
        $code = (int) ($error->errorInfo[1] ?? 0);
        return str_starts_with($state, '08') || in_array($state, ['57P01', '57P02', '57P03'], true) || in_array($code, [2006, 2013, 4031], true)
            || (bool) preg_match('/server has gone away|lost connection|server closed the connection|no connection to the server|terminating connection/i', $error->getMessage());
    }

    private function attempt(string $sql, array $params): \PDOStatement
    {
        $pdo = $this->pdo();
        if ($this->dialect === 'mysql') {
            $text = $this->texts[$sql] ??= self::mysqlText($sql);
            if (count($this->texts) > 500) {
                $this->texts = [$sql => $text];
            }
        } else {
            $text = $sql;
        }
        $statement = $this->statements[$text] ??= $pdo->prepare($text);
        if (count($this->statements) > 200) {
            $this->statements = [$text => $statement];
        }
        foreach (array_values($params) as $i => $value) {
            $type = match (true) {
                $value === null => \PDO::PARAM_NULL,
                is_int($value) => \PDO::PARAM_INT,
                is_bool($value) => \PDO::PARAM_BOOL,
                default => \PDO::PARAM_STR,
            };
            // A float is bound as text, which every database reads back as the same number.
            $statement->bindValue($i + 1, is_float($value) ? Json::number($value) : $value, $type);
        }
        try {
            $statement->execute();
        } catch (\PDOException $error) {
            // A statement that failed is not used again: SQLite refuses to run one left mid-step.
            unset($this->statements[$text]);
            throw $error;
        }
        return $statement;
    }

    private function prepare(\PDO $pdo): void
    {
        $pdo->setAttribute(\PDO::ATTR_ERRMODE, \PDO::ERRMODE_EXCEPTION);
        $pdo->setAttribute(\PDO::ATTR_DEFAULT_FETCH_MODE, \PDO::FETCH_ASSOC);
        if ($this->dialect === 'mysql') {
            // Values are written into the statement on the client, as mysql2 sends them.
            $pdo->setAttribute(\PDO::ATTR_EMULATE_PREPARES, true);
        }
        if ($this->dialect === 'sqlite') {
            $pdo->setAttribute(\PDO::ATTR_TIMEOUT, 5);
        }
    }
}
