<?php

declare(strict_types=1);

namespace Runlight\Server;

use Runlight\Http\CurlFetcher;
use Runlight\Http\Fetcher;
use Runlight\Http\Url;
use Runlight\Importers\Http as ImportHttp;
use Runlight\Js;
use Runlight\Json;
use Runlight\Ua;
use Runlight\Undefined;

/**
 * vendor/bin/runlight agents: counts AI agents on a site that has only the script
 * tag, by reading its web server's access log. Agents do not run JavaScript, so
 * the tracker never sees them; the server that answered them did.
 *
 * It reads nginx and Apache's combined format and Caddy's JSON lines, keeps
 * successful GETs from known AI agents, and sends them in batches to a
 * Runlight's /api/observe with the site's observe key. Nothing else in the log
 * leaves the machine. With follow it keeps reading as the log grows and
 * carries on after the log is rotated. Without it, it reads what is new and
 * stops, for cron. In both modes the state file remembers how far it read, so the
 * next run, or a restarted follow, carries on from there.
 *
 * The port of the Node server's agents.ts. A fetch is an array of url, userAgent, and at (epoch milliseconds).
 */
final class Agents
{
    private const MONTHS = ['Jan' => 0, 'Feb' => 1, 'Mar' => 2, 'Apr' => 3, 'May' => 4, 'Jun' => 5, 'Jul' => 6, 'Aug' => 7, 'Sep' => 8, 'Oct' => 9, 'Nov' => 10, 'Dec' => 11];

    /** JavaScript's \S, which also leaves out Unicode spaces. */
    private const S = '[^' . Js::SPACE . ']';

    // host? ip - user [time] "METHOD /path HTTP/x" status bytes "referrer" "user agent"
    private const COMBINED = '/^(?:(' . self::S . '+) )?' . self::S . '+ ' . self::S . '+ ' . self::S . '+ \[([^\]]+)\] "(' . self::S . '+) (' . self::S . '+)[^"]*" ([0-9]{3}) ' . self::S . '+ "(?:[^"\\\\]|\\\\[^\n\r\x{2028}\x{2029}])*" "((?:[^"\\\\]|\\\\[^\n\r\x{2028}\x{2029}])*)"/u';

    /** A request line and status, in a line that might be a combined log line without its host. */
    private const REQUEST = '/"' . self::S . '+ \/' . self::S . '* [^"]*" [0-9]{3}/u';

    /** The most fetches /api/observe takes at once. */
    public const BATCH = 500;

    /** The most of a log read at once, so a log of any size fits in memory a piece at a time. */
    private const CHUNK = 32 * 1024 * 1024;

    /** How many bytes at the start of a log identify it. */
    private const HEAD = 256;

    /**
     * A request target as a page on the site. Absolute targets ("GET http://other/x", a proxy
     * request) name somewhere else and are skipped. The target is set as the path and query of the
     * site's own address, never parsed as a URL, so "//x" and "/\x" stay paths on the site.
     */
    private static function pageUrl(string $target, string $base): ?string
    {
        if (!str_starts_with($target, '/')) {
            return null;
        }
        $url = Url::parse($base);
        if ($url === null) {
            return null;
        }
        $query = strpos($target, '?');
        $url->setPathname('/' . ltrim($query === false ? $target : substr($target, 0, $query), '/'));
        $url->setSearch($query === false ? '' : substr($target, $query));
        $url->hash = '';
        return $url->href();
    }

