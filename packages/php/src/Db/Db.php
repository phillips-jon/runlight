<?php

declare(strict_types=1);

namespace Runlight\Db;

/**
 * The little a store needs from a database. SQL uses `?` placeholders on
 * every dialect. Rows come back as arrays keyed by column name; numbers may
 * arrive as strings, so the store casts what it reads.
 */
interface Db
{
    /** "sqlite", "postgres", or "mysql". */
    public function dialect(): string;

    /** @return list<array<string, mixed>> */
    public function all(string $sql, array $params = []): array;

    public function run(string $sql, array $params = []): void;

    /**
     * Runs `$fn` in one transaction, committed when it returns and rolled back
     * when it throws. A transaction already open is joined, not nested.
     *
     * @template T
     * @param callable(Db): T $fn
     * @return T
     */
    public function transaction(callable $fn): mixed;

    /**
     * Runs `$fn` while holding a database-wide lock, so two processes starting
     * at once do not race to create the same tables.
     *
     * @template T
     * @param callable(Db): T $fn
     * @return T
     */
    public function exclusive(callable $fn): mixed;

    public function close(): void;
}
