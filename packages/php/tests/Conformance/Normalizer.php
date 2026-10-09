<?php

declare(strict_types=1);

namespace Runlight\Tests\Conformance;

use Runlight\Json;

/**
 * The masking http-conformance.ts applies to answers, ported line by line:
 * ids and other random values become placeholders, so answers compare across
 * runs and implementations. Values are as Json::decode gives them (objects as
 * stdClass, so {} and [] stay apart).
 *
 * The regexes are JavaScript's, so they are written here to read the same way:
 * `\z` for JavaScript's `$` without the m flag (PCRE's `$` also matches before
 * a final newline), and JavaScript's `\s` spelled out, since it matches
 * Unicode spaces that PCRE's `\s` does not.
 */
final class Normalizer
{
    /** Headers every implementation must send the same, where it sends them. */
    public const HEADERS = [
        'content-type',
        'cache-control',
        'location',
        'set-cookie',
        'www-authenticate',
        'allow',
        'content-disposition',
        'content-security-policy',
        'x-frame-options',
        'referrer-policy',
        'x-content-type-options',
        'x-robots-tag',
        'access-control-allow-origin',
        'access-control-allow-methods',
        'access-control-allow-headers',
        'access-control-max-age',
    ];

    // The version and the implementation differ between ports and releases, so they are placeholders too.
    private const RANDOM = ['token', 'secret', 'hint', 'version', 'library', 'language', 'ticket', 'recovery'];

    /** JavaScript's \s: WhiteSpace and LineTerminator, Unicode spaces included. */
    private const JS_SPACE = '\t\n\x{0B}\f\r \x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}';

    /** Random parts inside a longer string: secrets in a query, and long runs of hex such as ids and signatures. */
    public static function scrub(string $text): string
    {
        $text = self::replace('/([?&](?:code|ticket|secret|code_challenge)=)[^&#' . self::JS_SPACE . '"\'<>]+/u', '$1<value>', $text);
        $text = self::replace('/(?<![A-Za-z0-9])[a-f0-9]{24,}(?![A-Za-z0-9])/u', '<hex>', $text);
        return self::replace('/(?<![A-Za-z0-9_])rlo?_[A-Za-z0-9]{20,}(?![A-Za-z0-9])/u', '<key>', $text);
    }

    /** Ids and other random values become "<key>", so answers compare across runs and implementations. */
    public static function normalize(mixed $value, string $key = ''): mixed
    {
        if (is_array($value)) {
            return array_map(fn ($v) => self::normalize($v, $key), $value);
        }
        if ($value instanceof \stdClass) {
            $out = new \stdClass();
            foreach (get_object_vars($value) as $k => $v) {
                $out->{$k} = self::normalize($v, (string) $k);
            }
            return $out;
        }
        if (is_string($value)) {
            if (in_array($key, self::RANDOM, true) || self::test('/^rlo?_[A-Za-z0-9]+\z/u', $value) || self::test('/^[a-f0-9]{24}\z/u', $value)) {
                return '<' . ($key !== '' ? $key : 'value') . '>';
            }
            return self::scrub($value);
        }
        return $value;
    }

    /** A Set-Cookie header with its value as <value>, unless it clears the cookie. */
    public static function cookieShape(string $header): string
    {
        return self::replaceCallback(
            '/^([^=;]+)=([^;]*)/u',
            fn (array $m) => $m[1] . '=' . ($m[2] !== '' ? '<value>' : ''),
            $header,
            1,
        );
    }

    /**
     * Answers as one text to compare: object keys sorted, since JavaScript's deepEqual ignores their
     * order, and written as Json writes them, so 1.0 and 1 are the same number as they are in JavaScript.
     */
    public static function canonical(mixed $value): string
    {
        return Json::encode(self::sorted($value), true);
    }

    private static function sorted(mixed $value): mixed
    {
        if (is_array($value)) {
            if (!array_is_list($value)) {
                $value = (object) $value;
            } else {
                return array_map(self::sorted(...), $value);
            }
        }
        if ($value instanceof \stdClass) {
            $fields = get_object_vars($value);
            ksort($fields, SORT_STRING);
            $out = new \stdClass();
            foreach ($fields as $k => $v) {
                $out->{$k} = self::sorted($v);
            }
            return $out;
        }
        return $value;
    }

    private static function test(string $pattern, string $text): bool
    {
        $found = preg_match($pattern, $text);
        if ($found === false) {
            // Not UTF-8: read it byte by byte, as the patterns only name ASCII.
            $found = preg_match(substr($pattern, 0, -1), $text);
        }
        return $found === 1;
    }

    private static function replace(string $pattern, string $replacement, string $text): string
    {
        return preg_replace($pattern, $replacement, $text) ?? (string) preg_replace(self::bytes($pattern), $replacement, $text);
    }

    private static function replaceCallback(string $pattern, \Closure $fn, string $text, int $limit = -1): string
    {
        return preg_replace_callback($pattern, $fn, $text, $limit) ?? (string) preg_replace_callback(self::bytes($pattern), $fn, $text, $limit);
    }

    /** The pattern without the u flag, for text that is not UTF-8. */
    private static function bytes(string $pattern): string
    {
        return str_replace(self::JS_SPACE, '\t\n\x0B\f\r ', substr($pattern, 0, -1));
    }
}
