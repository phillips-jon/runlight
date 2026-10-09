<?php

declare(strict_types=1);

namespace Runlight;

/**
 * The dashboard's translations, for text the server writes (email reports).
 * Same keys, same placeholders, so every language stays in one place.
 */
final class Messages
{
    /** @var array<string, string>|null each language's table as JSON text, from the shared assets */
    private static ?array $raw = null;

    /** @var array<string, array<string, string>> */
    private static array $parsed = [];

    /** @return array<string, string> */
    private static function raw(): array
    {
        return self::$raw ??= Json::decode((string) file_get_contents(__DIR__ . '/../assets/locales.json'), true);
    }

    /** @return array<string, string> */
    private static function table(string $lang): array
    {
        if (!isset(self::$parsed[$lang])) {
            $raw = self::raw()[$lang] ?? null;
            self::$parsed[$lang] = is_string($raw) ? Json::decode($raw, true) : [];
        }
        return self::$parsed[$lang];
    }

    /** @return list<string> */
    public static function languages(): array
    {
        return ['en', ...array_values(array_filter(array_keys(self::raw()), fn ($code) => $code !== 'en'))];
    }

    /**
     * The words for one language: t(key, vars) and tn(key, n, vars), with
     * `lang` the language used, English when the one asked for is not known.
     *
     * @return array{t: \Closure(string, array<string, string|int|float>=): string, tn: \Closure(string, int|float, array<string, string|int|float>=): string, lang: string}
     */
    public static function translator(string $lang): array
    {
        $code = in_array($lang, self::languages(), true) ? $lang : 'en';
        $fill = static fn (string $text, array $vars): string => (string) preg_replace_callback(
            '/\{(\w+)\}/',
            static fn (array $m): string => array_key_exists($m[1], $vars) ? Js::string($vars[$m[1]]) : $m[0],
            $text,
        );
        $t = static fn (string $key, array $vars = []): string => $fill(self::table($code)[$key] ?? self::table('en')[$key] ?? $key, $vars);
        $tn = static function (string $key, int|float $n, array $vars = []) use ($code, $fill, $t): string {
            $form = self::plural($code, $n);
            $own = self::table($code)["{$key}_$form"] ?? self::table($code)["{$key}_other"] ?? null;
            return $own !== null && $own !== '' ? $fill($own, $vars) : $t("{$key}_other", $vars);
        };
        return ['t' => $t, 'tn' => $tn, 'lang' => $code];
    }

    /**
     * Intl.PluralRules(lang).select(n) for the dashboard's languages, by CLDR's cardinal rules. As there, the
     * number is first written with at most three decimals (rounding half away from zero), and its integer
     * digits i and visible decimals v are read from that. Any other language answers "other".
     *
     * - en, de: one when i = 1 and v = 0
     * - es: one when n = 1; many when i is a non-zero multiple of a million and v = 0
     * - fr, pt: one when i is 0 or 1; many as in es
     */
    public static function plural(string $lang, int|float $n): string
    {
        if (is_float($n) && (is_nan($n) || is_infinite($n))) {
            return 'other';
        }
        [$i, $fraction] = self::decimal(abs($n));
        $v = strlen($fraction);
        $million = $i !== '0' && strlen($i) >= 7 && substr($i, -6) === '000000';
        switch ($lang) {
            case 'en':
            case 'de':
                return $i === '1' && $v === 0 ? 'one' : 'other';
            case 'es':
                if ($i === '1' && $v === 0) {
                    return 'one';
                }
                return $million && $v === 0 ? 'many' : 'other';
            case 'fr':
            case 'pt':
                if ($i === '0' || $i === '1') {
                    return 'one';
                }
                return $million && $v === 0 ? 'many' : 'other';
        }
        return 'other';
    }

    /**
     * A non-negative number as its integer digits and up to three decimals without trailing zeros, from the
     * shortest decimal that reads back as the number, as ICU formats it.
     *
     * @return array{0: string, 1: string}
     */
    private static function decimal(int|float $n): array
    {
        $text = Json::number($n);
        // Plain digits, from JavaScript's exponent form where it uses one.
        if (preg_match('/^(\d+)(?:\.(\d+))?e([+-]\d+)$/', $text, $m)) {
            $digits = $m[1] . ($m[2] ?? '');
            $point = strlen($m[1]) + (int) $m[3];
            if ($point <= 0) {
                $text = '0.' . str_repeat('0', -$point) . $digits;
            } elseif ($point >= strlen($digits)) {
                $text = $digits . str_repeat('0', $point - strlen($digits));
            } else {
                $text = substr($digits, 0, $point) . '.' . substr($digits, $point);
            }
        }
        [$whole, $fraction] = array_pad(explode('.', $text, 2), 2, '');
        if (strlen($fraction) > 3) {
            $up = (int) $fraction[3] >= 5;
            $fraction = substr($fraction, 0, 3);
            if ($up) {
                // Add one at the third decimal, carrying into the whole part.
                $all = self::increment($whole . $fraction);
                $whole = substr($all, 0, strlen($all) - 3);
                $fraction = substr($all, -3);
            }
        }
        // ICU reads i as a 64-bit integer, keeping only the lowest 18 digits of a larger number, so 1e21 has i = 0.
        $whole = ltrim(substr($whole, -18), '0');
        return [$whole === '' ? '0' : $whole, rtrim($fraction, '0')];
    }

    private static function increment(string $digits): string
    {
        $i = strlen($digits) - 1;
        while ($i >= 0 && $digits[$i] === '9') {
            $digits[$i] = '0';
            $i--;
        }
        return $i < 0 ? '1' . $digits : substr_replace($digits, (string) ((int) $digits[$i] + 1), $i, 1);
    }
}