    /** "07/Oct/2026:13:55:36 -0400" as epoch milliseconds, or NAN. */
    private static function logTime(string $value): int|float
    {
        if (!preg_match('/^(\d{2})\/(\w{3})\/(\d{4}):(\d{2}):(\d{2}):(\d{2}) ([+-])(\d{2})(\d{2})$/D', $value, $m) || !isset(self::MONTHS[$m[2]])) {
            return NAN;
        }
        // Date.UTC reads years 0 to 99 as 1900 to 1999, and lets days and hours run on past their end.
        $year = (int) $m[3];
        $year += $year <= 99 ? 1900 : 0;
        $days = self::daysFromCivil($year, self::MONTHS[$m[2]] + 1) + (int) $m[1] - 1;
        $local = ((($days * 24 + (int) $m[4]) * 60 + (int) $m[5]) * 60 + (int) $m[6]) * 1000;
        $offset = ((int) $m[8] * 60 + (int) $m[9]) * 60_000 * ($m[7] === '-' ? -1 : 1);
        return $local - $offset;
    }

    /** Days from 1970-01-01 to the first of this month. */
    private static function daysFromCivil(int $year, int $month): int
    {
        $y = $month <= 2 ? $year - 1 : $year;
        $era = intdiv($y >= 0 ? $y : $y - 399, 400);
        $yoe = $y - $era * 400;
        $doy = intdiv(153 * ($month + ($month > 2 ? -3 : 9)) + 2, 5);
        $doe = $yoe * 365 + intdiv($yoe, 4) - intdiv($yoe, 100) + $doy;
        return $era * 146097 + $doe - 719468;
    }

    /** value?.[key], for a value that may be null or undefined. */
    private static function at(mixed $value, string|int $key): mixed
    {
        return $value === null || $value instanceof Undefined ? Undefined::value() : Js::get($value, $key);
    }

    /** a ?? b */
    private static function either(mixed $value, mixed $otherwise): mixed
    {
        return $value === null || $value instanceof Undefined ? $otherwise : $value;
    }

    /** A whole float as an int, as JavaScript makes no difference between them. */
    private static function whole(int|float $n): int|float
    {
        return is_float($n) && is_finite($n) && floor($n) === $n && abs($n) < 9.0e15 ? (int) $n : $n;
    }

    /**
     * One log line as a page fetch, or null. `$site` is the address pages live at
     * (https://example.com), for formats that do not record the host.
     *
     * @return array{method: mixed, url: string, status: int|float, userAgent: string, at: int|float}|null
     */
    public static function parseLine(string $line, ?string $site = null): ?array
    {
        $text = Js::trim($line);
        if ($text === '') {
            return null;
        }
        if (str_starts_with($text, '{')) {
            // Caddy: {"ts": 1696..., "request": {"method", "host", "uri", "headers": {"User-Agent": [...]}}, "status": 200}
            try {
                $entry = Json::decode($text);
                $request = self::at($entry, 'request');
                $uri = self::at($request, 'uri');
                $method = self::at($request, 'method');
                if (!Js::truthy($uri) || !Js::truthy($method)) {
                    return null;
                }
                $host = self::at($request, 'host');
                $host = Js::truthy($host)
                    ? (Js::truthy(self::at($request, 'tls')) ? 'https' : ($site !== null && str_starts_with($site, 'http://') ? 'http' : 'https')) . '://' . Js::string($host)
                    : $site;
                if ($host === null || $host === '') {
                    return null;
                }
                $headers = self::at($request, 'headers');
                $ua = self::either(self::at(self::at($headers, 'User-Agent'), 0), self::either(self::at(self::at($headers, 'user-agent'), 0), ''));
                $ts = self::at($entry, 'ts');
                $at = is_int($ts) || is_float($ts) ? self::whole($ts * 1000) : ImportHttp::parseDate(Js::string(self::either($ts, '')));
                // A target that is not text cannot be a page, as startsWith throws on it in TypeScript.
                $url = is_string($uri) ? self::pageUrl($uri, $host) : null;
                if ($url === null) {
                    return null;
                }
                return ['method' => $method, 'url' => $url, 'status' => Js::number(self::either(self::at($entry, 'status'), 0)), 'userAgent' => Js::string($ua), 'at' => $at];
            } catch (\JsonException|\TypeError) {
                return null;
            }
        }
        if (!preg_match(self::COMBINED, $text, $m)) {
            return null;
        }
        // A vhost column first ("example.com:443 1.2.3.4 - - [...]") names the host; otherwise $site does.
        $vhost = $m[1] !== '' && preg_match('/[a-z]/i', $m[1]) && !preg_match('/^[0-9.:]+$/D', $m[1]) ? preg_replace('/:[0-9]+$/D', '', $m[1]) : null;
        $base = $vhost !== null ? "https://$vhost" : $site;
        if ($base === null || $base === '') {
            return null;
        }
        $url = self::pageUrl($m[4], $base);
        return $url !== null ? ['method' => $m[3], 'url' => $url, 'status' => (int) $m[5], 'userAgent' => str_replace('\\"', '"', $m[6]), 'at' => self::logTime($m[2])] : null;
    }

