<?php

declare(strict_types=1);

namespace Runlight;

/**
 * Counts tracker requests per address in fixed one-minute windows. Addresses
 * are hashed with a key made once per server, so the count never holds an IP,
 * and each window's counts are dropped when it ends.
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
        $window = intdiv(($this->now)(), 60_000);
        $id = substr(hash('sha256', self::key() . $ip), 0, 16);
        if ($this->shared && function_exists('apcu_enabled') && apcu_enabled()) {
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

    private function countInFile(int $window, string $id): ?int
    {
        $dir = ($this->dir ?? sys_get_temp_dir()) . '/runlight-rate';
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
        // Earlier windows are no longer needed.
        foreach (glob("$dir/*") ?: [] as $old) {
            if ((int) basename($old) < $window - 1) {
                @unlink($old);
            }
        }
        return $counts[$id];
    }

    /** A key made once and kept beside the counts, so the hashes cannot be turned back into addresses without it. */
    private static function key(): string
    {
        static $key = null;
        if ($key !== null) {
            return $key;
        }
        if (function_exists('apcu_enabled') && apcu_enabled()) {
            $stored = apcu_fetch('runlight:rl:key');
            if (is_string($stored)) {
                return $key = $stored;
            }
            $made = random_bytes(16);
            apcu_add('runlight:rl:key', $made);
            $stored = apcu_fetch('runlight:rl:key');
            return $key = is_string($stored) ? $stored : $made;
        }
        $file = sys_get_temp_dir() . '/runlight-rate/key';
        $stored = @file_get_contents($file);
        if (is_string($stored) && strlen($stored) === 16) {
            return $key = $stored;
        }
        $made = random_bytes(16);
        @mkdir(dirname($file), 0700, true);
        if (@file_put_contents($file, $made, LOCK_EX) !== false) {
            @chmod($file, 0600);
        }
        return $key = $made;
    }
}
