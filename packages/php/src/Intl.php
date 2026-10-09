<?php

declare(strict_types=1);

namespace Runlight;

/**
 * The pieces of JavaScript's Intl the email reports use, for the dashboard's languages (en, de, es, fr, and
 * pt), written out so they read the same with or without ext-intl: Intl.NumberFormat for counts, percents,
 * and one decimal place, and Intl.DateTimeFormat for a month and year or a short day. Region names and
 * currencies come from ext-intl's ICU when it is loaded, as Node's come from its own ICU; without it a
 * region stays its code and a currency is written as the amount and its code.
 *
 * Numbers round as ICU does, half away from zero on the number's shortest decimal form, so 2.05 to one
 * place is 2.1, though the double just under it is what is stored.
 */
final class Intl
{
    private const GROUP = ['en' => ',', 'de' => '.', 'es' => '.', 'fr' => "\u{202F}", 'pt' => '.'];
    private const DECIMAL = ['en' => '.', 'de' => ',', 'es' => ',', 'fr' => ',', 'pt' => ','];
    private const PERCENT = ['en' => '%s%%', 'de' => "%s\u{A0}%%", 'es' => "%s\u{A0}%%", 'fr' => "%s\u{A0}%%", 'pt' => '%s%%'];

    private const MONTHS = [
        'en' => ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'],
        'de' => ['Januar', 'Februar', 'März', 'April', 'Mai', 'Juni', 'Juli', 'August', 'September', 'Oktober', 'November', 'Dezember'],
        'es' => ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'],
        'fr' => ['janvier', 'février', 'mars', 'avril', 'mai', 'juin', 'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'],
        'pt' => ['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'],
    ];
    private const SHORT_MONTHS = [
        'en' => ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'],
        'de' => ['Jan.', 'Feb.', 'März', 'Apr.', 'Mai', 'Juni', 'Juli', 'Aug.', 'Sept.', 'Okt.', 'Nov.', 'Dez.'],
        'es' => ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sept', 'oct', 'nov', 'dic'],
        'fr' => ['janv.', 'févr.', 'mars', 'avr.', 'mai', 'juin', 'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.'],
        'pt' => ['jan.', 'fev.', 'mar.', 'abr.', 'mai.', 'jun.', 'jul.', 'ago.', 'set.', 'out.', 'nov.', 'dez.'],
    ];
    /** { month: "long", year: "numeric" }, then { month: "short", day: "numeric" } without and with the year. */
    private const DATE_PATTERNS = [
        'en' => ['{M} {y}', '{m} {d}', '{m} {d}, {y}'],
        'de' => ['{M} {y}', '{d}. {m}', '{d}. {m} {y}'],
        'es' => ['{M} de {y}', '{d} {m}', '{d} {m} {y}'],
        'fr' => ['{M} {y}', '{d} {m}', '{d} {m} {y}'],
        'pt' => ['{M} de {y}', '{d} de {m}', '{d} de {m} de {y}'],
    ];

    private static function lang(string $lang): string
    {
        return isset(self::GROUP[$lang]) ? $lang : 'en';
    }

    /** new Intl.NumberFormat(lang, { minimumFractionDigits, maximumFractionDigits }).format(n); the defaults are 0 and 3. */
    public static function number(string $lang, int|float $n, int $minFraction = 0, int $maxFraction = 3): string
    {
        $lang = self::lang($lang);
        if (is_float($n) && is_nan($n)) {
            return 'NaN';
        }
        if (is_float($n) && is_infinite($n)) {
            return ($n < 0 ? '-' : '') . '∞';
        }
        [$negative, $whole, $fraction] = self::rounded($n, $minFraction, $maxFraction);
        // Spanish groups only from five digits on (CLDR's minimum grouping digits of 2).
        if (!($lang === 'es' && strlen($whole) < 5)) {
            $whole = (string) preg_replace('/\B(?=(\d{3})+$)/', self::GROUP[$lang], $whole);
        }
        return ($negative ? '-' : '') . $whole . ($fraction !== '' ? self::DECIMAL[$lang] . $fraction : '');
    }

    /** new Intl.NumberFormat(lang, { style: "percent", maximumFractionDigits: 0 }).format(n). */
    public static function percent(string $lang, int|float $n): string
    {
        $lang = self::lang($lang);
        return sprintf(self::PERCENT[$lang], self::number($lang, self::times100($n), 0, 0));
    }

    /**
     * new Intl.NumberFormat(lang, { style: "currency", currency, maximumFractionDigits }).format(n), or
     * `${n} ${currency}` where Intl throws (a currency code that is not three letters).
     */
    public static function currency(string $lang, int|float $n, string $currency, int $maxFraction): string
    {
        $lang = self::lang($lang);
        if (!preg_match('/^[A-Za-z]{3}$/D', $currency)) {
            return Js::string($n) . " $currency";
        }
        $code = strtoupper($currency);
        if (class_exists(\NumberFormatter::class)) {
            $format = new \NumberFormatter($lang, \NumberFormatter::CURRENCY);
            $format->setAttribute(\NumberFormatter::MAX_FRACTION_DIGITS, $maxFraction);
            if ($maxFraction < 2) {
                $format->setAttribute(\NumberFormatter::MIN_FRACTION_DIGITS, $maxFraction);
            }
            $text = $format->formatCurrency((float) $n, $code);
            if (is_string($text)) {
                // ICU's currency format groups four digits in Spanish, where Node's leaves them alone.
                return $lang === 'es' ? (string) preg_replace('/(?<![\d.])(\d)\.(\d{3})(?![\d.])/', '$1$2', $text) : $text;
            }
        }
        $amount = self::number($lang, $n, min(2, $maxFraction), $maxFraction);
        return $lang === 'en' || $lang === 'pt' ? "$code\u{A0}$amount" : "$amount\u{A0}$code";
    }

