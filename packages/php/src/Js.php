<?php

declare(strict_types=1);

namespace Runlight;

/**
 * The few JavaScript string and number rules the port has to keep exactly:
 * lengths and slices counted in UTF-16 units, trim() with JavaScript's idea of
 * white space, decodeURIComponent's strictness, String(value), and Math.round.
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
}
