<?php

declare(strict_types=1);

namespace Runlight\Tests\Store;

use Runlight\Db\Db;
use Runlight\Db\PdoDb;

/**
 * A Db that lets a test see, and step into, every statement: as the TypeScript tests replace db.run and
 * db.all on a store. Statements inside a transaction or lock go through it too.
 */
final class WatchedDb implements Db
{
    /** @var (\Closure(string, array): void)|null Called before each statement. */
    public ?\Closure $before = null;
    /** @var (\Closure(string, array): void)|null Called after each run(). */
    public ?\Closure $afterRun = null;

    public function __construct(public readonly Db $inner)
    {
    }

    public function dialect(): string
    {
        return $this->inner->dialect();
    }

    public function all(string $sql, array $params = []): array
    {
        if ($this->before) {
            ($this->before)($sql, $params);
        }
        return $this->inner->all($sql, $params);
    }

    public function run(string $sql, array $params = []): void
    {
        if ($this->before) {
            ($this->before)($sql, $params);
        }
        $this->inner->run($sql, $params);
        if ($this->afterRun) {
            ($this->afterRun)($sql, $params);
        }
    }

    public function affected(string $sql, array $params = []): int
    {
        if ($this->before) {
            ($this->before)($sql, $params);
        }
        $inner = $this->inner;
        if (!$inner instanceof PdoDb) {
            throw new \LogicException('affected() needs a PdoDb');
        }
        return $inner->affected($sql, $params);
    }

    public function transaction(callable $fn): mixed
    {
        return $this->inner->transaction(fn (Db $_) => $fn($this));
    }

    public function exclusive(callable $fn): mixed
    {
        return $this->inner->exclusive(fn (Db $_) => $fn($this));
    }

    public function close(): void
    {
        $this->inner->close();
    }
}