    /** A date, YYYY-MM-DD, as { month: "long", year: "numeric" } writes it. */
    public static function monthYear(string $lang, string $date): string
    {
        return self::date($lang, $date, 0);
    }

    /** A date as { month: "short", day: "numeric" } writes it, with `year: "numeric"` too when asked. */
    public static function shortDay(string $lang, string $date, bool $withYear): string
    {
        return self::date($lang, $date, $withYear ? 2 : 1);
    }

    private static function date(string $lang, string $date, int $pattern): string
    {
        $lang = self::lang($lang);
        [$y, $m, $d] = array_map('intval', explode('-', $date));
        return strtr(self::DATE_PATTERNS[$lang][$pattern], [
            '{M}' => self::MONTHS[$lang][$m - 1],
            '{m}' => self::SHORT_MONTHS[$lang][$m - 1],
            '{d}' => (string) $d,
            '{y}' => (string) $y,
        ]);
    }

    /**
     * new Intl.DisplayNames(lang, { type: "region" }).of(code), or the code where that throws or ICU is not
     * at hand. Only an upper case code is looked up; Intl gives any other back as it came.
     */
    public static function region(string $lang, string $code): string
    {
        if (!preg_match('/^([A-Z]{2}|\d{3})$/D', $code) || !class_exists(\Locale::class)) {
            return $code;
        }
        $name = \Locale::getDisplayRegion("-$code", self::lang($lang));
        return is_string($name) && $name !== '' ? $name : $code;
    }

    /** n * 100, worked out on the decimal digits, as ICU scales a percent, so 0.135 is 13.5 and not 13.500000000000002. */
    private static function times100(int|float $n): int|float
    {
        if (is_int($n)) {
            return $n * 100;
        }
        [$negative, $digits, $point] = self::decimal($n);
        return (float) (($negative ? '-' : '') . self::plain($digits, $point + 2));
    }

    /**
     * The number's sign, whole digits, and fraction digits, rounded half away from zero to at most
     * `$max` places and padded to at least `$min`.
     *
     * @return array{bool, string, string}
     */
    private static function rounded(int|float $n, int $min, int $max): array
    {
        if (is_int($n)) {
            return [$n < 0, (string) abs($n), str_repeat('0', $min)];
        }
        [$negative, $digits, $point] = self::decimal($n);
        // Digits as a whole number of units of 10^-max.
        $keep = $point + $max;
        if ($keep < 0) {
            $units = '0';
        } elseif (strlen($digits) > $keep) {
            $units = $keep === 0 ? '0' : substr($digits, 0, $keep);
            if ((int) $digits[$keep] >= 5) {
                $units = self::increment($units);
            }
        } else {
            $units = str_pad($digits, $keep, '0');
        }
        $units = str_pad($units, $max + 1, '0', STR_PAD_LEFT);
        $whole = ltrim(substr($units, 0, strlen($units) - $max), '0');
        $fraction = rtrim($max > 0 ? substr($units, -$max) : '', '0');
        $fraction = str_pad($fraction, $min, '0');
        return [$negative, $whole === '' ? '0' : $whole, $fraction];
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

    /**
     * The shortest decimal form of a double: its sign, its significant digits, and where the point
     * goes (the number of digits before it, which may be zero or negative).
     *
     * @return array{bool, string, int}
     */
    private static function decimal(float $n): array
    {
        $negative = $n < 0 || ($n == 0 && fdiv(1, $n) < 0);
        $text = var_export(abs($n), true);
        $exponent = 0;
        if (preg_match('/^(.*)E([+-]?\d+)$/i', $text, $m)) {
            $text = $m[1];
            $exponent = (int) $m[2];
        }
        [$int, $fraction] = array_pad(explode('.', $text), 2, '');
        $digits = $int . $fraction;
        $point = strlen($int) + $exponent;
        $trimmed = ltrim($digits, '0');
        $point -= strlen($digits) - strlen($trimmed);
        $trimmed = rtrim($trimmed, '0');
        return [$negative, $trimmed === '' ? '0' : $trimmed, $trimmed === '' ? 1 : $point];
    }

    /** Digits with the point after `$point` of them, written out in full. */
    private static function plain(string $digits, int $point): string
    {
        if ($point <= 0) {
            return '0.' . str_repeat('0', -$point) . $digits;
        }
        if ($point >= strlen($digits)) {
            return $digits . str_repeat('0', $point - strlen($digits));
        }
        return substr($digits, 0, $point) . '.' . substr($digits, $point);
    }
}
