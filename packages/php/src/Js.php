<?php

declare(strict_types=1);

namespace Runlight;

/**
 * The few JavaScript string and number rules the port has to keep exactly:
 * lengths and slices counted in UTF-16 units, trim() with JavaScript's idea of
 * white space, decodeURIComponent's strictness, String(value), Number(value),
 * Math.round, truthiness, property reads, and comparing text with `<`.
 *
 * PHP strings are bytes, so text that is not valid UTF-8 is first made valid
 * as a browser's TextDecoder would make it, each broken sequence becoming one
 * U+FFFD. A slice that cuts a surrogate pair in two leaves U+FFFD in place of
 * the lone half, which is what the TypeScript SDK stores once it writes the
 * text out as UTF-8.
 */
final class Js
{
    /** The characters JavaScript's \s and trim() treat as white space, for a /u character class. */
    public const SPACE = '\t\n\x{0B}\f\r \x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}';

    /** Text as valid UTF-8, each ill-formed sequence replaced by U+FFFD as the WHATWG decoder does. */
    public static function scrub(string $text): string
    {
        if (mb_check_encoding($text, 'UTF-8')) {
            return $text;
        }
        $out = '';
        $length = strlen($text);
        $i = 0;
        while ($i < $length) {
            $b = ord($text[$i]);
            if ($b < 0x80) {
                $out .= $text[$i++];
                continue;
            }
            [$need, $low, $high] = match (true) {
                $b >= 0xC2 && $b <= 0xDF => [1, 0x80, 0xBF],
                $b === 0xE0 => [2, 0xA0, 0xBF],
                $b === 0xED => [2, 0x80, 0x9F],
                $b >= 0xE1 && $b <= 0xEF => [2, 0x80, 0xBF],
                $b === 0xF0 => [3, 0x90, 0xBF],
                $b >= 0xF1 && $b <= 0xF3 => [3, 0x80, 0xBF],
                $b === 0xF4 => [3, 0x80, 0x8F],
                default => [0, 0, 0],
            };
            if ($need === 0) {
                $out .= "\u{FFFD}";
                $i++;
                continue;
            }
            $j = $i + 1;
            $ok = true;
            for ($k = 0; $k < $need; $k++, $j++) {
                $c = $j < $length ? ord($text[$j]) : -1;
                if ($c < ($k === 0 ? $low : 0x80) || $c > ($k === 0 ? $high : 0xBF)) {
                    $ok = false;
                    break;
                }
            }
            if ($ok) {
                $out .= substr($text, $i, $need + 1);
            } else {
                // The maximal subpart read so far becomes one replacement; the byte that broke it starts again.
                $out .= "\u{FFFD}";
            }
            $i = $j;
        }
        return $out;
    }

    /** The length JavaScript gives a string: UTF-16 code units. */
    public static function length(string $text): int
    {
        if (!preg_match('/[\x80-\xff]/', $text)) {
            return strlen($text);
        }
        return intdiv(strlen(mb_convert_encoding(self::scrub($text), 'UTF-16LE', 'UTF-8')), 2);
    }

    /** String.prototype.slice, counting UTF-16 code units. */
    public static function slice(string $text, int $start, ?int $end = null): string
    {
        if ($start === 0 && $end !== null && $end >= 0 && strlen($text) <= $end) {
            // UTF-8 never has fewer bytes than UTF-16 has units, so nothing is cut.
            return self::scrub($text);
        }
        $ascii = !preg_match('/[\x80-\xff]/', $text);
        $units = $ascii ? $text : mb_convert_encoding(self::scrub($text), 'UTF-16BE', 'UTF-8');
        $width = $ascii ? 1 : 2;
        $count = intdiv(strlen($units), $width);
        $from = $start < 0 ? max(0, $count + $start) : min($start, $count);
        $to = $end === null ? $count : ($end < 0 ? max(0, $count + $end) : min($end, $count));
        if ($to <= $from) {
            return '';
        }
        $part = substr($units, $from * $width, ($to - $from) * $width);
        if ($ascii) {
            return $part;
        }
        $first = (ord($part[0]) << 8) | ord($part[1]);
        if ($first >= 0xDC00 && $first <= 0xDFFF) {
            $part = "\xFF\xFD" . substr($part, 2);
        }
        $n = strlen($part);
        $last = (ord($part[$n - 2]) << 8) | ord($part[$n - 1]);
        if ($last >= 0xD800 && $last <= 0xDBFF) {
            $part = substr($part, 0, $n - 2) . "\xFF\xFD";
        }
        return mb_convert_encoding($part, 'UTF-8', 'UTF-16BE');
    }

    /** String.prototype.trim: JavaScript's white space and line terminators, at both ends. */
    public static function trim(string $text): string
    {
        return (string) preg_replace('/^[' . self::SPACE . ']+|[' . self::SPACE . ']+$/uD', '', self::scrub($text));
    }

    public static function lower(string $text): string
    {
        return preg_match('/[\x80-\xff]/', $text) ? mb_strtolower(self::scrub($text), 'UTF-8') : strtolower($text);
    }

    public static function upper(string $text): string
    {
        return preg_match('/[\x80-\xff]/', $text) ? mb_strtoupper(self::scrub($text), 'UTF-8') : strtoupper($text);
    }

    /** decodeURIComponent, or null where it would throw: a broken escape or bytes that are not UTF-8. */
    public static function decodeURIComponent(string $text): ?string
    {
        if (preg_match('/%(?![0-9A-Fa-f]{2})/', $text)) {
            return null;
        }
        $decoded = rawurldecode($text);
        return mb_check_encoding($decoded, 'UTF-8') ? $decoded : null;
    }

    /** String(value) for the values the SDK passes it. */
    public static function string(mixed $value): string
    {
        return match (true) {
            $value === null => 'null',
            $value instanceof Undefined => 'undefined',
            is_bool($value) => $value ? 'true' : 'false',
            is_int($value) => (string) $value,
            is_float($value) => is_nan($value) ? 'NaN' : (is_infinite($value) ? ($value > 0 ? 'Infinity' : '-Infinity') : Json::number($value)),
            is_string($value) => $value,
            // An array is its items joined with commas, null and undefined as nothing.
            is_array($value) && array_is_list($value) => implode(',', array_map(fn ($v) => $v === null || $v instanceof Undefined ? '' : self::string($v), $value)),
            $value instanceof \Stringable => (string) $value,
            default => '[object Object]',
        };
    }

    /** Math.round: halves go up, toward positive infinity, so -2.5 becomes -2. */
    public static function round(float $value): float
    {
        if (is_nan($value) || is_infinite($value)) {
            return $value;
        }
        $floor = floor($value);
        // A double's distance from its floor is exact, so 0.49999999999999994 stays 0.
        return $value - $floor >= 0.5 ? $floor + 1 : $floor;
    }

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

    /** Orders two strings as JavaScript's `<` does, by UTF-16 code units: negative, zero, or positive. */
    public static function compare(string $a, string $b): int
    {
        if ($a === $b) {
            return 0;
        }
        return strcmp(self::utf16($a), self::utf16($b)) < 0 ? -1 : 1;
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
