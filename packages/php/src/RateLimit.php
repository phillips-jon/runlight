<?php

declare(strict_types=1);

namespace Runlight;

/**
 * Counts tracker requests per address in fixed one-minute windows. Addresses
 * are hashed with a key made each day, so the count never holds an IP, each
 * window's counts are dropped when it ends, and yesterday's key goes with them,
 * so no leftover hash can be matched to an address by trying them all.
 *
 * PHP forgets everything between requests, so the counts live where requests
 * can share them: APCu when it is loaded, or else one small file per window in
 * the system's temporary folder. Several servers behind a load balancer each
 * count on their own, as the TypeScript SDK's processes do.
 */
final class RateLimit
{
    /** @var array<string, int> counts kept in this process, used when neither APCu nor a temporary folder works */
    private array $counts = [];
    private int $window = 0;
    /** @var array<string, string> today's key by its file, read once per process */
    private static array $keys = [];
    private ?string $ownKey = null;

    /**
     * @param callable(): int $now milliseconds
     * @param bool $shared whether to share counts with other requests through APCu or the temporary folder; a
     *   Runlight on a clock given in code (tests, replays) counts on its own, since the same minutes come again
     */
    public function __construct(private readonly int $perMinute, private $now, private readonly ?string $dir = null, private readonly bool $shared = true)
    {
    }

    /** True while this address is under its limit for the current minute. */
    public function allow(string $ip): bool
    {
        // No address cannot be told apart, so it is not limited.
        if ($ip === '') {
            return true;
        }
        $ms = ($this->now)();
        $window = intdiv($ms, 60_000);
        $id = substr(hash('sha256', $this->key(intdiv($ms, 86_400_000)) . $ip), 0, 16);
        if ($this->shared && self::apcu()) {
            $name = "runlight:rl:$window:$id";
            apcu_add($name, 0, 120);
            $count = apcu_inc($name);
            if ($count !== false) {
                return $count <= $this->perMinute;
            }
        }
        $count = $this->shared ? $this->countInFile($window, $id) : null;
        if ($count !== null) {
            return $count <= $this->perMinute;
        }
        if ($window !== $this->window) {
            $this->window = $window;
            $this->counts = [];
        }
        $this->counts[$id] = ($this->counts[$id] ?? 0) + 1;
        return $this->counts[$id] <= $this->perMinute;
    }

    /**
     * Deletes the windows that have ended and every key but today's. Each counted request does this, and the
     * scheduled check does too, so the files go even once the requests stop.
     */
    public function sweep(): void
    {
        if (!$this->shared) {
            return;
        }
        $ms = ($this->now)();
        $window = intdiv($ms, 60_000);
        $today = 'key-' . intdiv($ms, 86_400_000);
        foreach (glob($this->folder() . '/*') ?: [] as $old) {
            $name = basename($old);
            // A bare "key" is one an earlier version kept for good.
            $stale = preg_match('/^[0-9]+\z/', $name) ? (int) $name < $window - 1 : ($name === 'key' || (str_starts_with($name, 'key-') && $name !== $today));
            if ($stale) {
                @unlink($old);
            }
        }
    }

    private function folder(): string
    {
        return ($this->dir ?? sys_get_temp_dir()) . '/runlight-rate';
    }

    private static function apcu(): bool
    {
        return function_exists('apcu_enabled') && apcu_enabled();
    }

    private function countInFile(int $window, string $id): ?int
    {
        $dir = $this->folder();
        if (!is_dir($dir) && !@mkdir($dir, 0700, true) && !is_dir($dir)) {
            return null;
        }
        $file = "$dir/$window";
        $handle = @fopen($file, 'c+');
        if ($handle === false) {
            return null;
        }
        try {
            flock($handle, LOCK_EX);
            $counts = json_decode((string) stream_get_contents($handle), true);
            $counts = is_array($counts) ? $counts : [];
            $counts[$id] = (int) ($counts[$id] ?? 0) + 1;
            ftruncate($handle, 0);
            rewind($handle);
            fwrite($handle, (string) json_encode($counts));
            fflush($handle);
            flock($handle, LOCK_UN);
        } finally {
            fclose($handle);
        }
        $this->sweep();
        return $counts[$id];
    }

    /**
     * Today's key, shared by every request on the server, so the hashes cannot be turned back into addresses
     * without it. A limiter that counts on its own keeps a key of its own in memory.
     */
    private function key(int $day): string
    {
        if (!$this->shared) {
            return $this->ownKey ??= random_bytes(16);
        }
        $dir = $this->folder();
        $file = "$dir/key-$day";
        if (isset(self::$keys[$file])) {
            return self::$keys[$file];
        }
        if (self::apcu()) {
            $name = "runlight:rl:key:$day";
            $stored = apcu_fetch($name);
            if (!is_string($stored)) {
                apcu_add($name, random_bytes(16), 2 * 86_400);
                $stored = apcu_fetch($name);
            }
            if (is_string($stored)) {
                return self::$keys[$file] = $stored;
            }
        }
        $made = random_bytes(16);
        if (!is_dir($dir) && !@mkdir($dir, 0700, true) && !is_dir($dir)) {
            return self::$keys[$file] = $made;
        }
        $handle = @fopen($file, 'c+');
        if ($handle === false) {
            return self::$keys[$file] = $made;
        }
        try {
            // Readable by the owner alone before anything is in it, and written under a lock so two first
            // requests agree.
            @chmod($file, 0600);
            flock($handle, LOCK_EX);
            $stored = (string) stream_get_contents($handle);
            if (strlen($stored) !== 16) {
                ftruncate($handle, 0);
                rewind($handle);
                fwrite($handle, $made);
                fflush($handle);
                $stored = $made;
            }
            flock($handle, LOCK_UN);
        } finally {
            fclose($handle);
        }
        return self::$keys[$file] = $stored;
    }
}
