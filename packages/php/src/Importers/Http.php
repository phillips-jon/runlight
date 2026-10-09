<?php

declare(strict_types=1);

namespace Runlight\Importers;

use Runlight\Http\CurlFetcher;
use Runlight\Http\Fetcher;
use Runlight\Http\FetchError;
use Runlight\Http\Url;
use Runlight\Json;
use Runlight\Undefined;

/**
 * JSON over HTTPS with a timeout and a few retries on rate limits and server
 * errors, plus the few pieces of JavaScript the importers lean on (Date.parse,
 * String(), truthiness, and fields that may be missing). An importer takes one,
 * so tests can pass a fake Fetcher and a sleep that does not wait.
 */
final class Http
{
    private readonly Fetcher $fetcher;
    /** @var \Closure(int|float): void */
    private readonly \Closure $sleep;

    /** @param (\Closure(int|float): void)|null $sleep waits this many milliseconds */
    public function __construct(?Fetcher $fetcher = null, ?\Closure $sleep = null)
    {
        $this->fetcher = $fetcher ?? new CurlFetcher();
        $this->sleep = $sleep ?? static function (int|float $ms): void {
            if ($ms > 0) {
                usleep((int) ($ms * 1000));
            }
        };
    }

    public function pause(int|float $ms): void
    {
        ($this->sleep)($ms);
    }

    /**
     * Fetches JSON, decoded to arrays.
     *
     * @param array{headers?: array<string, string>, method?: string, body?: string} $init
     */
    public function getJson(string $url, array $init = []): mixed
    {
        for ($attempt = 1; ; $attempt++) {
            $options = ['headers' => ['accept' => 'application/json', ...($init['headers'] ?? [])], 'timeoutMs' => 20_000];
            if (isset($init['method'])) {
                $options['method'] = $init['method'];
            }
            if (isset($init['body'])) {
                $options['body'] = $init['body'];
            }
            try {
                $response = $this->fetcher->fetch($url, $options);
            } catch (FetchError) {
                if ($attempt < 3) {
                    continue;
                }
                $host = (new Url($url))->host();
                throw new ImportError("Could not reach $host", 'unreachable', ['host' => $host]);
            }
            if ($response->ok()) {
                return Json::decode($response->text(), true);
            }
            if ($response->status === 401) {
                throw new HttpError('The key or sign-in was refused', 401, 'import_refused');
            }
            if (($response->status === 429 || $response->status >= 500) && $attempt < 4) {
                // Retry-After in seconds; none, zero, negative, or not a number waits the default backoff.
                $wait = self::number($response->headers->get('retry-after')) * 1000;
                $wait = is_nan($wait) || $wait <= 0 ? 800 * $attempt : $wait;
                $this->pause(self::whole(min($wait, 10_000)));
                continue;
            }
            $host = (new Url($url))->host();
            throw new HttpError("$host answered {$response->status}", $response->status, 'import_status', ['host' => $host, 'status' => (string) $response->status]);
        }
    }

    /** A float that is whole as an int, so it reads as JavaScript's number would. */
    private static function whole(int|float $n): int|float
    {
        return is_float($n) && floor($n) === $n && abs($n) < PHP_INT_MAX ? (int) $n : $n;
    }

    /** JavaScript's Number() of a header or other text: 0 for none or blank, NaN for anything not a number. */
    public static function number(?string $text): float
    {
        if ($text === null) {
            return 0;
        }
        $text = self::trim($text);
        if ($text === '') {
            return 0;
        }
        if (preg_match('/^0[xX][0-9a-fA-F]+$/', $text)) {
            return (float) hexdec(substr($text, 2));
        }
        if (preg_match('/^0[oO][0-7]+$/', $text)) {
            return (float) octdec(substr($text, 2));
        }
        if (preg_match('/^0[bB][01]+$/', $text)) {
            return (float) bindec(substr($text, 2));
        }
        if (preg_match('/^[+-]?Infinity$/', $text)) {
            return $text[0] === '-' ? -INF : INF;
        }
        if (preg_match('/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/', $text)) {
            return (float) $text;
        }
        return NAN;
    }

    /** JavaScript's String.prototype.trim. */
    public static function trim(string $text): string
    {
        return (string) preg_replace('/^[\s\x{FEFF}\x{A0}]+|[\s\x{FEFF}\x{A0}]+$/u', '', $text);
    }

    /** JavaScript's encodeURIComponent. */
    public static function encodeURIComponent(string $text): string
    {
        return strtr(rawurlencode($text), ['%21' => '!', '%27' => "'", '%28' => '(', '%29' => ')', '%2A' => '*']);
    }

    /** Whether JavaScript counts a value as true. */
    public static function truthy(mixed $value): bool
    {
        if ($value instanceof Undefined || $value === null || $value === false || $value === '' || $value === 0) {
            return false;
        }
        if (is_float($value)) {
            return $value != 0 && !is_nan($value);
        }
        return true;
    }

    /** JavaScript's String() of a value, as a template literal writes it. */
    public static function str(mixed $value): string
    {
        return match (true) {
            $value instanceof Undefined => 'undefined',
            $value === null => 'null',
            is_bool($value) => $value ? 'true' : 'false',
            is_int($value) => (string) $value,
            is_float($value) => is_nan($value) ? 'NaN' : (is_infinite($value) ? ($value > 0 ? 'Infinity' : '-Infinity') : Json::number($value)),
            is_array($value) => array_is_list($value) ? implode(',', array_map(static fn ($v) => $v === null || $v instanceof Undefined ? '' : self::str($v), $value)) : '[object Object]',
            default => (string) $value,
        };
    }