    /**
     * The lines worth sending: GETs that succeeded, from known AI agents.
     *
     * @param (callable(): int)|null $now epoch milliseconds, for a line whose time cannot be read
     * @return array{url: string, userAgent: string, at: int|float}|null
     */
    public static function agentFetch(string $line, ?string $site = null, ?callable $now = null): ?array
    {
        $hit = self::parseLine($line, $site);
        if ($hit === null || $hit['method'] !== 'GET' || $hit['status'] < 200 || $hit['status'] >= 400 || Ua::aiAgent($hit['userAgent']) === null) {
            return null;
        }
        return ['url' => $hit['url'], 'userAgent' => $hit['userAgent'], 'at' => is_finite((float) $hit['at']) ? $hit['at'] : ($now ?? self::clock(...))()];
    }

    private static function clock(): int
    {
        return (int) floor(microtime(true) * 1000);
    }

    /**
     * Sends one batch of fetches to /api/observe and returns how many Runlight kept.
     *
     * @param list<array{url: string, userAgent: string, at: int|float}> $fetches
     */
    private static function send(array $options, Fetcher $fetcher, array $fetches): int|float
    {
        try {
            $answer = $fetcher->fetch(rtrim($options['to'], '/') . '/api/observe', [
                'method' => 'POST',
                'headers' => ['authorization' => "Bearer {$options['key']}", 'content-type' => 'application/json'],
                'body' => Json::encode(['fetches' => $fetches]),
                'timeoutMs' => 30_000,
            ]);
        } catch (\Throwable $error) {
            throw new SendError($error->getMessage(), 0, $error);
        }
        if ($answer->status === 401) {
            throw new SendError("Runlight refused the key. Use the site's key from Settings, Install, Key for CMS plugins.");
        }
        if (!$answer->ok()) {
            throw new SendError("Runlight answered {$answer->status}: " . Js::slice(Js::scrub($answer->text()), 0, 200));
        }
        $body = Json::tryDecode($answer->text());
        $recorded = $body instanceof \stdClass ? Js::get($body, 'recorded') : null;
        return is_int($recorded) || is_float($recorded) ? $recorded : 0;
    }

    /**
     * Opens a file for reading, or throws with the reason, as Node's openSync does.
     *
     * @return resource
     */
    private static function open(string $file)
    {
        $fd = @fopen($file, 'rb');
        if ($fd === false) {
            throw new \RuntimeException(self::reason("Could not open $file"));
        }
        return $fd;
    }

    /** The last PHP warning's text, without the function name it starts with. */
    private static function reason(string $otherwise): string
    {
        $error = error_get_last();
        return $error !== null ? (string) preg_replace('/^\w+\([^)]*\): /', '', $error['message']) : $otherwise;
    }

    /** @return array{ino: int, size: int} */
    private static function stat(string $file): array
    {
        clearstatcache(true, $file);
        $stat = @stat($file);
        if ($stat === false) {
            throw new \RuntimeException(self::reason("Could not read $file"));
        }
        return ['ino' => (int) $stat['ino'], 'size' => (int) $stat['size']];
    }

