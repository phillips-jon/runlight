<?php

declare(strict_types=1);

namespace Runlight;

/**
 * JSON written exactly as JavaScript's JSON.stringify writes it, so answers
 * match the TypeScript SDK byte for byte: slashes and Unicode as they are,
 * whole floats without a decimal point, numbers in JavaScript's own form,
 * and NaN or infinity as null.
 *
 * A PHP list becomes an array and any other array an object. An empty array
 * is an empty JSON array; pass Json::object() or a stdClass for an empty
 * object. Decoding gives objects as stdClass (so {} and [] stay apart) unless
 * `$assoc` asks for arrays.
 */
final class Json
{
    public static function encode(mixed $value, bool $pretty = false): string
    {
        return $pretty ? self::pretty($value, '') : self::write($value);
    }

    public static function decode(string $text, bool $assoc = false): mixed
    {
        return json_decode($text, $assoc, 512, JSON_THROW_ON_ERROR | JSON_BIGINT_AS_STRING);
    }

    /** Decodes, or gives null for text that is not JSON. */
    public static function tryDecode(string $text, bool $assoc = false): mixed
    {
        try {
            return self::decode($text, $assoc);
        } catch (\JsonException) {
            return null;
        }
    }

    /** An empty JSON object, or `$fields` written as an object even when empty or a list. */
    public static function object(array $fields = []): \stdClass
    {
        return (object) $fields;
    }

    /** A number as JavaScript's String(number) writes it. */
    public static function number(int|float $n): string
    {
        if (is_int($n)) {
            return (string) $n;
        }
        if (is_nan($n) || is_infinite($n)) {
            return 'null';
        }
        $text = var_export($n, true);
        if ($n == floor($n) && abs($n) < 1e21) {
            if ($n == 0) {
                return '0';
            }
            if (abs($n) < 2 ** 53 || !str_contains($text, 'E')) {
                return sprintf('%.0f', $n);
            }
            // Past 2^53 JavaScript writes the shortest digits that read back, then zeros: 12345678901234567000, not ...168.
            [$mantissa, $exponent] = explode('E', $text);
            $digits = str_replace(['-', '.'], '', $mantissa);
            return ($n < 0 ? '-' : '') . str_pad($digits, (int) $exponent + 1, '0');
        }
        if (!str_contains($text, 'E')) {
            return $text;
        }
        // PHP writes 1.0E-7 or 1.2E+25; JavaScript writes 1e-7 and 1.2e+25, and uses plain digits down to 1e-6.
        [$mantissa, $exponent] = explode('E', $text);
        $mantissa = rtrim(rtrim($mantissa, '0'), '.');
        $exp = (int) $exponent;
        if ($exp >= -6 && $exp < 0) {
            $digits = str_replace(['-', '.'], '', $mantissa);
            return ($n < 0 ? '-' : '') . '0.' . str_repeat('0', -$exp - 1) . $digits;
        }
        return $mantissa . 'e' . ($exp > 0 ? '+' : '-') . abs($exp);
    }

    private static function write(mixed $value): string
    {
        if ($value === null) {
            return 'null';
        }
        if (is_bool($value)) {
            return $value ? 'true' : 'false';
        }
        if (is_int($value) || is_float($value)) {
            return self::number($value);
        }
        if (is_string($value)) {
            return self::string($value);
        }
        if ($value instanceof \JsonSerializable) {
            return self::write($value->jsonSerialize());
        }
        if (is_array($value) && array_is_list($value)) {
            return '[' . implode(',', array_map(fn ($item) => self::write(self::item($item)), $value)) . ']';
        }
        if (is_array($value) || is_object($value)) {
            $parts = [];
            foreach ((array) $value as $key => $item) {
                // An undefined field is left out, as JSON.stringify leaves out undefined.
                if ($item instanceof Undefined) {
                    continue;
                }
                $parts[] = self::string((string) $key) . ':' . self::write($item);
            }
            return '{' . implode(',', $parts) . '}';
        }
        return 'null';
    }

    private static function pretty(mixed $value, string $indent): string
    {
        $inner = "$indent  ";
        if (is_array($value) && array_is_list($value)) {
            if ($value === []) {
                return '[]';
            }
            return "[\n" . implode(",\n", array_map(fn ($item) => $inner . self::pretty(self::item($item), $inner), $value)) . "\n$indent]";
        }
        if ((is_array($value) || $value instanceof \stdClass)) {
            $parts = [];
            foreach ((array) $value as $key => $item) {
                if ($item instanceof Undefined) {
                    continue;
                }
                $parts[] = $inner . self::string((string) $key) . ': ' . self::pretty($item, $inner);
            }
            return $parts === [] ? '{}' : "{\n" . implode(",\n", $parts) . "\n$indent}";
        }
        return self::write($value);
    }

    /** In an array, an undefined item is written as null, as JSON.stringify does. */
    private static function item(mixed $item): mixed
    {
        return $item instanceof Undefined ? null : $item;
    }

    private static function string(string $text): string
    {
        $json = json_encode($text, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_LINE_TERMINATORS | JSON_INVALID_UTF8_SUBSTITUTE);
        return $json === false ? '""' : $json;
    }
}