    /** `object?.key`: the field, or Undefined when the object or the field is missing. A null field stays null. */
    public static function field(mixed $object, string|int $key): mixed
    {
        return is_array($object) && array_key_exists($key, $object) ? $object[$key] : Undefined::value();
    }

    /** `a ?? b`: b when a is null or missing. */
    public static function coalesce(mixed $value, mixed $fallback): mixed
    {
        return $value === null || $value instanceof Undefined ? $fallback : $value;
    }

    /**
     * An object as JSON.stringify would keep it: the fields holding undefined left out.
     *
     * @param array<string, mixed> $fields
     * @return array<string, mixed>
     */
    public static function defined(array $fields): array
    {
        return array_filter($fields, static fn ($v) => !$v instanceof Undefined);
    }

    /**
     * Date.parse: milliseconds, or NaN for text that is not a date. The ISO
     * forms are read as JavaScript reads them (a date alone is UTC, a date and
     * time without an offset is local time); other forms go to PHP's parser,
     * which takes what V8's fallback parser takes in the formats services send.
     */
    public static function parseDate(mixed $text): int|float
    {
        if (!is_string($text)) {
            return NAN;
        }
        $text = self::trim($text);
        if (preg_match('/^([+-]\d{6}|\d{4})(?:-(\d{2})(?:-(\d{2}))?)?(?:T(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,9}))?)?(Z|[+-]\d{2}:\d{2})?)?$/i', $text, $m)) {
            $year = (int) $m[1];
            $month = ($m[2] ?? '') !== '' ? (int) $m[2] : 1;
            $day = ($m[3] ?? '') !== '' ? (int) $m[3] : 1;
            $timed = ($m[4] ?? '') !== '';
            $hour = $timed ? (int) $m[4] : 0;
            $minute = $timed ? (int) $m[5] : 0;
            $second = ($m[6] ?? '') !== '' ? (int) $m[6] : 0;
            $ms = ($m[7] ?? '') !== '' ? (int) substr(str_pad($m[7], 3, '0'), 0, 3) : 0;
            if ($m[1] === '-000000' || $month < 1 || $month > 12 || $day < 1 || $day > self::daysIn($year, $month) || $hour > 24 || $minute > 59 || $second > 59 || ($hour === 24 && ($minute || $second || $ms))) {
                return NAN;
            }
            $zone = $m[8] ?? '';
            $utc = self::utcMs($year, $month, $day, $hour, $minute, $second, $ms);
            if (strtoupper($zone) === 'Z' || (!$timed && $zone === '')) {
                return $utc;
            }
            if ($zone !== '') {
                $sign = $zone[0] === '-' ? -1 : 1;
                return $utc - $sign * ((int) substr($zone, 1, 2) * 60 + (int) substr($zone, 4, 2)) * 60_000;
            }
            // Local time, in PHP's default zone (the process's zone in JavaScript).
            $offset = (new \DateTimeZone(date_default_timezone_get()))->getOffset(new \DateTimeImmutable('@' . intdiv($utc, 1000)));
            return $utc - $offset * 1000;
        }
        if ($text === '' || !preg_match('/\d/', $text)) {
            return NAN;
        }
        try {
            $date = new \DateTimeImmutable($text);
        } catch (\Exception) {
            return NAN;
        }
        return (int) $date->format('U') * 1000 + intdiv((int) $date->format('u'), 1000);
    }

    /** `new Date(ms).toISOString()`; a RangeException where JavaScript throws a RangeError. */
    public static function isoString(int|float $ms): string
    {
        if (is_float($ms) && (is_nan($ms) || is_infinite($ms))) {
            throw new \RangeException('Invalid time value');
        }
        // TimeClip truncates toward zero.
        $ms = is_float($ms) ? (int) $ms : $ms;
        if (abs($ms) > 8_640_000_000_000_000) {
            throw new \RangeException('Invalid time value');
        }
        $seconds = intdiv($ms, 1000) - ($ms % 1000 < 0 ? 1 : 0);
        $millis = $ms - $seconds * 1000;
        $date = new \DateTimeImmutable('@' . $seconds);
        $year = (int) $date->format('Y');
        $prefix = $year >= 0 && $year <= 9999 ? sprintf('%04d', $year) : sprintf('%s%06d', $year < 0 ? '-' : '+', abs($year));
        return $prefix . $date->format('-m-d\TH:i:s') . sprintf('.%03dZ', $millis);
    }

    private static function utcMs(int $year, int $month, int $day, int $hour, int $minute, int $second, int $ms): int
    {
        $days = (new \DateTimeImmutable(sprintf('%s-%02d-%02d', $year < 0 ? sprintf('-%04d', -$year) : sprintf('%04d', $year), $month, $day), new \DateTimeZone('UTC')))->getTimestamp();
        return ($days + $hour * 3600 + $minute * 60 + $second) * 1000 + $ms;
    }

    /** Days in a month of the proleptic Gregorian calendar. */
    private static function daysIn(int $year, int $month): int
    {
        return match ($month) {
            2 => ($year % 4 === 0 && $year % 100 !== 0) || $year % 400 === 0 ? 29 : 28,
            4, 6, 9, 11 => 30,
            default => 31,
        };
    }
}