    /** @param resource $fd */
    private static function size($fd): int
    {
        $stat = fstat($fd);
        if ($stat === false) {
            throw new \RuntimeException('Could not read the log');
        }
        return (int) $stat['size'];
    }

    /**
     * Up to `$length` bytes from `$offset`.
     *
     * @param resource $fd
     */
    private static function readAt($fd, int $offset, int $length): string
    {
        if ($length <= 0) {
            return '';
        }
        if (fseek($fd, $offset) !== 0) {
            throw new \RuntimeException('Could not read the log');
        }
        $buffer = '';
        while (strlen($buffer) < $length) {
            $part = fread($fd, $length - strlen($buffer));
            if ($part === false) {
                throw new \RuntimeException(self::reason('Could not read the log'));
            }
            if ($part === '') {
                break;
            }
            $buffer .= $part;
        }
        return $buffer;
    }

    /**
     * A fingerprint of the log's first bytes. A log rotated by copying and truncating keeps its inode,
     * so a different start is how a new log shows itself. An open file (in follow mode) is read as it is,
     * even once it is renamed.
     *
     * @param string|resource $file
     * @return array{head: string, length: int}
     */
    private static function headOf($file, int $length = self::HEAD): array
    {
        $fd = is_string($file) ? self::open($file) : $file;
        try {
            $buffer = self::readAt($fd, 0, min($length, self::size($fd)));
            return ['head' => hash('sha256', $buffer), 'length' => strlen($buffer)];
        } finally {
            if (is_string($file)) {
                fclose($fd);
            }
        }
    }

    /**
     * Whether the log at this inode still starts the way it did, so a saved place in it still holds.
     *
     * @param array{ino: int, head?: mixed, length?: mixed} $saved
     * @param array{ino: int, size: int} $stat
     */
    private static function sameLog(string $file, array $saved, array $stat): bool
    {
        if ($saved['ino'] !== $stat['ino']) {
            return false;
        }
        if (!Js::truthy($saved['head'] ?? null) || !isset($saved['length'])) {
            return true;
        }
        $length = (int) $saved['length'];
        return $stat['size'] >= $length && self::headOf($file, $length)['head'] === $saved['head'];
    }

    /**
     * Reads whole lines from a byte offset, at most a chunk, and returns where the next read starts.
     * Offsets count bytes up to each newline byte, so a malformed character cannot shift them. `ends`
     * holds where the line after each one starts, so a place can be saved part way through a chunk.
     *
     * @param string|resource $file
     * @return array{lines: list<string>, ends: list<int>, next: int, more: bool}
     */
    private static function readFrom($file, int $offset): array
    {
        // A path is opened for this read; an open file (in follow mode) stays open, even once it is renamed.
        $size = is_string($file) ? self::stat($file)['size'] : self::size($file);
        if ($size <= $offset) {
            return ['lines' => [], 'ends' => [], 'next' => $offset, 'more' => false];
        }
        $fd = is_string($file) ? self::open($file) : $file;
        try {
            $buffer = self::readAt($fd, $offset, min($size - $offset, self::CHUNK));
            $end = strrpos($buffer, "\n");
            // A half-written last line waits for the next read (or, in a chunk with no newline at all, is skipped).
            if ($end === false) {
                return strlen($buffer) === self::CHUNK
                    ? ['lines' => [], 'ends' => [], 'next' => $offset + strlen($buffer), 'more' => true]
                    : ['lines' => [], 'ends' => [], 'next' => $offset, 'more' => false];
            }
            $lines = [];
            $ends = [];
            for ($start = 0; $start <= $end;) {
                $newline = (int) strpos($buffer, "\n", $start);
                // Read as UTF-8 the way Node does, each malformed sequence becoming U+FFFD.
                $lines[] = Js::scrub(substr($buffer, $start, $newline - $start));
                $ends[] = $offset + $newline + 1;
                $start = $newline + 1;
            }
            return ['lines' => $lines, 'ends' => $ends, 'next' => $offset + $end + 1, 'more' => $offset + strlen($buffer) < $size];
        } finally {
            if (is_string($file)) {
                fclose($fd);
            }
        }
    }

