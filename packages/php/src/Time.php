<?php

declare(strict_types=1);

namespace Runlight;

/**
 * Dates in a site's timezone, without a date library. Ranges are computed
 * here as epoch milliseconds so the database only ever compares integers.
 *
 * A range is an array{from: int, to: int, fromDate: string, toDate: string, interval: string}: `from`
 * inclusive, `to` exclusive, and the first and last local dates covered, YYYY-MM-DD, both inclusive. A
 * bucket is an array{start: int, end: int}.
 *
 * The TypeScript reads local times through Intl.DateTimeFormat, which knows ICU's zone names. PHP's
 * DateTimeZone knows nearly the same ones, and the differences are settled here: a name is matched without
 * regard to case, the few that PHP reads as abbreviations with a fixed offset (CET, EST, MST) go to the zone
 * they name in the time zone database, ICU's own extra names (PST, SystemV/EST5EDT) are added, and
 * "Factory", which ICU refuses, is refused.
 */
final class Time
{
    public const PERIODS = ['today', 'yesterday', '7d', '30d', '90d', 'month', 'last_month', 'year', '12mo', 'all'];
    public const INTERVALS = ['hour', 'day', 'week', 'month'];
    public const COMPARE_MODES = ['previous', 'year', 'custom', 'off'];

    private const MAX_BUCKETS = 1000;
    /** A month of hours. Longer hourly ranges are cut off rather than refused. */
    private const MAX_HOURS = 744;

    /** Names Intl reads as another zone where PHP has no name, or reads it as a fixed abbreviation. */
    private const ALIASES = [
        // Links in the time zone database whose names PHP takes for abbreviations.
        'cet' => 'Europe/Brussels', 'eet' => 'Europe/Athens', 'est' => 'America/Panama', 'gmt' => 'UTC', 'gmt+0' => 'UTC',
        'gmt-0' => 'UTC', 'hst' => 'Pacific/Honolulu', 'met' => 'Europe/Brussels', 'mst' => 'America/Phoenix', 'uct' => 'UTC',
        'wet' => 'Europe/Lisbon',
        // ICU's three letter names, kept from early Java.
        'act' => 'Australia/Darwin', 'aet' => 'Australia/Sydney', 'agt' => 'America/Argentina/Buenos_Aires', 'art' => 'Africa/Cairo',
        'ast' => 'America/Anchorage', 'bet' => 'America/Sao_Paulo', 'bst' => 'Asia/Dhaka', 'cat' => 'Africa/Maputo',
        'cnt' => 'America/St_Johns', 'cst' => 'America/Chicago', 'ctt' => 'Asia/Shanghai', 'eat' => 'Africa/Nairobi',
        'ect' => 'Europe/Paris', 'iet' => 'America/Indiana/Indianapolis', 'ist' => 'Asia/Kolkata', 'jst' => 'Asia/Tokyo',
        'mit' => 'Pacific/Apia', 'net' => 'Asia/Yerevan', 'nst' => 'Pacific/Auckland', 'plt' => 'Asia/Karachi',
        'pnt' => 'America/Phoenix', 'prt' => 'America/Puerto_Rico', 'pst' => 'America/Los_Angeles', 'sst' => 'Pacific/Guadalcanal',
        'vst' => 'Asia/Ho_Chi_Minh',
        // ICU's System V zones.
        'systemv/ast4' => 'Etc/GMT+4', 'systemv/ast4adt' => 'America/Halifax', 'systemv/est5' => 'Etc/GMT+5',
        'systemv/est5edt' => 'America/New_York', 'systemv/cst6' => 'Etc/GMT+6', 'systemv/cst6cdt' => 'America/Chicago',
        'systemv/mst7' => 'Etc/GMT+7', 'systemv/mst7mdt' => 'America/Denver', 'systemv/pst8' => 'Etc/GMT+8',
        'systemv/pst8pdt' => 'America/Los_Angeles', 'systemv/yst9' => 'Etc/GMT+9', 'systemv/yst9ydt' => 'America/Anchorage',
        'systemv/hst10' => 'Etc/GMT+10',
        // Names the database dropped and ICU kept.
        'canada/east-saskatchewan' => 'America/Regina', 'us/pacific-new' => 'America/Los_Angeles',
    ];

    /** @var array<string, \DateTimeZone|false> */
    private static array $zones = [];
    /** @var array<string, string>|null lowercase name to PHP's name */
    private static ?array $names = null;

    /** The zone Intl.DateTimeFormat would use for a timeZone option, or null where it throws a RangeError. */
    private static function zone(string $timezone): ?\DateTimeZone
    {
        if (!array_key_exists($timezone, self::$zones)) {
            self::$zones[$timezone] = self::open($timezone) ?? false;
        }
        return self::$zones[$timezone] ?: null;
    }

