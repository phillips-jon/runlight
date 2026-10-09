<?php

declare(strict_types=1);

namespace Runlight\Importers;

use Runlight\Http\Url;
use Runlight\Js;
use Runlight\Json;

/**
 * Visit history from a CSV file, in one of two shapes: Umami's data export
 * (one row per pageview or event, as in its website_event table) or Runlight's
 * own, documented on the dashboard docs page. The dashboard reads the file,
 * sorts it with rowTime, and sends it in batches; the server turns each row
 * into a hit with csvHit. Nothing here touches a database.
 *
 * A format is "umami" or "runlight". A hit is an ImportedHit array (see Visits).
 */
final class CsvVisits
{
    /** At most this many rows in one request. */
    public const CSV_BATCH = 2000;

    /**
     * Which shape a file is, from its header row (lower case, as the dashboard reads it).
     *
     * @param list<string> $columns
     */
    public static function csvFormat(array $columns): ?string
    {
        $has = static fn (string $c): bool => in_array($c, $columns, true);
        if ($has('created_at') && $has('url_path')) {
            return 'umami';
        }
        if ($has('time') && ($has('path') || $has('url'))) {
            return 'runlight';
        }
        return null;
    }

    /**
     * A row's time in milliseconds, or NaN. ISO 8601 with or without a zone, "2024-05-01 12:34:56"
     * (both read as UTC when no zone is given, as Umami writes them), or a Unix time in seconds or milliseconds.
     *
     * @param array<string, string> $row
     */
    public static function rowTime(array $row, string $format): int|float
    {
        $text = Js::trim($format === 'umami' ? ($row['created_at'] ?? '') : ($row['time'] ?? ''));
        if ($text === '') {
            return NAN;
        }
        if (preg_match('/^\d+(\.\d+)?$/D', $text)) {
            $n = (float) $text;
            $ms = $n < 1e12 ? Js::round($n * 1000) : Js::round($n);
            return abs($ms) < 2 ** 53 ? (int) $ms : $ms;
        }
        $iso = preg_replace('/ /', 'T', $text, 1);
        return Http::parseDate(preg_match('/[zZ]|[+-]\d\d:?\d\d$/D', $iso) || !preg_match('/T\d/', $iso) ? $iso : "{$iso}Z");
    }

    /** @param array<string, string> $row */
    private static function cell(array $row, string ...$names): string
    {
        foreach ($names as $n) {
            if (isset($row[$n]) && Js::trim($row[$n]) !== '') {
                return Js::trim($row[$n]);
            }
        }
        return '';
    }

    /**
     * A row with no visitor is its own visit, keyed by its whole content so a second import gives it the same ids.
     *
     * @param array<string, string> $row
     */
    private static function ownKey(array $row): string
    {
        $entries = [];
        foreach ($row as $k => $v) {
            $entries[] = [(string) $k, $v];
        }
        usort($entries, static fn (array $a, array $b): int => Js::compare($a[0], $b[0]) < 0 ? -1 : 1);
        return 'row:' . Json::encode($entries);
    }

    /** A referrer as a full address: a bare domain gains https://. */
    private static function fullReferrer(string $value): string
    {
        return $value === '' ? '' : (preg_match('#^[a-z][a-z0-9+.-]*://#i', $value) ? $value : "https://$value");
    }

    /**
     * One row as a hit and the namespace its ids are made in, or null for a row that is not a pageview or a
     * named event, or has no time. Umami rows use the namespace the Umami API import does, so the same visits
     * brought in both ways get the same ids.
     *
     * @param array<string, string> $row
     * @return array{ns: string, hit: array}|null
     */
    public static function csvHit(array $row, string $format): ?array
    {
        $ts = self::rowTime($row, $format);
        if (!is_int($ts) && !is_finite($ts)) {
            return null;
        }
        if ($format === 'umami') {
            $type = self::cell($row, 'event_type');
            $type = $type !== '' ? $type : '1';
            $name = self::cell($row, 'event_name');
            if ($type !== '1' && !($type === '2' && $name !== '')) {
                return null;
            }
            $website = self::cell($row, 'website_id');
            $domain = self::cell($row, 'referrer_domain');
            $query = self::cell($row, 'referrer_query');
            $referrerPath = self::cell($row, 'referrer_path');
            $key = self::cell($row, 'session_id', 'visit_id');
            $path = self::cell($row, 'url_path');
            return [
                'ns' => $website !== '' ? "umami-visits:$website" : 'umami-csv',
                'hit' => [
                    'ts' => $ts,
                    'key' => $key !== '' ? $key : self::ownKey($row),
                    'kind' => $type === '1' ? 'pageview' : 'event',
                    'hostname' => self::cell($row, 'hostname'),
                    'path' => $path !== '' ? $path : '/',
                    'query' => self::cell($row, 'url_query'),
                    'referrer' => $domain === '' ? '' : "https://$domain" . ($referrerPath !== '' ? $referrerPath : '/') . ($query !== '' ? '?' . preg_replace('/^\?/', '', $query) : ''),
                    'title' => self::cell($row, 'page_title'),
                    'name' => $type === '2' ? $name : '',
                    'country' => self::cell($row, 'country'),
                    'region' => self::cell($row, 'subdivision1', 'region'),
                    'city' => self::cell($row, 'city'),
                    'browser' => self::cell($row, 'browser'),
                    'os' => self::cell($row, 'os'),
                    'device' => self::cell($row, 'device'),
                    'screen' => self::cell($row, 'screen'),
                    'language' => self::cell($row, 'language'),
                ],
            ];
        }
        // Runlight's own shape: a full url, or a path (with its query) and a hostname.
        $hostname = self::cell($row, 'hostname');
        $path = self::cell($row, 'path');
        $query = '';
        $url = self::cell($row, 'url');
        if ($url !== '') {
            $u = Url::parse(preg_match('#^[a-z][a-z0-9+.-]*://#i', $url) ? $url : "https://$url");
            if ($u === null) {
                return null;
            }
            $hostname = $hostname !== '' ? $hostname : $u->hostname;
            $path = $u->pathname;
            $query = substr($u->search, 1);
        } else {
            $at = strpos($path, '?');
            if ($at !== false) {
                [$path, $query] = [substr($path, 0, $at), substr($path, $at + 1)];
            }
        }
        if (!str_starts_with($path, '/')) {
            $path = "/$path";
        }
        $name = self::cell($row, 'event');
        $visitor = self::cell($row, 'visitor');
        return [
            'ns' => 'csv',
            'hit' => [
                'ts' => $ts,
                // Without a visitor column every row is its own visit.
                'key' => $visitor !== '' ? $visitor : self::ownKey($row),
                'kind' => $name !== '' ? 'event' : 'pageview',
                'hostname' => $hostname,
                'path' => $path,
                'query' => $query,
                'referrer' => self::fullReferrer(self::cell($row, 'referrer')),
                'title' => self::cell($row, 'title'),
                'name' => $name,
                'country' => self::cell($row, 'country'),
                'region' => self::cell($row, 'region'),
                'city' => self::cell($row, 'city'),
                'browser' => self::cell($row, 'browser'),
                'os' => self::cell($row, 'os'),
                'device' => self::cell($row, 'device'),
                'screen' => self::cell($row, 'screen'),
                'language' => self::cell($row, 'language'),
            ],
        ];
    }
}
