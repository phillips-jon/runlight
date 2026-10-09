<?php

declare(strict_types=1);

namespace Runlight\Importers;

use Runlight\Http\Fetcher;
use Runlight\Http\Url;
use Runlight\Js;
use Runlight\Json;
use Runlight\Runlight;
use Runlight\Sources;
use Runlight\Store\SqlStore;
use Runlight\Time;

/**
 * Visit history from Umami: pageviews and custom events with where each
 * visit came from, its place, and its device, written as imported visits so
 * the dashboard's history does not start the day Runlight was installed.
 *
 * The dashboard drives it a few days at a time, oldest first, so it fits any
 * host's time limit and shows progress. It stops where Runlight's own visits
 * begin, so nothing is counted twice, and it remembers how far it got, so
 * running it again carries on from there.
 *
 * An ImportedHit, the shape every visit import writes, is an array: `ts`, `key` (groups rows into visitors,
 * as Umami's session id does), `kind` ("pageview" or "event"), and the strings `hostname`, `path`, `query`,
 * `referrer`, `title`, `name`, `country`, `region`, `city`, `browser`, `os`, `device`, `screen`, `language`.
 */
final class Visits
{
    private const DAY = 86_400_000;
    /** Each step reads at most this many days, or stops after this many events. */
    private const STEP_DAYS = 14;
    private const STEP_EVENTS = 5_000;
    /** A single day with more than this is refused rather than read without end. */
    private const MAX_DAY_EVENTS = 200_000;

    /** Umami's event types that are visits: a pageview, and a custom event. */
    private const PAGEVIEW = 1;
    private const CUSTOM_EVENT = 2;

    private static function progressKey(string $site, string $website): string
    {
        return "import:umami-visits:$site:$website";
    }

    /**
     * The websites an Umami account can see, to pick which one becomes this site's history.
     *
     * @param array<string, string> $credentials
     * @return list<array{id: string, name: string, domain: string}>
     */
    public static function umamiWebsites(array $credentials, ?Fetcher $fetcher = null): array
    {
        $http = new Http($fetcher);
        ['base' => $base, 'token' => $token] = Umami::umamiSignIn($http, $credentials);
        $headers = ['authorization' => 'Bearer ' . Http::str($token)];
        $out = [];
        for ($page = 1; $page < 100; $page++) {
            $body = $http->getJson("$base/api/websites?page=$page&pageSize=100", ['headers' => $headers]);
            foreach ($body['data'] as $w) {
                $out[] = ['id' => $w['id'], 'name' => $w['name'], 'domain' => $w['domain']];
            }
            if (count($out) >= ($body['count'] ?? INF) || $body['data'] === []) {
                break;
            }
        }
        return $out;
    }

    /**
     * Every page of an Umami list for a time window.
     *
     * @param array<string, string> $headers
     */
    private static function all(Http $http, string $base, string $path, array $headers, int $limit): array
    {
        $out = [];
        for ($page = 1; ; $page++) {
            $body = $http->getJson("$base/api$path&page=$page&pageSize=1000", ['headers' => $headers]);
            foreach ($body['data'] as $row) {
                $out[] = $row;
            }
            if (count($out) >= ($body['count'] ?? INF) || $body['data'] === []) {
                return $out;
            }
            if (count($out) > $limit) {
                $text = number_format($limit, 0, '.', ',');
                throw new ImportError("One day has more than $text events, more than an import step can read", 'import_day_full', ['limit' => (string) $limit]);
            }
        }
    }