    private static function open(string $timezone): ?\DateTimeZone
    {
        // An offset, as ECMA-402 takes one: a sign (a minus sign too), two digit hours, and optional minutes.
        if (preg_match('/^([+\-]|\x{2212})([01][0-9]|2[0-3])(?::?([0-5][0-9]))?$/uD', $timezone, $m)) {
            $sign = $m[1] === '+' ? '+' : '-';
            return new \DateTimeZone(sprintf('%s%s:%s', $sign, $m[2], $m[3] ?? '00'));
        }
        if (preg_match('/[^\x21-\x7e]/', $timezone)) {
            return null;
        }
        $key = strtolower($timezone);
        if (isset(self::ALIASES[$key])) {
            return new \DateTimeZone(self::ALIASES[$key]);
        }
        if (self::$names === null) {
            self::$names = [];
            foreach (\DateTimeZone::listIdentifiers(\DateTimeZone::ALL_WITH_BC) as $name) {
                self::$names[strtolower($name)] = $name;
            }
            unset(self::$names['factory']);
        }
        $name = self::$names[$key] ?? null;
        return $name === null ? null : new \DateTimeZone($name);
    }

    public static function isTimezone(string $value): bool
    {
        return self::zone($value) !== null;
    }

    /**
     * Year, month, day, hour, minute, and second of an instant in a zone, as Intl formats them.
     *
     * @return array{int, int, int, int, int, int}
     */
    private static function parts(int $ts, string $timezone): array
    {
        $zone = self::zone($timezone) ?? throw new \InvalidArgumentException("Invalid time zone specified: $timezone");
        $seconds = intdiv($ts, 1000) - ($ts % 1000 < 0 ? 1 : 0);
        $local = (new \DateTimeImmutable("@$seconds"))->setTimezone($zone);
        return array_map('intval', explode(' ', $local->format('Y n j G i s')));
    }

    /** Milliseconds the zone is ahead of UTC at an instant. */
    private static function offset(int $ts, string $timezone): int
    {
        [$y, $mo, $d, $h, $mi, $s] = self::parts($ts, $timezone);
        return self::utc($y, $mo - 1, $d, $h, $mi, $s) - ($ts - $ts % 1000);
    }

    /** The instant a local date (and hour) begins in a zone. */
    public static function startOf(string $date, string $timezone, int $hour = 0): int
    {
        [$y, $m, $d] = self::split($date);
        $guess = self::utc($y, $m - 1, $d, $hour);
        $first = $guess - self::offset($guess, $timezone);
        $at = $guess - self::offset($first, $timezone);
        // Where clocks jump forward at that time (midnight in Santiago, Havana, and the Azores), it never
        // happens, and the sum above lands before it; the day then begins when the clocks land, at most a
        // few quarter hours on.
        for ($i = 0; $i < 8; $i++) {
            [$ly, $lm, $ld, $lh] = self::parts($at, $timezone);
            if (self::utc($ly, $lm - 1, $ld, $lh) >= $guess) {
                break;
            }
            $at += 15 * 60_000;
        }
        return $at;
    }

    /** The local date of an instant, YYYY-MM-DD. */
    public static function localDate(int $ts, string $timezone): string
    {
        [$y, $m, $d] = self::parts($ts, $timezone);
        return sprintf('%s-%02d-%02d', str_pad((string) $y, 4, '0', STR_PAD_LEFT), $m, $d);
    }

    public static function addDays(string $date, int $days): string
    {
        [$y, $m, $d] = self::split($date);
        return substr(self::iso(self::utc($y, $m - 1, $d + $days)), 0, 10);
    }

    public static function addMonths(string $date, int $months): string
    {
        [$y, $m] = self::split($date);
        return substr(self::iso(self::utc($y, $m - 1 + $months, 1)), 0, 10);
    }

    public static function isDate(string $value): bool
    {
        // Years from 1900 to 9998, so the day after any date is a date too.
        if (!preg_match('/^\d{4}-\d{2}-\d{2}$/D', $value) || strcmp($value, '1900') < 0 || strcmp($value, '9999') >= 0) {
            return false;
        }
        // A month or day that does not exist (2026-13-01) makes no date at all, rather than a wrong one.
        [$y, $m, $d] = self::split($value);
        return checkdate($m, $d, $y);
    }

    private static function daysBetween(string $from, string $to): int
    {
        [$fy, $fm, $fd] = self::split($from);
        [$ty, $tm, $td] = self::split($to);
        return intdiv(self::utc($ty, $tm - 1, $td) - self::utc($fy, $fm - 1, $fd), 86_400_000);
    }