    /** Whether a process with this id is running on this machine. */
    private static function running(int $pid): bool
    {
        if (function_exists('posix_kill')) {
            if (posix_kill($pid, 0)) {
                return true;
            }
            // EPERM: it runs, as someone else.
            return posix_get_last_error() === 1;
        }
        // Without the posix extension, Linux lists running processes in /proc; elsewhere a lock is taken as held.
        return is_dir('/proc/self') ? is_dir("/proc/$pid") : true;
    }

    /** The text of a file, or null when it cannot be read. */
    private static function contents(string $file): ?string
    {
        $text = @file_get_contents($file);
        return $text === false ? null : $text;
    }

    /**
     * Takes the lock beside a state file, so two runs never read from the same place and send the
     * same lines twice. The lock holds the run's process id; a lock left by a process that is no longer
     * running is taken over. Returns the release.
     *
     * @return \Closure(): void
     */
    private static function lock(string $state): \Closure
    {
        $path = "$state.lock";
        $mine = (string) getmypid();
        for ($attempt = 0; $attempt < 3; $attempt++) {
            $fd = @fopen($path, 'x');
            if ($fd !== false) {
                fwrite($fd, $mine);
                fclose($fd);
                $released = false;
                $release = static function () use ($path, $mine, &$released): void {
                    if ($released) {
                        return;
                    }
                    $released = true;
                    if (self::contents($path) === $mine) {
                        @unlink($path);
                    }
                };
                // Released on exit too, as a run that stops part way would otherwise leave its lock behind.
                register_shutdown_function($release);
                return $release;
            }
            clearstatcache(true, $path);
            if (!file_exists($path)) {
                throw new \RuntimeException(self::reason("Could not create $path"));
            }
            $held = self::contents($path);
            if ($held === null) {
                continue;
            }
            $held = Js::trim($held);
            $pid = Js::number($held);
            // A lock being written has no id in it yet, so it counts as held.
            if ($held === '' || (is_int($pid) && $pid > 0 && self::running($pid))) {
                break;
            }
            // Stale. Moving it aside is atomic, so of two runs taking it over only one moves this lock; one
            // that finds a newer lock moved aside puts it back.
            $aside = "$path.$mine";
            if (!@rename($path, $aside)) {
                continue;
            }
            if (Js::trim((string) self::contents($aside)) !== $held) {
                @link($aside, $path);
                unlink($aside);
                break;
            }
            unlink($aside);
        }
        $holder = Js::trim((string) self::contents($path));
        throw new \RuntimeException("Another run is using $state" . ($holder !== '' ? " (process $holder)" : '') . ". Wait for it to finish, or delete $path if none is running.");
    }

    /**
     * Writes the state whole or not at all, so a crash part way never leaves it empty.
     *
     * @param array{ino: int, offset: int, head: string, length: int} $saved
     */
    private static function writeState(string $state, array $saved): void
    {
        $temp = "$state." . getmypid() . '.tmp';
        if (@file_put_contents($temp, Json::encode($saved)) === false || !@rename($temp, $state)) {
            throw new \RuntimeException(self::reason("Could not write $state"));
        }
    }