    /**
     * One step: read the next few days from Umami and write them as imported visits.
     *
     * @param array<string, string> $credentials
     * @return array{cursor: ?string, done: int, total: int, pageviews: int, events: int, visits: int}
     */
    public static function importUmamiVisits(Runlight $runlight, string $siteId, array $credentials, string $website, ?string $cursor): array
    {
        $runlight->init();
        $site = $runlight->site($siteId);
        if ($site === null) {
            throw new ImportError('Unknown site', 'unknown_site');
        }
        if (!preg_match('/^[A-Za-z0-9-]{1,64}$/D', $website)) {
            throw new ImportError('Pick the Umami website to import', 'import_website');
        }
        $http = new Http($runlight->fetcher);

        $saved = $cursor !== null && $cursor !== '' ? Json::decode($cursor, true) : null;
        ['base' => $base, 'token' => $token] = Umami::umamiSignIn($http, $credentials, $saved['token'] ?? null);
        $headers = ['authorization' => 'Bearer ' . Http::str($token)];
        if ($saved !== null && ($saved['website'] ?? null) === $website) {
            $state = $saved;
        } else {
            $info = $http->getJson("$base/api/websites/$website", ['headers' => $headers]);
            $created = Http::parseDate($info['createdAt'] ?? null);
            $created = Js::truthy($created) ? $created : $runlight->now();
            // Carry on where an earlier run stopped, and end where Runlight's own visits begin.
            // A saved place that does not read as a number is ignored, as if there were none.
            $stored = Js::number($runlight->store->setting(self::progressKey($siteId, $website)) ?? 0);
            $resumed = is_finite($stored) ? $stored : 0;
            // Never older than the site keeps, or the next scheduled check would delete it again.
            $cutoff = $runlight->retentionCutoff($siteId) ?? 0;
            $start = (int) max(floor($created / self::DAY) * self::DAY, $resumed, ceil($cutoff / self::DAY) * self::DAY);
            $own = $runlight->store->firstOwnVisit($siteId);
            $state = ['website' => $website, 'day' => $start, 'start' => $start, 'end' => (int) ($own ?? $runlight->now())];
        }
        $usesKey = Http::trim((string) ($credentials['apiKey'] ?? '')) !== '';

        // Read whole days until the step has enough.
        $events = [];
        $from = (int) $state['day'];
        $to = (int) $state['day'];
        $end = (int) $state['end'];
        while ($to < $end && $to - $from < self::STEP_DAYS * self::DAY && count($events) < self::STEP_EVENTS) {
            $next = min($to + self::DAY, $end);
            foreach (self::all($http, $base, "/websites/$website/events?startAt=$to&endAt=" . ($next - 1), $headers, self::MAX_DAY_EVENTS) as $e) {
                $events[] = $e;
            }
            $to = $next;
        }
        $sessions = $events !== [] ? self::all($http, $base, "/websites/$website/sessions?startAt=$from&endAt=" . ($to - 1), $headers, self::MAX_DAY_EVENTS * self::STEP_DAYS) : [];
        $info = [];
        foreach ($sessions as $s) {
            $info[Http::str($s['id'] ?? null)] = $s;
        }

        $ns = "umami-visits:$website";
        $visits = [];
        foreach ($events as $e) {
            $type = $e['eventType'] ?? null;
            if (!($type === self::PAGEVIEW || ($type === self::CUSTOM_EVENT && Js::truthy($e['eventName'] ?? null)))) {
                continue;
            }
            $ts = Http::parseDate($e['createdAt'] ?? null);
            if (!is_int($ts) && !is_finite($ts) || $ts >= $end) {
                continue;
            }
            $e['ts'] = (int) $ts;
            $visits[] = $e;
        }
        usort($visits, static fn (array $a, array $b): int => $a['ts'] <=> $b['ts']);
        $hits = array_map(static fn (array $e): array => ['ns' => $ns, 'hit' => self::fromUmami($e, $info[Http::str($e['sessionId'] ?? null)] ?? null)], $visits);
        $counts = self::writeStep($runlight, $siteId, $from, $to, $hits, static function (SqlStore $store) use ($siteId, $website, $to): void {
            $store->setSetting(self::progressKey($siteId, $website), (string) $to);
        });

        $totalDays = (int) max(1, ceil(($end - $state['start']) / self::DAY));
        $doneDays = (int) min($totalDays, ceil(($to - $state['start']) / self::DAY));
        $more = $to < $end;
        $next = [...$state, 'day' => $to];
        if (!$usesKey) {
            $next['token'] = $token;
        }
        return [
            'cursor' => $more ? Json::encode($next) : null,
            'done' => $doneDays,
            'total' => $totalDays,
            ...$counts,
        ];
    }