    private static function defaultInterval(string $fromDate, string $toDate): string
    {
        $days = self::daysBetween($fromDate, $toDate);
        if ($days < 1) {
            return 'hour';
        }
        if ($days <= 92) {
            return 'day';
        }
        return 'month';
    }

    /**
     * A named period or custom dates as a range in the site's timezone.
     * `$firstDate` is the earliest local date with data, used by "all".
     *
     * @param array{period?: ?string, from?: ?string, to?: ?string, interval?: ?string} $input
     * @return array{from: int, to: int, fromDate: string, toDate: string, interval: string}|null
     */
    public static function resolveRange(array $input, string $timezone, int $now, ?string $firstDate = null): ?array
    {
        $today = self::localDate($now, $timezone);
        $from = $input['from'] ?? null;
        $to = $input['to'] ?? null;

        if (($from !== null && $from !== '') || ($to !== null && $to !== '')) {
            if ($from === null || $from === '' || $to === null || $to === '' || !self::isDate($from) || !self::isDate($to) || strcmp($from, $to) > 0) {
                return null;
            }
            $fromDate = $from;
            $toDate = $to;
        } else {
            $monthStart = substr($today, 0, 8) . '01';
            switch ($input['period'] ?? '30d') {
                case 'today': $fromDate = $toDate = $today; break;
                case 'yesterday': $fromDate = $toDate = self::addDays($today, -1); break;
                case '7d': $fromDate = self::addDays($today, -6); $toDate = $today; break;
                case '30d': $fromDate = self::addDays($today, -29); $toDate = $today; break;
                case '90d': $fromDate = self::addDays($today, -89); $toDate = $today; break;
                case 'month': $fromDate = $monthStart; $toDate = $today; break;
                case 'last_month': $fromDate = self::addMonths($today, -1); $toDate = self::addDays($monthStart, -1); break;
                case 'year': $fromDate = substr($today, 0, 4) . '-01-01'; $toDate = $today; break;
                case '12mo': $fromDate = self::addMonths($today, -11); $toDate = $today; break;
                case 'all': $fromDate = $firstDate !== null && $firstDate !== '' && strcmp($firstDate, $today) < 0 ? $firstDate : $today; $toDate = $today; break;
                default: return null;
            }
        }

        $interval = in_array($input['interval'] ?? null, self::INTERVALS, true) ? $input['interval'] : self::defaultInterval($fromDate, $toDate);
        return ['from' => self::startOf($fromDate, $timezone), 'to' => self::startOf(self::addDays($toDate, 1), $timezone), 'fromDate' => $fromDate, 'toDate' => $toDate, 'interval' => $interval];
    }

    private static function addYears(string $date, int $years): string
    {
        [$y, $m, $d] = self::split($date);
        $shifted = self::utc($y + $years, $m - 1, $d);
        // Feb 29 in a year without one becomes Feb 28, not Mar 1.
        [$sy, $sm] = self::civil($shifted);
        if ($sm - 1 !== $m - 1) {
            // setUTCDate(0): the last day of the month before.
            $shifted = self::utc($sy, $sm - 1, 0);
        }
        return substr(self::iso($shifted), 0, 10);
    }

    /**
     * The range a period is compared with: the same number of days just before
     * it, the same dates a year earlier, or custom dates. Null for "off" or bad
     * custom dates.
     *
     * @param array{from: int, to: int, fromDate: string, toDate: string, interval: string} $range
     * @param array{from?: ?string, to?: ?string} $custom
     * @return array{from: int, to: int, fromDate: string, toDate: string, interval: string}|null
     */
    public static function compareRange(array $range, string $mode, string $timezone, array $custom = []): ?array
    {
        if ($mode === 'off') {
            return null;
        }
        if ($mode === 'year') {
            $fromDate = self::addYears($range['fromDate'], -1);
            $toDate = self::addYears($range['toDate'], -1);
        } elseif ($mode === 'custom') {
            $from = $custom['from'] ?? null;
            $to = $custom['to'] ?? null;
            if ($from === null || $from === '' || $to === null || $to === '' || !self::isDate($from) || !self::isDate($to) || strcmp($from, $to) > 0) {
                return null;
            }
            $fromDate = $from;
            $toDate = $to;
        } else {
            $days = self::daysBetween($range['fromDate'], $range['toDate']) + 1;
            $fromDate = self::addDays($range['fromDate'], -$days);
            $toDate = self::addDays($range['fromDate'], -1);
        }
        return ['from' => self::startOf($fromDate, $timezone), 'to' => self::startOf(self::addDays($toDate, 1), $timezone), 'fromDate' => $fromDate, 'toDate' => $toDate, 'interval' => $range['interval']];
    }

