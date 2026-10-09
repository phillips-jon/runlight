<?php

declare(strict_types=1);

namespace Runlight\Db;

use Runlight\Json;

/**
 * A Db over PDO, for SQLite, Postgres, and MySQL or MariaDB. The connection
 * is opened on first use, so a request that reads nothing never connects.
 */
final class PdoDb implements Db
{
    /** Arbitrary but fixed, so every Runlight process takes the same lock to create tables. */
    public const MIGRATION_LOCK = 7_331_906;

    private ?\PDO $pdo;
    /** @var (\Closure(): \PDO)|null */
    private ?\Closure $connect;
    private int $depth = 0;
    /** @var array<string, \PDOStatement> */
    private array $statements = [];

    /** @param \PDO|(\Closure(): \PDO) $pdo */
    public function __construct(\PDO|\Closure $pdo, private readonly string $dialect, private readonly bool $owned = true)
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
            $this->pdo = ($this->connect)();
            $this->prepare($this->pdo);
        }
        return $this->pdo;
    }

    public function all(string $sql, array $params = []): array
    {
        $statement = $this->execute($sql, $params);
        $rows = $statement->fetchAll(\PDO::FETCH_ASSOC);
        $statement->closeCursor();
        return $rows;
    }

    public function run(string $sql, array $params = []): void
    {
        $this->execute($sql, $params)->closeCursor();
    }

    public function transaction(callable $fn): mixed
    {
        if ($this->depth > 0) {
            return $fn($this);
        }
        $pdo = $this->pdo();
        $pdo->beginTransaction();
        $this->depth++;
        try {
            $result = $fn($this);
            $this->depth--;
            $pdo->commit();
            return $result;
        } catch (\Throwable $error) {
            $this->depth--;
            if ($pdo->inTransaction()) {
                $pdo->rollBack();
            }
            throw $error;
        }
    }

    public function exclusive(callable $fn): mixed
    {
        if ($this->dialect === 'sqlite') {
            // SQLite's file lock already serialises its writers.
            return $fn($this);
        }
        if ($this->dialect === 'postgres') {
            // Asked for again and again rather than waited on, so a waiting statement never holds up an
            // index being built CONCURRENTLY by whoever has the lock.
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
        while ((int) ($this->all('SELECT GET_LOCK(?, 0) AS ok', ['runlight_migrate'])[0]['ok'] ?? 0) !== 1) {
            usleep(100_000);
        }
        try {
            return $fn($this);
        } finally {
            try {
                $this->run('SELECT RELEASE_LOCK(?)', ['runlight_migrate']);
            } catch (\Throwable) {
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

    private function execute(string $sql, array $params): \PDOStatement
    {
        $pdo = $this->pdo();
        $statement = $this->statements[$sql] ??= $pdo->prepare($sql);
        if (count($this->statements) > 200) {
            $this->statements = [$sql => $statement];
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
        $statement->execute();
        return $statement;
    }

    private function prepare(\PDO $pdo): void
    {
        $pdo->setAttribute(\PDO::ATTR_ERRMODE, \PDO::ERRMODE_EXCEPTION);
        $pdo->setAttribute(\PDO::ATTR_DEFAULT_FETCH_MODE, \PDO::FETCH_ASSOC);
        if ($this->dialect === 'mysql') {
            $pdo->setAttribute(\PDO::ATTR_EMULATE_PREPARES, false);
        }
        if ($this->dialect === 'sqlite') {
            $pdo->setAttribute(\PDO::ATTR_TIMEOUT, 5);
        }
    }
}