    /**
     * Writes one step of imported visits, sorted oldest first, all within [from, to). Whatever an earlier import
     * left in those times is cleared first, so a step can always run again, and a visit carried in from the step
     * before is counted again from its rows. `done` runs in the same transaction, to remember how far it got.
     *
     * @param list<array{ns: string, hit: array}> $hits
     * @param (callable(SqlStore): void)|null $done
     * @return array{pageviews: int, events: int, visits: int}
     */
    private static function writeStep(Runlight $runlight, string $siteId, int $from, int $to, array $hits, ?callable $done = null): array
    {
        $site = $runlight->site($siteId);
        if ($site === null) {
            throw new ImportError('Unknown site', 'unknown_site');
        }
        $counts = ['pageviews' => 0, 'events' => 0, 'visits' => 0];
        $runlight->store->transaction(static function (SqlStore $store) use ($siteId, $from, $to, $hits, $done, $site, &$counts): void {
            // Days this step writes into are added up again later, with the imported visits in them.
            $store->clearRollups($siteId, ['from' => $from, 'to' => $to]);
            // A failed earlier try at these days (on D1, which has no transactions) can
            // have left part of them behind. Clear it, so every step can safely run again.
            $imported = 'SELECT id FROM rl_sessions WHERE site = ? AND imported = 1';
            $store->db->run("DELETE FROM rl_events WHERE site = ? AND ts >= ? AND ts < ? AND kind IN ('pageview', 'event') AND session IN ($imported)", [$siteId, $from, $to, $siteId]);
            // Visits of these days that kept no rows go too. Their rows would come within EVENT_TAIL_MS of the step,
            // so the time bounds let the (site, ts) index find them, with no scan of every event.
            $store->db->run(
                'DELETE FROM rl_sessions WHERE site = ? AND imported = 1 AND started_at >= ? AND started_at < ?
         AND id NOT IN (SELECT e.session FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ?)',
                [$siteId, $from, $to, $siteId, $from, $to + SqlStore::EVENT_TAIL_MS],
            );
            foreach ($hits as ['ns' => $ns, 'hit' => $hit]) {
                if (self::writeEvent($store, $site, $ns, $hit)) {
                    $counts['visits']++;
                }
                if ($hit['kind'] === 'pageview') {
                    $counts['pageviews']++;
                } else {
                    $counts['events']++;
                }
            }
            // A visit that began in an earlier step and went on into this one is counted
            // again from its rows, so a repeated step cannot leave it with doubled totals.
            // The day it began may already be built, so that day is built again too.
            $carried = $store->db->all(
                'SELECT s.id AS id, s.started_at AS started_at FROM rl_sessions s
       WHERE s.site = ? AND s.imported = 1 AND s.started_at < ? AND s.started_at >= ?
         AND s.id IN (SELECT e.session FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ?)',
                [$siteId, $from, $from - SqlStore::EVENT_TAIL_MS, $siteId, $from, $to],
            );
            if ($carried !== []) {
                $earliest = (int) min(array_map(static fn (array $c): int|float => Js::number($c['started_at']), $carried));
                $store->clearRollups($siteId, ['from' => $earliest, 'to' => $from]);
                // Their rows lie between the earliest start and this step's end, which the (site, ts) index reads in one pass.
                // Ninety ids a statement, within Cloudflare D1's 100 values.
                $rows = [];
                foreach (array_chunk($carried, 90) as $chunk) {
                    $ids = array_map(static fn (array $c): string => (string) $c['id'], $chunk);
                    foreach ($store->db->all(
                        "SELECT e.session AS session, e.kind AS kind, e.ts AS ts, e.path AS path FROM rl_events e
             WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind IN ('pageview', 'event') AND e.session IN (" . implode(', ', array_fill(0, count($ids), '?')) . ')
             ORDER BY e.ts, e.id',
                        [$siteId, $earliest, $to, ...$ids],
                    ) as $row) {
                        $rows[] = $row;
                    }
                }
                $totals = [];
                foreach ($rows as $r) {
                    $session = (string) $r['session'];
                    $t = $totals[$session] ?? ['pageviews' => 0, 'events' => 0, 'last' => 0, 'exit' => null];
                    if ($r['kind'] === 'pageview') {
                        $t['pageviews']++;
                        $t['exit'] = (string) $r['path'];
                    } else {
                        $t['events']++;
                    }
                    $t['last'] = max($t['last'], Js::number($r['ts']));
                    $totals[$session] = $t;
                }
                foreach ($totals as $id => $t) {
                    $store->db->run('UPDATE rl_sessions SET pageviews = ?, events = ?, last_at = ?, exit_path = COALESCE(?, exit_path) WHERE id = ?', [$t['pageviews'], $t['events'], $t['last'], $t['exit'], (string) $id]);
                }
            }
            if ($done !== null) {
                $done($store);
            }
        });
        return $counts;
    }

    private static function referrerOf(mixed $domain, mixed $path, mixed $query): string
    {
        if (!Js::truthy($domain)) {
            return '';
        }
        $path = Js::truthy($path) ? Js::string($path) : '/';
        $query = Js::truthy($query) ? '?' . preg_replace('/^\?/', '', Js::string($query)) : '';
        return 'https://' . Js::string($domain) . $path . $query;
    }

    private static function fromUmami(array $e, ?array $session): array
    {
        $text = static fn (mixed $value): string => $value === null ? '' : Js::string($value);
        $region = Js::truthy($session['subdivision1'] ?? null) ? $session['subdivision1'] : (Js::truthy($session['region'] ?? null) ? $session['region'] : '');
        return [
            'ts' => $e['ts'],
            'key' => Http::str($e['sessionId'] ?? null),
            'kind' => $e['eventType'] === self::PAGEVIEW ? 'pageview' : 'event',
            'hostname' => $text($e['hostname'] ?? null),
            'path' => $text($e['urlPath'] ?? null),
            'query' => $text($e['urlQuery'] ?? null),
            'referrer' => self::referrerOf($e['referrerDomain'] ?? null, $e['referrerPath'] ?? null, $e['referrerQuery'] ?? null),
            'title' => $text($e['pageTitle'] ?? null),
            'name' => $text($e['eventName'] ?? null),
            'country' => $text($e['country'] ?? null),
            'region' => Js::string($region),
            'city' => $text($e['city'] ?? null),
            'browser' => $text($e['browser'] ?? null),
            'os' => $text($e['os'] ?? null),
            'device' => $text($e['device'] ?? null),
            'screen' => $text($session['screen'] ?? null),
            'language' => $text($session['language'] ?? null),
        ];
    }

    /**
     * Writes one imported pageview or event as part of a Runlight visit. Visitors
     * are hashed per day from the hit's key, as live visitors are hashed per day,
     * and a hit within thirty minutes of the visitor's last one joins that visit.
     * Ids come from `ns` and the key, so importing the same rows again makes the
     * same ids. Returns whether it started a new visit.
     */
    private static function writeEvent(SqlStore $store, array $site, string $ns, array $e): bool
    {
        // The site's own day, as live visitors are counted, so days add up the same way in rollups.
        $day = Time::localDate($e['ts'], $site['timezone']);
        $visitor = Write::hexId("$ns:{$e['key']}:$day", 16);
        // A visit that runs past midnight keeps the id it started with, as a live one does.
        $yesterday = Write::hexId("$ns:{$e['key']}:" . Time::addDays($day, -1), 16);
        $host = Js::lower($e['hostname'] !== '' ? $e['hostname'] : ($site['hostnames'][0] ?? 'imported.invalid'));
        $url = Url::parse("https://$host" . ($e['path'] !== '' ? $e['path'] : '/') . ($e['query'] !== '' ? '?' . preg_replace('/^\?/', '', $e['query']) : ''))
            ?? new Url("https://$host/");
        $page = Sources::parsePage($url);
        $open = $store->openSession($site['id'], [$visitor, $yesterday], $e['ts'] - Runlight::SESSION_IDLE_MS);
        $id = $open['id'] ?? null;
        if ($id === null) {
            $id = Write::hexId("$ns:{$e['key']}:{$e['ts']}");
            $store->db->run('DELETE FROM rl_sessions WHERE id = ?', [$id]);
            $country = Js::slice(Js::upper($e['country']), 0, 2);
            $rawRegion = $e['region'];
            $region = $rawRegion !== '' ? Js::slice(Js::upper(str_contains($rawRegion, '-') ? $rawRegion : "$country-$rawRegion"), 0, 10) : '';
            $known = (bool) preg_match('/^[A-Z]{2}$/D', $country);
            $store->insertSession([
                'id' => $id,
                'site' => $site['id'],
                'visitor' => $visitor,
                'startedAt' => $e['ts'],
                'hostname' => $page['hostname'],
                ...Sources::attribute($page, $e['referrer'], $site['hostnames']),
                'utmSource' => $page['utm']['source'],
                'utmMedium' => $page['utm']['medium'],
                'utmCampaign' => $page['utm']['campaign'],
                'utmTerm' => $page['utm']['term'],
                'utmContent' => $page['utm']['content'],
                'country' => $known ? $country : '',
                'region' => $known ? $region : '',
                'city' => Js::slice($e['city'], 0, 100),
                'browser' => Write::browser($e['browser']),
                'browserVersion' => '',
                'os' => Write::system($e['os']),
                'osVersion' => '',
                'device' => Write::device($e['device']),
                'screen' => Js::slice($e['screen'], 0, 20),
                'language' => Js::slice($e['language'], 0, 35),
            ]);
            // No engaged time is known, so duration falls back to first-to-last pageview.
            $store->db->run('UPDATE rl_sessions SET imported = 1, engaged_ms = NULL WHERE id = ?', [$id]);
        }
        $kind = $e['kind'];
        $store->touchSession($id, $e['ts'], $kind, $page['path']);
        $store->insertEvent([
            'site' => $site['id'],
            'ts' => $e['ts'],
            'kind' => $kind,
            // The visit's own visitor, which for one running past midnight is the id of the day it started.
            'visitor' => $open['visitor'] ?? $visitor,
            'session' => $id,
            'pageview' => '',
            'path' => $page['path'],
            'hostname' => $page['hostname'],
            'title' => $kind === 'pageview' ? Js::slice($e['title'], 0, 300) : '',
            'name' => $kind === 'event' ? Js::slice($e['name'], 0, 120) : '',
            'props' => null,
            'engagedMs' => 0,
            'scroll' => null,
            'link' => '',
        ]);
        return $open === null;
    }

    /**
     * One batch of a CSV file, sorted oldest first by the dashboard. As with Umami, only rows from before
     * Runlight's own first visit, and within what the site keeps, are written. A batch can run again: its
     * time span is cleared first, so batches must not share a moment, which the dashboard sees to.
     *
     * @return array{pageviews: int, events: int, visits: int, skipped: int}
     */
    public static function importCsvVisits(Runlight $runlight, string $siteId, mixed $rows): array
    {
        $runlight->init();
        if ($runlight->site($siteId) === null) {
            throw new ImportError('Unknown site', 'unknown_site');
        }
        if (!is_array($rows) || !array_is_list($rows) || count($rows) > CsvVisits::CSV_BATCH) {
            throw new ImportError('Send at most ' . CsvVisits::CSV_BATCH . ' rows at a time', 'import_csv_batch', ['max' => (string) CsvVisits::CSV_BATCH]);
        }
        $clean = [];
        foreach ($rows as $r) {
            $r = $r instanceof \stdClass ? (array) $r : $r;
            $row = [];
            foreach (is_array($r) ? $r : [] as $k => $v) {
                $row[Js::lower(Js::trim((string) $k))] = $v === null ? '' : Js::string($v);
            }
            $clean[] = $row;
        }
        $format = CsvVisits::csvFormat(array_map('strval', array_keys($clean[0] ?? [])));
        if ($format === null) {
            throw new ImportError("This CSV is not an Umami export or Runlight's visit format", 'import_csv_format');
        }
        $cutoff = $runlight->retentionCutoff($siteId) ?? 0;
        $end = min($runlight->store->firstOwnVisit($siteId) ?? INF, $runlight->now());
        $hits = [];
        foreach ($clean as $row) {
            $h = CsvVisits::csvHit($row, $format);
            if ($h !== null && $h['hit']['ts'] >= $cutoff && $h['hit']['ts'] < $end) {
                $h['hit']['ts'] = (int) $h['hit']['ts'];
                $hits[] = $h;
            }
        }
        usort($hits, static fn (array $a, array $b): int => $a['hit']['ts'] <=> $b['hit']['ts']);
        $skipped = count($clean) - count($hits);
        if ($hits === []) {
            return ['pageviews' => 0, 'events' => 0, 'visits' => 0, 'skipped' => $skipped];
        }
        $counts = self::writeStep($runlight, $siteId, $hits[0]['hit']['ts'], $hits[count($hits) - 1]['hit']['ts'] + 1, $hits);
        return [...$counts, 'skipped' => $skipped];
    }
}
