<?php

declare(strict_types=1);

namespace Runlight;

/**
 * JavaScript's own rules for the few conversions the port needs to match:
 * Number(), String(), trim(), comparing text with `<`, cutting text to a
 * length in UTF-16 units, and encodeURIComponent().
 *
 * Values are as Json::decode gives them: null, bool, int, float, string, a
 * list for an array, and an array with keys or a stdClass for an object.
 */
final class Js
{
    /** What JavaScript counts as white space in trim() and \s, for a regex class with the u flag. */
    public const SPACE = '\t\n\x{0B}\f\r \x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}';

    /** Number(value). */
    public static function number(mixed $value): int|float
    {
        if ($value === null || $value === false) {
            return 0;
        }
        if ($value === true) {
            return 1;
        }
        if (is_int($value) || is_float($value)) {
            return $value;
        }
        if (is_array($value) && array_is_list($value)) {
            return self::number(self::string($value));
        }
        if (!is_string($value)) {
            return NAN;
        }
        $text = self::trim($value);
        if ($text === '') {
            return 0;
        }
        if (preg_match('/^0([xob])([0-9a-f]+)$/i', $text, $m)) {
            $base = ['x' => 16, 'o' => 8, 'b' => 2][strtolower($m[1])];
            $digits = strtolower($m[2]);
            $valid = ['x' => '/^[0-9a-f]+$/', 'o' => '/^[0-7]+$/', 'b' => '/^[01]+$/'][strtolower($m[1])];
            if (!preg_match($valid, $digits)) {
                return NAN;
            }
            $n = 0.0;
            foreach (str_split($digits) as $digit) {
                $n = $n * $base + hexdec($digit);
            }
            return self::whole($n);
        }
        if (preg_match('/^[+-]?Infinity$/', $text)) {
            return $text[0] === '-' ? -INF : INF;
        }
        if (!preg_match('/^[+-]?(\d+\.?\d*|\.\d+)(e[+-]?\d+)?$/i', $text)) {
            return NAN;
        }
        return self::whole((float) $text);
    }

    /** String(value). */
    public static function string(mixed $value): string
    {
        if ($value === null) {
            return 'null';
        }
        if (is_bool($value)) {
            return $value ? 'true' : 'false';
        }
        if (is_int($value) || is_float($value)) {
            if (is_float($value) && is_nan($value)) {
                return 'NaN';
            }
            if (is_float($value) && is_infinite($value)) {
                return $value > 0 ? 'Infinity' : '-Infinity';
            }
            return Json::number($value);
        }
        if (is_string($value)) {
            return $value;
        }
        if ($value instanceof Undefined) {
            return 'undefined';
        }
        if (is_array($value) && array_is_list($value)) {
            return implode(',', array_map(fn ($item) => $item === null || $item instanceof Undefined ? '' : self::string($item), $value));
        }
        return '[object Object]';
    }

    /**
     * value[key]: Undefined::value() when there is no such property, and a TypeError for a property of null or
     * undefined, as JavaScript throws then.
     */
    public static function get(mixed $value, string|int $key): mixed
    {
        if ($value === null || $value instanceof Undefined) {
            throw new \TypeError("Cannot read properties of " . ($value === null ? 'null' : 'undefined') . " (reading '$key')");
        }
        if ($value instanceof \stdClass) {
            return property_exists($value, (string) $key) ? $value->{$key} : Undefined::value();
        }
        if (is_array($value)) {
            if ($key === 'length' && array_is_list($value)) {
                return count($value);
            }
            return array_key_exists($key, $value) ? $value[$key] : Undefined::value();
        }
        if (is_string($value) && $key === 'length') {
            return self::length($value);
        }
        return Undefined::value();
    }

    /** Whether JavaScript reads a value as true. */
    public static function truthy(mixed $value): bool
    {
        if ($value === null || $value instanceof Undefined || $value === false || $value === '' || $value === 0) {
            return false;
        }
        if (is_float($value)) {
            return $value != 0 && !is_nan($value);
        }
        return true;
    }

    /** Whether typeof value is "object" and it is not null: an array or an object. */
    public static function isObject(mixed $value): bool
    {
        return is_array($value) || $value instanceof \stdClass;
    }

    /**
     * JSON.parse of a body as Response.json() reads it: a byte order mark is skipped and bytes that are not
     * UTF-8 read as U+FFFD. Objects come back as stdClass, so {} and [] stay apart.
     *
     * @return array{0: bool, 1: mixed} whether it parsed, and the value
     */
    public static function parseJson(string $text): array
    {
        if (str_starts_with($text, "\xEF\xBB\xBF")) {
            $text = substr($text, 3);
        }
        if (!mb_check_encoding($text, 'UTF-8')) {
            $before = mb_substitute_character();
            mb_substitute_character(0xFFFD);
            $text = mb_convert_encoding($text, 'UTF-8', 'UTF-8');
            mb_substitute_character($before);
        }
        try {
            return [true, Json::decode($text)];
        } catch (\JsonException) {
            return [false, null];
        }
    }

    /** text.trim(), which takes off Unicode spaces and line ends too. */
    public static function trim(string $text): string
    {
        return (string) preg_replace('/^[' . self::SPACE . ']+|[' . self::SPACE . ']+$/u', '', $text);
    }

    /** Orders two strings as JavaScript's `<` does, by UTF-16 code units: negative, zero, or positive. */
    public static function compare(string $a, string $b): int
    {
        if ($a === $b) {
            return 0;
        }
        return strcmp(self::utf16($a), self::utf16($b)) < 0 ? -1 : 1;
    }

    /** The length JavaScript gives a string: UTF-16 code units. */
    public static function length(string $text): int
    {
        return intdiv(strlen(self::utf16($text)), 2);
    }

    /**
     * text.slice(0, length), counting UTF-16 code units. Where JavaScript would cut a pair in two and keep half
     * of a character, this leaves the whole character out, since PHP text cannot hold half of one.
     */
    public static function cut(string $text, int $length): string
    {
        $units = self::utf16($text);
        if (strlen($units) <= 2 * $length) {
            return $text;
        }
        $units = substr($units, 0, 2 * $length);
        $last = ord($units[strlen($units) - 2]);
        if ($last >= 0xd8 && $last <= 0xdb) {
            $units = substr($units, 0, -2);
        }
        return mb_convert_encoding($units, 'UTF-8', 'UTF-16BE');
    }

    /** encodeURIComponent(text). */
    public static function encodeURIComponent(string $text): string
    {
        return strtr(rawurlencode($text), ['%21' => '!', '%2A' => '*', '%27' => "'", '%28' => '(', '%29' => ')']);
    }

    private static function utf16(string $text): string
    {
        return mb_convert_encoding($text, 'UTF-16BE', 'UTF-8');
    }

    private static function whole(float $n): int|float
    {
        return is_finite($n) && $n == floor($n) && abs($n) <= PHP_INT_MAX / 2 ? (int) $n : $n;
    }
}
