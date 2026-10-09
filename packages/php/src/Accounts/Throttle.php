<?php

declare(strict_types=1);

namespace Runlight\Accounts;

use Runlight\Hash;
use Runlight\Json;
use Runlight\Store\SqlStore;

/**
 * Counts failed sign-ins under a key and refuses more than a few in a while.
 * Keys are hashed with a key made on first use, so the counts never hold an
 * address or an email as it was given.
 *
 * TypeScript keeps the counts in its process. PHP forgets everything between
 * requests, so here they live in the database's settings, as
 * "throttle:<name>:<id>" holding {count, until}, and the hashing key as
 * "throttle-key". Every process of an install then shares the same counts.
 */
final class Throttle
{
    private const KEY = 'throttle-key';

    public function __construct(
        private readonly SqlStore $store,
        private readonly string $name,
        private readonly int $limit = 10,
        private readonly int $windowMs = 15 * 60_000,
    ) {
    }

    private function salt(): string
    {
        $saved = $this->store->setting(self::KEY);
        if ($saved !== null && $saved !== '') {
            return $saved;
        }
        $made = Hash::randomId(16);
        $this->store->setSetting(self::KEY, $made);
        return $made;
    }

    private function id(string $key): string
    {
        return substr(Crypto::base64url(Crypto::hmac('SHA-256', $this->salt(), $key)), 0, 22);
    }

    private function prefix(): string
    {
        return "throttle:$this->name:";
    }

    /** @return array{count: int, until: int}|null */
    private function entry(string $id): ?array
    {
        $saved = $this->store->setting($this->prefix() . $id);
        $entry = $saved === null ? null : Json::tryDecode($saved, true);
        return is_array($entry) ? ['count' => (int) ($entry['count'] ?? 0), 'until' => (int) ($entry['until'] ?? 0)] : null;
    }

    /** @param array{count: int, until: int} $entry */
    private function save(string $id, array $entry): void
    {
        $this->store->setSetting($this->prefix() . $id, Json::encode($entry));
    }

    public function blocked(string $key, int $now): bool
    {
        return $this->isBlocked($this->id($key), $now);
    }

    private function isBlocked(string $id, int $now): bool
    {
        $entry = $this->entry($id);
        if ($entry === null || $entry['until'] <= $now) {
            return false;
        }
        return $entry['count'] >= $this->limit;
    }

    /**
     * Counts a try before the slow check it guards, so a burst that arrives
     * while earlier tries are still being checked cannot get past the limit.
     * False, counting nothing, when the key is already at its limit. A try
     * that turns out right is taken back with forgive().
     */
    public function take(string $key, int $now): bool
    {
        $id = $this->id($key);
        if ($this->isBlocked($id, $now)) {
            return false;
        }
        $this->count($id, $now);
        return true;
    }

    /** Takes back one counted try, for one that turned out right. */
    public function forgive(string $key): void
    {
        $id = $this->id($key);
        $entry = $this->entry($id);
        if ($entry !== null && $entry['count'] > 0) {
            $entry['count']--;
            $this->save($id, $entry);
        }
    }

    public function fail(string $key, int $now): void
    {
        $this->count($this->id($key), $now);
    }

    private function count(string $id, int $now): void
    {
        $entry = $this->entry($id);
        if ($entry === null || $entry['until'] <= $now) {
            $this->save($id, ['count' => 1, 'until' => $now + $this->windowMs]);
            $this->prune($now);
            return;
        }
        $entry['count']++;
        $this->save($id, $entry);
    }

    /**
     * Expired entries go first, then the oldest that are not blocked, and blocked ones last, so the counts
     * have a hard ceiling and a flood of made-up names cannot wipe out a real block. Run when a new entry is
     * made, since only then can there be more.
     */
    private function prune(int $now): void
    {
        $entries = [];
        foreach ($this->store->settingsStartingWith($this->prefix()) as ['key' => $key, 'value' => $value]) {
            $entry = Json::tryDecode($value, true);
            $until = is_array($entry) ? (int) ($entry['until'] ?? 0) : 0;
            if ($until <= $now) {
                $this->store->setSetting($key, null);
                continue;
            }
            $entries[] = ['key' => $key, 'until' => $until, 'blocked' => is_array($entry) && (int) ($entry['count'] ?? 0) >= $this->limit];
        }
        $size = count($entries);
        if ($size <= Accounts::MAX_THROTTLED) {
            return;
        }
        // Oldest first: each entry's window started windowMs before its end.
        usort($entries, static fn (array $a, array $b): int => $a['until'] <=> $b['until']);
        foreach ([false, true] as $blocked) {
            foreach ($entries as $entry) {
                if ($size <= Accounts::MAX_THROTTLED) {
                    return;
                }
                if ($entry['blocked'] === $blocked) {
                    $this->store->setSetting($entry['key'], null);
                    $size--;
                }
            }
        }
    }

    public function clear(string $key): void
    {
        $this->store->setSetting($this->prefix() . $this->id($key), null);
    }
}