    /**
     * Reads the log and sends what AI agents fetched, returning how many fetches Runlight kept.
     *
     * Options, as the Node command's:
     * - log: the access log's path
     * - to: the Runlight to report to, as its dashboard address
     * - key: the site's observe key
     * - site: the site's address, for logs with no host in them
     * - follow: keep reading as the log grows
     * - state: where runs remember how far they read, so the next one (or a restarted follow) carries on
     * - out: callable(string): void for what it has to say, a line at a time; printed by default
     * - stop: callable(): bool that ends follow, which otherwise runs until the process stops
     * - pollMs: how often follow looks at the log, 2 seconds by default
     * - sleep: callable(int $ms): void that waits between looks, usleep by default
     * - fetcher: the Fetcher that reaches Runlight, CurlFetcher by default
     * - now: callable(): int, epoch milliseconds, for lines whose time cannot be read
     *
     * @param array<string, mixed> $options
     */
    public static function run(array $options): int|float
    {
        $release = isset($options['state']) ? self::lock($options['state']) : static function (): void {
        };
        try {
            return self::readLog($options);
        } finally {
            $release();
        }
    }

    /** @param array<string, mixed> $options */
    private static function readLog(array $options): int|float
    {
        $out = $options['out'] ?? static function (string $line): void {
            fwrite(STDOUT, "$line\n");
        };
        $fetcher = $options['fetcher'] ?? new CurlFetcher();
        $now = $options['now'] ?? self::clock(...);
        $site = isset($options['site']) && $options['site'] !== '' ? (string) $options['site'] : null;
        $state = isset($options['state']) && $options['state'] !== '' ? (string) $options['state'] : null;
        $log = (string) $options['log'];
        clearstatcache(true, $log);
        if (!file_exists($log)) {
            throw new \RuntimeException("No log at $log");
        }
        $total = 0;
        $warned = false;
        /**
         * Sends the agent fetches among lines read, a batch at a time, calling `done` with where the next
         * unsent line starts after each batch, so a failure part way sends none of the earlier batches again.
         */
        $handle = static function (array $read, callable $done) use ($options, $fetcher, $now, $site, $out, &$total, &$warned): int|float {
            ['lines' => $lines, 'ends' => $ends] = $read;
            // Lines with no host and no site cannot be placed on a site; say so once rather than skip them silently.
            if ($site === null && !$warned) {
                foreach ($lines as $line) {
                    if (!str_starts_with(Js::trim($line), '{') && preg_match(self::REQUEST, $line) && self::parseLine($line) === null) {
                        $warned = true;
                        $out('Some lines have no host in them. Add --site https://your-site.example so they can be counted.');
                        break;
                    }
                }
            }
            $kept = 0;
            $batch = [];
            $count = count($lines);
            for ($i = 0; $i < $count; $i++) {
                $found = self::agentFetch($lines[$i], $site, $now);
                if ($found !== null) {
                    $batch[] = $found;
                }
                if (count($batch) === self::BATCH || ($i === $count - 1 && $batch !== [])) {
                    $recorded = self::send($options, $fetcher, $batch);
                    $kept += $recorded;
                    $total += $recorded;
                    $batch = [];
                    $done($ends[$i]);
                }
            }
            return $kept;
        };
        /** The place to save: the file being read, by its inode and its own start, and how far into it. */
        $save = static function (int $ino, int $offset, array $head) use ($state): void {
            if ($state !== null) {
                self::writeState($state, ['ino' => $ino, 'offset' => $offset, 'head' => $head['head'], 'length' => $head['length']]);
            }
        };
        /** Where the last run stopped, or null with a word about it when the state file cannot be read. */
        $readState = static function () use ($state, $out): ?array {
            clearstatcache();
            if ($state === null || !file_exists($state)) {
                return null;
            }
            $saved = Json::tryDecode((string) self::contents($state));
            $ino = $saved instanceof \stdClass ? Js::get($saved, 'ino') : null;
            $offset = $saved instanceof \stdClass ? Js::get($saved, 'offset') : null;
            if ((is_int($ino) || is_float($ino)) && (is_int($offset) || is_float($offset))) {
                $read = ['ino' => self::whole($ino), 'offset' => self::whole($offset)];
                $head = Js::get($saved, 'head');
                $length = Js::get($saved, 'length');
                if (!$head instanceof Undefined) {
                    $read['head'] = $head;
                }
                if (!$length instanceof Undefined) {
                    $read['length'] = $length;
                }
                return $read;
            }
            $out("Could not read $state, so this run starts as if it were the first.");
            return null;
        };

        if (empty($options['follow'])) {
            // Where the last run stopped, unless the log was rotated since (a new file, a shorter one, or a new start).
            $saved = $readState();
            $stat = self::stat($log);
            $offset = $saved !== null && $saved['offset'] <= $stat['size'] && self::sameLog($log, $saved, $stat) ? (int) $saved['offset'] : 0;
            $count = 0;
            // A batch at a time, saving the place after each, so a failure part way resends nothing already sent.
            for (;;) {
                $read = self::readFrom($log, $offset);
                $handle($read, static fn (int $at) => $save($stat['ino'], $at, self::headOf($log)));
                $count += count($read['lines']);
                $offset = $read['next'];
                $save($stat['ino'], $offset, self::headOf($log));
                if (!$read['more']) {
                    break;
                }
            }
            $out("Sent $total AI agent fetches from $count new lines.");
            return $total;
        }

        // Follow: start where the state says, else at the end like tail -F. A log that was rotated since the
        // state was saved is all new, so it is read from its start.
        $stop = $options['stop'] ?? static fn (): bool => false;
        $sleep = $options['sleep'] ?? static function (int $ms): void {
            usleep($ms * 1000);
        };
        $pollMs = (int) ($options['pollMs'] ?? 2000);
        $resumed = $readState();
        $first = self::stat($log);
        $ino = $first['ino'];
        $offset = $resumed !== null ? ($resumed['offset'] <= $first['size'] && self::sameLog($log, $resumed, $first) ? (int) $resumed['offset'] : 0) : $first['size'];
        $out("Following $log. AI agent fetches go to {$options['to']} as they happen.");
        // The log stays open, so when it is renamed in a rotation, what was written to it before the
        // switch is still read to the end before the new log starts. Its fingerprint is taken from the
        // open file too, so a place saved while finishing an old log names that log, never the new one.
        $fd = self::open($log);
        $known = self::headOf($fd);
        // The same trouble every two seconds is said once, until something changes.
        $trouble = '';
        while (!$stop()) {
            $sleep($pollMs);
            try {
                clearstatcache(true, $log);
                $stat = file_exists($log) ? self::stat($log) : null;
                $renamed = $stat === null || $stat['ino'] !== $ino;
                // Copied and truncated in place: the same file, shorter or with a new start.
                if (!$renamed && ($stat['size'] < $offset || !self::sameLog($log, ['ino' => $ino] + $known, $stat))) {
                    $offset = 0;
                }
                $read = self::readFrom($fd, $offset);
                $sent = $handle($read, static function (int $at) use (&$offset, &$ino, &$known, $save): void {
                    $offset = $at;
                    $save($ino, $offset, $known);
                });
                // Only past lines that were sent, so a failed send is tried again next time.
                $offset = $read['next'];
                $save($ino, $offset, $known);
                if ($sent) {
                    $out("Sent $sent AI agent fetches.");
                }
                if ($renamed && $stat !== null && !$read['more']) {
                    // The old log is finished; the new one is read from its start.
                    $next = self::open($log);
                    fclose($fd);
                    $fd = $next;
                    $ino = $stat['ino'];
                    $offset = 0;
                }
                // The start grows until it is HEAD bytes long, so the fingerprint is taken again each time.
                $known = self::headOf($fd);
                $trouble = '';
            } catch (\Throwable $error) {
                $said = $error instanceof SendError ? "Could not send, trying again shortly: {$error->getMessage()}" : "Could not read $log, trying again shortly: {$error->getMessage()}";
                if ($said !== $trouble) {
                    $out($said);
                }
                $trouble = $said;
            }
        }
        fclose($fd);
        return $total;
    }
}