    /**
     * Chart buckets covering a range, each starting on a local boundary.
     *
     * @param array{from: int, to: int, fromDate: string, toDate: string, interval: string} $range
     * @return list<array{start: int, end: int}>
     */
    public static function buckets(array $range, string $timezone): array
    {
        $starts = [];
        if ($range['interval'] === 'hour') {
            for ($t = $range['from']; $t < $range['to'] && count($starts) < self::MAX_HOURS; $t += 3_600_000) {
                $starts[] = $t;
            }
        } else {
            $date = $range['fromDate'];
            if ($range['interval'] === 'week') {
                $date = self::addDays($date, -self::weekday($date));
            } elseif ($range['interval'] === 'month') {
                $date = substr($date, 0, 8) . '01';
            }
            while (strcmp($date, $range['toDate']) <= 0 && count($starts) < self::MAX_BUCKETS) {
                $starts[] = self::startOf($date, $timezone);
                $date = match ($range['interval']) {
                    'day' => self::addDays($date, 1),
                    'week' => self::addDays($date, 7),
                    default => self::addMonths($date, 1),
                };
            }
        }
        $out = [];
        foreach ($starts as $i => $start) {
            $out[] = ['start' => max($start, $range['from']), 'end' => min($starts[$i + 1] ?? $range['to'], $range['to'])];
        }
        return $out;
    }

    /**
     * Monday is 0.
     *
     * @return array{int, int} weekday and hour
     */
    public static function localWeekdayHour(int $ts, string $timezone): array
    {
        [$y, $m, $d, $h] = self::parts($ts, $timezone);
        return [self::weekday(sprintf('%04d-%02d-%02d', $y, $m, $d)), $h];
    }

    /** Monday is 0. */
    private static function weekday(string $date): int
    {
        [$y, $m, $d] = self::split($date);
        $days = intdiv(self::utc($y, $m - 1, $d), 86_400_000);
        // 1970-01-01 was a Thursday.
        return self::mod($days + 3, 7);
    }

    /** @return array{int, int, int} */
    private static function split(string $date): array
    {
        $parts = array_map('intval', explode('-', $date));
        return [$parts[0], $parts[1] ?? 0, $parts[2] ?? 0];
    }

    private static function mod(int $a, int $b): int
    {
        return (($a % $b) + $b) % $b;
    }

    /** Date.UTC: months and days past their ends roll over, and a year from 0 to 99 means 1900 to 1999. */
    private static function utc(int $year, int $month, int $day, int $hour = 0, int $minute = 0, int $second = 0): int
    {
        if ($year >= 0 && $year <= 99) {
            $year += 1900;
        }
        $year += intdiv($month - self::mod($month, 12), 12);
        $month = self::mod($month, 12) + 1;
        $days = self::daysFromCivil($year, $month, 1) + $day - 1;
        return $days * 86_400_000 + $hour * 3_600_000 + $minute * 60_000 + $second * 1000;
    }

    /** Days from 1970-01-01 to a proleptic Gregorian date. */
    private static function daysFromCivil(int $y, int $m, int $d): int
    {
        $y -= $m <= 2 ? 1 : 0;
        $era = intdiv($y >= 0 ? $y : $y - 399, 400);
        $yoe = $y - $era * 400;
        $doy = intdiv(153 * ($m + ($m > 2 ? -3 : 9)) + 2, 5) + $d - 1;
        $doe = $yoe * 365 + intdiv($yoe, 4) - intdiv($yoe, 100) + $doy;
        return $era * 146097 + $doe - 719468;
    }

    /** @return array{int, int, int} year, month, and day of an instant in UTC */
    private static function civil(int $ms): array
    {
        $z = intdiv($ms - self::mod($ms, 86_400_000), 86_400_000) + 719468;
        $era = intdiv($z >= 0 ? $z : $z - 146096, 146097);
        $doe = $z - $era * 146097;
        $yoe = intdiv($doe - intdiv($doe, 1460) + intdiv($doe, 36524) - intdiv($doe, 146096), 365);
        $doy = $doe - (365 * $yoe + intdiv($yoe, 4) - intdiv($yoe, 100));
        $mp = intdiv(5 * $doy + 2, 153);
        $d = $doy - intdiv(153 * $mp + 2, 5) + 1;
        $m = $mp < 10 ? $mp + 3 : $mp - 9;
        return [$yoe + $era * 400 + ($m <= 2 ? 1 : 0), $m, $d];
    }

    /** The date part of Date.prototype.toISOString, with its six digit form outside years 0 to 9999. */
    private static function iso(int $ms): string
    {
        [$y, $m, $d] = self::civil($ms);
        $year = $y >= 0 && $y <= 9999 ? sprintf('%04d', $y) : ($y < 0 ? '-' : '+') . sprintf('%06d', abs($y));
        return sprintf('%s-%02d-%02d', $year, $m, $d);
    }
}
