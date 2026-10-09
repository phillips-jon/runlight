<?php

declare(strict_types=1);

namespace Runlight\Server;

use Runlight\Geo;
use Runlight\Mmdb;

/**
 * Location for servers with no platform headers (Cloudflare, Vercel, and Netlify send their own, and those always
 * win), from DB-IP's free databases (CC BY 4.0, https://db-ip.com). This is the port of the Geo class in
 * packages/server/src/geo.ts, split as PHP needs it: `runlight cron` downloads each month's release with
 * refresh(), and requests read the newest file on disk with lookup(), a page at a time.
 */
final class DbIp
{
    /** @var callable(string, string): bool */
    private $download;
    /** @var callable(string): void */
    private $log;

    /**
     * @param 'city'|'country' $mode
     * @param (callable(string $url, string $file): bool)|null $download writes the gzipped file at the URL to
     *     the file, and says whether it got one; curl by default
     * @param (callable(string): void)|null $log
     */
    public function __construct(
        private readonly string $dir,
        private readonly string $mode,
        ?callable $download = null,
        ?callable $log = null,
    ) {
        $this->download = $download ?? self::curl(...);
        $this->log = $log ?? static function (string $line): void {
            error_log($line);
        };
    }

    /** "2026-10", the month DB-IP names each release after. */
    public static function month(int $ms): string
    {
        return gmdate('Y-m', intdiv($ms, 1000));
    }

    private function file(string $release): string
    {
        return "{$this->dir}/dbip-{$this->mode}-lite-{$release}.mmdb";
    }

    /** The newest release on disk, or null before the first download. */
    public function newest(): ?string
    {
        $found = glob("{$this->dir}/dbip-{$this->mode}-lite-*.mmdb") ?: [];
        sort($found);
        return $found === [] ? null : end($found);
    }

    /**
     * A lookup answering from the newest release on disk, opened at the first lookup, or null when there is none
     * yet. Lookups that fail answer nothing, as they do before the first download in TypeScript.
     *
     * @return (\Closure(string): ?array)|null
     */
    public function lookup(): ?\Closure
    {
        $file = $this->newest();
        if ($file === null) {
            return null;
        }
        $lookup = null;
        return static function (string $ip) use ($file, &$lookup): ?array {
            try {
                $lookup ??= Geo::lookupFrom(Mmdb::open($file));
            } catch (\Throwable) {
                return null;
            }
            return $lookup($ip);
        };
    }

    /**
     * Fetches this month's release when it is missing. A new month's file appears a day or so after the month
     * starts, so until then last month's is fetched when that is missing too. Older releases go once a new
     * one is ready. Safe to call often: once this month's file is there it reads only the folder.
     */
    public function refresh(int $now): void
    {
        $current = self::month($now);
        if (is_file($this->file($current))) {
            return;
        }
        if (!is_dir($this->dir) && !@mkdir($this->dir, 0755, true) && !is_dir($this->dir)) {
            ($this->log)("Runlight: could not make the folder for location data, {$this->dir}");
            return;
        }
        $seconds = intdiv($now, 1000);
        $previous = self::month((int) gmmktime(0, 0, 0, (int) gmdate('n', $seconds) - 1, 15, (int) gmdate('Y', $seconds)) * 1000);
        foreach ([$current, $previous] as $release) {
            if (is_file($this->file($release))) {
                return;
            }
            $url = "https://download.db-ip.com/free/dbip-{$this->mode}-lite-{$release}.mmdb.gz";
            $gz = $this->file($release) . '.gz.partial';
            $partial = $this->file($release) . '.partial';
            try {
                if (!($this->download)($url, $gz)) {
                    continue;
                }
                self::gunzip($gz, $partial);
                // A file that does not open as a database is never kept.
                Mmdb::open($partial);
                rename($partial, $this->file($release));
                foreach (glob("{$this->dir}/dbip-{$this->mode}-lite-*") ?: [] as $old) {
                    if ($old !== $this->file($release)) {
                        @unlink($old);
                    }
                }
                ($this->log)("Runlight: location data from DB-IP ($release) is ready.");
                return;
            } catch (\Throwable $error) {
                ($this->log)("Runlight: could not download location data from $url: {$error->getMessage()}");
            } finally {
                @unlink($gz);
                @unlink($partial);
            }
        }
    }

    private static function gunzip(string $from, string $to): void
    {
        $in = gzopen($from, 'rb');
        $out = fopen($to, 'wb');
        if ($in === false || $out === false) {
            throw new \RuntimeException("could not unpack $from");
        }
        try {
            while (!gzeof($in)) {
                $chunk = gzread($in, 1 << 20);
                if ($chunk === false) {
                    throw new \RuntimeException("could not unpack $from");
                }
                fwrite($out, $chunk);
            }
        } finally {
            gzclose($in);
            fclose($out);
        }
    }

    /**
     * Downloads a file straight to disk, since a city database is too big to hold in memory. This is the one
     * download that does not go through a Fetcher, which keeps whole answers in memory.
     */
    private static function curl(string $url, string $file): bool
    {
        $out = fopen($file, 'wb');
        if ($out === false) {
            throw new \RuntimeException("could not write $file");
        }
        try {
            if (!function_exists('curl_init')) {
                $in = @fopen($url, 'rb', false, stream_context_create(['http' => ['timeout' => 600, 'ignore_errors' => false]]));
                if ($in === false) {
                    return false;
                }
                stream_copy_to_stream($in, $out);
                fclose($in);
                return true;
            }
            $handle = curl_init($url);
            curl_setopt_array($handle, [
                CURLOPT_FILE => $out,
                CURLOPT_FOLLOWLOCATION => true,
                CURLOPT_FAILONERROR => true,
                CURLOPT_TIMEOUT => 600,
                CURLOPT_CONNECTTIMEOUT => 15,
                CURLOPT_PROTOCOLS => CURLPROTO_HTTPS,
                CURLOPT_REDIR_PROTOCOLS => CURLPROTO_HTTPS,
            ]);
            $ok = curl_exec($handle);
            $status = (int) curl_getinfo($handle, CURLINFO_RESPONSE_CODE);
            $error = curl_error($handle);
            if ($ok === false && $status === 0) {
                throw new \RuntimeException($error !== '' ? $error : 'no answer');
            }
            return $ok !== false && $status === 200;
        } finally {
            fclose($out);
        }
    }
}
