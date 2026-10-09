<?php

declare(strict_types=1);

namespace Runlight;

use Runlight\Http\Url;

/**
 * What the tracker sends, after validation. Anything malformed is dropped.
 *
 * A payload is an array{kind: 'pageview'|'event'|'engagement', site: string, url: Url, referrer: string,
 * title: string, screenWidth: ?int, screenHeight: ?int, language: string, name: string,
 * props: array<string, string>|null, pageviewId: string, engagedMs: int, scroll: ?int}, where null stands
 * for TypeScript's undefined.
 *
 * `props` keeps JavaScript's key order (keys that are array indexes first, in number order, then the rest
 * as sent). PHP turns a key like "0" into an integer, so write props out with Json::encode(Json::object($props)),
 * never as a bare array, or {"0":"a"} would come out as ["a"].
 */
final class Payload
{
    public const MAX_BODY = 8 * 1024;
    /** One engagement ping covers at most the 30 minutes a session can idle. */
    private const MAX_ENGAGED_MS = 30 * 60 * 1000;
    private const MAX_PROPS = 30;

    private static function str(mixed $value, int $max): string
    {
        return is_string($value) ? Js::slice($value, 0, $max) : '';
    }

    private static function int(mixed $value, int $min, int $max): ?int
    {
        if (!is_int($value) && !is_float($value)) {
            return null;
        }
        $value = (float) $value;
        if (is_nan($value) || is_infinite($value)) {
            return null;
        }
        return (int) min($max, max($min, Js::round($value)));
    }

    /** @return array<string, string>|null */
    private static function props(mixed $value): ?array
    {
        if (!$value instanceof \stdClass) {
            return null;
        }
        $out = [];
        $count = 0;
        foreach (self::entries($value) as [$key, $raw]) {
            if ($count >= self::MAX_PROPS) {
                break;
            }
            $k = Js::slice(Js::trim($key), 0, 60);
            if ($k === '') {
                continue;
            }
            if (is_string($raw)) {
                $text = Js::slice($raw, 0, 500);
            } elseif ((is_int($raw) || is_float($raw)) && is_finite((float) $raw)) {
                // JSON.parse reads every number as a double, so a long integer is rounded as it is there.
                $text = Js::string((float) $raw);
            } elseif (is_bool($raw)) {
                $text = $raw ? 'true' : 'false';
            } else {
                continue;
            }
            // Assigning out["__proto__"] in JavaScript sets the prototype, which a string cannot be, so
            // nothing is kept; it still counts.
            if ($k !== '__proto__') {
                $out[$k] = $text;
            }
            $count++;
        }
        if ($count === 0) {
            return null;
        }
        $ordered = [];
        foreach (self::entries((object) $out) as [$key, $text]) {
            $ordered[$key] = $text;
        }
        return $ordered;
    }

    /**
     * An object's entries in JavaScript's order: keys that are array indexes first, ascending, then the
     * rest in the order they were added.
     *
     * @return list<array{string, mixed}>
     */
    private static function entries(\stdClass $object): array
    {
        $indexes = [];
        $names = [];
        foreach (get_object_vars($object) as $key => $item) {
            $key = (string) $key;
            if (preg_match('/^(0|[1-9][0-9]{0,9})$/D', $key) && (int) $key <= 4294967294) {
                $indexes[(int) $key] = [$key, $item];
            } else {
                $names[] = [$key, $item];
            }
        }
        ksort($indexes, SORT_NUMERIC);
        return [...array_values($indexes), ...$names];
    }

    /**
     * Reads JSON as JSON.parse does where PHP differs: text that is not UTF-8 is repaired as a TextDecoder
     * would, a lone surrogate escape reads as U+FFFD (which is how the SDK stores it), long integers become
     * doubles, and nesting has no practical limit.
     */
    private static function parse(string $text): mixed
    {
        // Escapes are read left to right so an escaped backslash is never taken for the start of one.
        $text = preg_replace_callback(
            '/\\\\(?:(?<pair>u[dD][89abAB][0-9a-fA-F]{2}\\\\u[dD][c-fC-F][0-9a-fA-F]{2})|(?<lone>u[dD][89a-fA-F][0-9a-fA-F]{2})|.)/s',
            fn (array $m) => ($m['lone'] ?? '') !== '' ? '�' : $m[0],
            $text,
        ) ?? $text;
        return json_decode($text, false, 100000, JSON_THROW_ON_ERROR);
    }

    /**
     * @return array{kind: string, site: string, url: Url, referrer: string, title: string, screenWidth: ?int,
     *   screenHeight: ?int, language: string, name: string, props: array<string, string>|null, pageviewId: string,
     *   engagedMs: int, scroll: ?int}|null
     */
    public static function parsePayload(string $text): ?array
    {
        $text = Js::scrub($text);
        if (Js::length($text) > self::MAX_BODY) {
            return null;
        }
        try {
            $body = self::parse($text);
        } catch (\JsonException) {
            return null;
        }
        if (!$body instanceof \stdClass) {
            return null;
        }
        $get = fn (string $key): mixed => property_exists($body, $key) ? $body->{$key} : null;

        $kind = $get('k');
        if ($kind !== 'pageview' && $kind !== 'event' && $kind !== 'engagement') {
            return null;
        }

        $url = Url::parse(self::str($get('u'), 2048));
        if ($url === null || ($url->protocol !== 'http:' && $url->protocol !== 'https:')) {
            return null;
        }

        $name = Js::trim(self::str($get('n'), 120));
        if ($kind === 'event' && $name === '') {
            return null;
        }

        $pageviewId = self::str($get('i'), 32);
        if ($pageviewId !== '' && !preg_match('/^[a-z0-9]+$/iD', $pageviewId)) {
            return null;
        }
        if ($kind === 'engagement' && $pageviewId === '') {
            return null;
        }

        return [
            'kind' => $kind,
            'site' => self::str($get('s'), 64),
            'url' => $url,
            'referrer' => self::str($get('r'), 2048),
            'title' => self::str($get('t'), 500),
            'screenWidth' => self::int($get('w'), 0, 20000),
            'screenHeight' => self::int($get('h'), 0, 20000),
            'language' => self::str($get('l'), 35),
            'name' => $name,
            'props' => $kind === 'event' ? self::props($get('p')) : null,
            'pageviewId' => $pageviewId,
            'engagedMs' => $kind === 'engagement' ? self::int($get('e'), 0, self::MAX_ENGAGED_MS) ?? 0 : 0,
            'scroll' => self::int($get('d'), 0, 100),
        ];
    }
}
