<?php

declare(strict_types=1);

namespace Runlight\Store;

use Runlight\Db\Db;
use Runlight\Js;
use Runlight\Json;
use Runlight\Query;

/**
 * Runlight's tables, read and written with the same SQL as store.ts's SqlStore for each dialect, so a
 * database made by either implementation opens in the other. Rows are the TypeScript interfaces as
 * associative arrays with the same camelCase keys:
 *
 * - SiteRow: array{id: string, name: string, hostnames: list<string>, timezone: string}
 * - GoalRow: array{id, site, name, kind: 'event'|'page'|'click', match, clickBy: 'selector'|'link'|'', valueMode:
 *   'none'|'fixed'|'prop', value: int|float, valueProp, currency, createdAt: int}
 * - ReportRow: array{id, site, email, frequency: 'weekly'|'monthly', lang, token, origin, lastPeriod, lastSentAt: ?int, createdAt: int}
 * - ShareRow: array{id, site, name, createdAt: int}
 * - FunnelRow: array{id, site, name, steps: list<array{kind: 'page'|'event', match: string}>, createdAt: int}
 * - TokenRow: array{id, name, site, scope: 'read'|'manage', hash, hint, createdAt: int, lastUsedAt: ?int}
 * - LinkRow: array{id, site, domain, slug, name, url, createdAt: int, updatedAt: int}
 * - SessionRow: array{id, site, visitor, startedAt: int, hostname, referrerHost, referrerPath, source, channel, utmSource,
 *   utmMedium, utmCampaign, utmTerm, utmContent, country, region, city, browser, browserVersion, os, osVersion, device, screen, language}
 * - EventRow: array{site, ts: int, kind: 'pageview'|'event'|'engagement'|'click'|'fetch', visitor, session, pageview, path,
 *   hostname, title, name, props: array<string, string>|\stdClass|null, engagedMs: int, scroll: ?int, link}
 * - Query: array{site: string, from: int, to: int, filters: list<array{dimension: string, op: string, value: string}>}
 * - Bucket: array{start: int, end: int}
 *
 * Numbers come back as int when whole and float otherwise, as JavaScript's one number type writes them.
 */
final class SqlStore
{
    public const BOUNCE_MS = Sql::BOUNCE_MS;
    public const JOURNEY_VISITS = Sql::JOURNEY_VISITS;
    public const EVENT_TAIL_MS = Sql::EVENT_TAIL_MS;
    public const MYSQL_COLLATION = Sql::MYSQL_COLLATION;

    private bool $ready = false;
    private bool $checkedAll = false;

    public function __construct(public readonly Db $db)
    {
    }

    /**
     * Creates the tables on first use. Safe to call any number of times.
     *
     * A PHP process serves one request, so going over every table and index each time would cost every
     * tracker hit a few milliseconds on MySQL and Postgres. When the database already records the current
     * schema version, that is taken as done; `$full` goes over everything anyway, as the scheduled check
     * and `runlight migrate` do, which adds an index a database of this version may still lack.
     */
    public function migrate(bool $full = false): void
    {
        if ($this->checkedAll || ($this->ready && !$full)) {
            return;
        }
        if (!$full && !$this->ready) {
            try {
                $found = $this->db->all('SELECT value FROM rl_meta WHERE "key" = \'schema\'')[0]['value'] ?? null;
                if ($found !== null && (string) $found === (string) Sql::SCHEMA_VERSION) {
                    $this->ready = true;
                    return;
                }
            } catch (\Throwable) {
                // No rl_meta yet: a new database, made below.
            }
        }
        $create = function (Db $db): void {
            // On Postgres an index on a big table takes a while to build, so the build may run past the
            // statement timeout, and goes CONCURRENTLY, so another process still serving keeps writing meanwhile.
            $postgres = $db->dialect() === 'postgres';
            if ($postgres) {
                $db->run('SET statement_timeout = 0');
            }
            try {
                $this->upgrade($db, $postgres);
            } finally {
                if ($postgres) {
                    try {
                        $db->run('RESET statement_timeout');
                    } catch (\Throwable) {
                    }
                }
            }
        };
        $this->db->exclusive($create);
        $this->ready = true;
        $this->checkedAll = true;
    }

    private function upgrade(Db $db, bool $postgres): void
    {
        $statements = Sql::schema($db->dialect());
        $db->run($statements[0]);
        $found = $db->all('SELECT value FROM rl_meta WHERE "key" = \'schema\'')[0] ?? null;
        $from = $found !== null ? Js::number($found['value']) : Sql::SCHEMA_VERSION;
        if ($postgres) {
            // A concurrent build that was stopped leaves its index unusable; it goes, and is built again below.
            $broken = $db->all(
                "SELECT c.relname AS name FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
           WHERE NOT i.indisvalid AND c.relname LIKE 'rl\\_%' AND c.relnamespace = current_schema()::regnamespace",
            );
            foreach ($broken as $row) {
                $db->run('DROP INDEX IF EXISTS "' . str_replace('"', '', (string) $row['name']) . '"');
            }
        }
        foreach ($statements as $statement) {
            if ($db->dialect() === 'mysql' && preg_match('/^CREATE (UNIQUE )?INDEX IF NOT EXISTS (\w+) ON (\w+)/', $statement, $index)) {
                // MySQL has no CREATE INDEX IF NOT EXISTS, so it is looked for first.
                [, $unique, $name, $table] = $index;
                $there = $db->all('SELECT 1 AS there FROM information_schema.statistics WHERE table_schema = DATABASE() AND table_name = ? AND index_name = ? LIMIT 1', [$table, $name]);
                if (!$there) {
                    $db->run((string) preg_replace('/^CREATE (UNIQUE )?INDEX IF NOT EXISTS/', "CREATE {$unique}INDEX", $statement));
                }
            } else {
                $db->run($postgres ? (string) preg_replace('/^CREATE (UNIQUE )?INDEX IF NOT EXISTS/', 'CREATE $1INDEX CONCURRENTLY IF NOT EXISTS', $statement) : $statement);
            }
        }
        // A column added by an upgrade that stopped before it recorded the new version is already there.
        $addColumn = function (string $sql) use ($db): void {
            try {
                $db->run($sql);
            } catch (\Throwable $error) {
                if (!preg_match('/duplicate column|already exists/i', (string) $error)) {
                    throw $error;
                }
            }
        };
        // Version 2: settings changed in the dashboard, kept apart from the ones in code.
        if ($from < 2) {
            $addColumn("ALTER TABLE rl_sites ADD COLUMN overrides TEXT NOT NULL DEFAULT '{}'");
        }
        if ($from < 4) {
            $db->run('DROP INDEX IF EXISTS rl_links_slug');
        }
        // Version 10: tokens that may change one site's settings, for a hub.
        if ($from >= 8 && $from < 10) {
            $addColumn("ALTER TABLE rl_tokens ADD COLUMN scope TEXT NOT NULL DEFAULT 'read'");
        }
        // Written only when it changes, so a database opened read-only can still be read.
        if ($found === null || (string) $found['value'] !== (string) Sql::SCHEMA_VERSION) {
            $db->run(Sql::upsert($db->dialect(), 'rl_meta', ['"key"', 'value'], ['"key"'], ['value']), ['schema', (string) Sql::SCHEMA_VERSION]);
        }
    }

    /**
     * Keeps SQLite's planner statistics current, which it never gathers by itself. Without them it can
     * choose a plan that reads a table once for every row of another. A sample of each index is enough,
     * so this takes milliseconds even on a large database. Postgres gathers its own.
     */
    public function optimize(bool $onlyWhenMissing = false): void
    {
        if ($this->db->dialect() !== 'sqlite') {
            return;
        }
        try {
            if ($onlyWhenMissing && $this->db->all("SELECT name FROM sqlite_master WHERE name = 'sqlite_stat1'")) {
                return;
            }
            $this->db->run('PRAGMA analysis_limit = 1000');
            $this->db->run('ANALYZE');
        } catch (\Throwable) {
            // Some hosted SQLite services refuse these, and gather statistics themselves.
        }
    }

    public function close(): void
    {
        $this->db->close();
    }

    /** True for a database reached one statement at a time with a cap on statements per request (Cloudflare D1). */
    private function metered(): bool
    {
        return method_exists($this->db, 'metered') && $this->db->metered();
    }

    /** How many rows an UPDATE or DELETE of rows with an id matched. MySQL has no RETURNING, so its driver counts them. */
    private function changed(string $sql, array $params): int
    {
        if ($this->db->dialect() === 'mysql' && method_exists($this->db, 'affected')) {
            return $this->db->affected($sql, $params);
        }
        return count($this->db->all("$sql RETURNING id", $params));
    }

    /**
     * Runs `fn` with a store whose every query is in one transaction.
     *
     * @template T
     * @param callable(SqlStore): T $fn
     * @return T
     */
    public function transaction(callable $fn): mixed
    {
        return $this->db->transaction(static fn (Db $db) => $fn(new SqlStore($db)));
    }

    // Sites

    /** @param array{id: string, name: string, hostnames: list<string>, timezone: string} $site */
    public function upsertSite(array $site, int $now): void
    {
        // Unchanged sites are left alone, so starting needs no write and a read-only database still opens.
        $hostnames = Json::encode(array_values($site['hostnames']));
        $row = $this->db->all('SELECT name, hostnames, timezone FROM rl_sites WHERE id = ?', [$site['id']])[0] ?? null;
        if ($row !== null && $row['name'] === $site['name'] && $row['hostnames'] === $hostnames && $row['timezone'] === $site['timezone']) {
            return;
        }
        $this->db->run(
            Sql::upsert($this->db->dialect(), 'rl_sites', ['id', 'name', 'hostnames', 'timezone', 'created_at'], ['id'], ['name', 'hostnames', 'timezone']),
            [$site['id'], $site['name'], $hostnames, $site['timezone'], $now],
        );
    }

    /**
     * Settings changed in the dashboard, by site. They win over the ones in code.
     *
     * @return array<string, array{name?: string, timezone?: string}>
     */
    public function siteOverrides(): array
    {
        $out = [];
        foreach ($this->db->all('SELECT id, overrides FROM rl_sites') as $row) {
            $value = Json::tryDecode((string) $row['overrides'], true);
            $out[(string) $row['id']] = is_array($value) ? $value : [];
        }
        return $out;
    }

    /**
     * Deletes a site and everything recorded for it. Used by the standalone server's "Delete site". Its
     * events and visits go a day at a time first, so a big site does not hold the database for minutes,
     * and what is left goes in one transaction.
     */
    public function deleteSite(string $id): void
    {
        $piece = $this->metered() ? 30 * Sql::PIECE_MS : Sql::PIECE_MS;
        foreach ([['rl_events', 'ts'], ['rl_sessions', 'started_at']] as [$table, $col]) {
            // A piece at a time from the oldest row, skipping straight over stretches with none.
            for ($from = $this->oldest($table, $col, $id, null); $from !== null; $from = $this->oldest($table, $col, $id, $from + $piece)) {
                $this->db->run("DELETE FROM $table WHERE site = ? AND $col < ?", [$id, $from + $piece]);
            }
        }
        $this->transaction(function (SqlStore $store) use ($id): void {
            foreach (['rl_events', 'rl_sessions', 'rl_links', 'rl_link_domains', 'rl_shares', 'rl_goals', 'rl_funnels', 'rl_reports', 'rl_tokens', 'rl_rollups', 'rl_rollup_days', 'rl_sites'] as $table) {
                $store->db->run("DELETE FROM $table WHERE " . ($table === 'rl_sites' ? 'id' : 'site') . ' = ?', [$id]);
            }
        });
    }

    /** When a site's oldest row at or after `from` is (null for no lower bound), or null when there is none. */
    private function oldest(string $table, string $col, string $site, int|float|null $from): int|float|null
    {
        $row = $this->db->all("SELECT MIN($col) AS t FROM $table WHERE site = ?" . ($from === null ? '' : " AND $col >= ?"), $from === null ? [$site] : [$site, $from])[0] ?? null;
        return $row === null || $row['t'] === null ? null : Sql::num($row['t']);
    }

    /** Deletes a site's visits and events from before a time, for its retention setting. */
    public function dropBefore(string $site, int $ts): void
    {
        // A day at a time from the oldest, each its own short transaction, so a long history goes without
        // holding the database for minutes. Stretches with nothing in them are skipped, so one stray old row
        // does not cost a piece for every day since.
        $piece = $this->metered() ? 30 * Sql::PIECE_MS : Sql::PIECE_MS;
        $next = function (int|float|null $at) use ($site): int|float|null {
            $found = array_values(array_filter([$this->oldest('rl_sessions', 'started_at', $site, $at), $this->oldest('rl_events', 'ts', $site, $at)], static fn ($t) => $t !== null));
            if (!$found) {
                return null;
            }
            return $at === null ? min($found) : max($at, min($found));
        };
        for ($from = $next(null); $from !== null && $from < $ts; $from = $next(min($from + $piece, $ts))) {
            $to = min($from + $piece, $ts);
            $this->transaction(function (SqlStore $store) use ($site, $from, $to): void {
                // A visit's events go with it, even ones after the cutoff, so nothing is left without its visit.
                // They come after it starts and within EVENT_TAIL_MS, so the time bounds let the (site, ts) index find them.
                $store->db->run(
                    'DELETE FROM rl_events WHERE site = ? AND ts >= ? AND ts < ? AND session IN (SELECT id FROM rl_sessions WHERE site = ? AND started_at >= ? AND started_at < ?)',
                    [$site, $from, $to + Sql::EVENT_TAIL_MS, $site, $from, $to],
                );
                $store->db->run('DELETE FROM rl_events WHERE site = ? AND ts < ?', [$site, $to]);
                $store->db->run('DELETE FROM rl_sessions WHERE site = ? AND started_at < ?', [$site, $to]);
            });
        }
        // A day that lost any of its visits is built again later, from what is left.
        $this->clearRollups($site, ['before' => $ts]);
    }

    /** Deletes a site's events from `from` on whose visit no longer exists, a day at a time. */
    public function dropOrphans(string $site, int $from, int $until): void
    {
        $piece = $this->metered() ? 30 * Sql::PIECE_MS : Sql::PIECE_MS;
        for ($at = $this->oldest('rl_events', 'ts', $site, $from); $at !== null && $at < $until; $at = $this->oldest('rl_events', 'ts', $site, $at + $piece)) {
            $this->db->run(
                "DELETE FROM rl_events WHERE site = ? AND ts >= ? AND ts < ? AND session <> '' AND NOT EXISTS (SELECT 1 FROM rl_sessions s WHERE s.id = rl_events.session)",
                [$site, $at, $at + $piece],
            );
        }
    }

    // Daily rollups

    /**
     * Adds up one local day of a site: totals, each visit dimension, and pages.
     * A visit belongs to the day it started. Visitor ids change every day, so
     * the days of a range add up to exactly what counting the range would give.
     */
    public function buildRollupDay(string $site, string $day, int $start, int $end): void
    {
        // A day with no visits still gets its row of zeros, so it counts as built.
        $bounce = Sql::BOUNCE;
        $sums = "COUNT(DISTINCT s.visitor), COUNT(*), COALESCE(SUM(s.pageviews), 0), COALESCE(SUM(CASE WHEN $bounce THEN 1 ELSE 0 END), 0), COALESCE(SUM(" . Sql::DURATION . '), 0)';
        $cols = '(site, day, dim, value, visitors, visits, pageviews, bounced, duration)';
        // Each piece names its own site and day, as text, so Postgres knows their type inside a UNION.
        $dialect = $this->db->dialect();
        $head = Sql::asText($dialect, '?') . ', ' . Sql::asText($dialect, '?');
        $quarter = Sql::div($dialect, 's.started_at', 900000);
        // The day's totals, each visit dimension, and the heatmap's quarter hours (counted as hourly() counts
        // them: every visit that started), in one statement over the day's visits, since a Cloudflare D1
        // check may only send so many.
        $pieces = ["SELECT $head, '', '', $sums FROM v s"];
        foreach (Query::SESSION_DIMENSIONS as $dim => $col) {
            $pieces[] = "SELECT $head, '$dim', s.$col, $sums FROM v s WHERE s.$col <> '' GROUP BY s.$col";
        }
        $pieces[] = "SELECT $head, 'quarter', " . Sql::asText($dialect, $quarter) . ", COUNT(DISTINCT s.visitor), COUNT(*), COALESCE(SUM(s.pageviews), 0), COALESCE(SUM(CASE WHEN $bounce THEN 1 ELSE 0 END), 0), 0 FROM v s GROUP BY " . Sql::asText($dialect, $quarter);
        // Pages and events, from the rows of the day's visits. The time bounds let the (site, kind, ts) index
        // find them; a visit's last row comes at most EVENT_TAIL_MS after it starts.
        $ofDay = static fn (string $kind): string => "FROM rl_events e JOIN rl_sessions s ON s.id = e.session
       WHERE e.site = ? AND e.kind = '$kind' AND e.ts >= ? AND e.ts < ? AND s.started_at >= ? AND s.started_at < ? AND " . Sql::IS_VISIT;
        $window = [$site, $start, $end + Sql::EVENT_TAIL_MS, $start, $end];
        $isVisit = Sql::IS_VISIT;
        $liveViews = Sql::LIVE_VIEWS;
        $this->transaction(function (SqlStore $store) use ($site, $day, $start, $end, $cols, $pieces, $ofDay, $window, $isVisit, $liveViews): void {
            $db = $store->db;
            $db->run('DELETE FROM rl_rollups WHERE site = ? AND day = ?', [$site, $day]);
            // The WITH goes after INSERT INTO, the one place every database takes it.
            $params = [$site, $start, $end];
            foreach ($pieces as $_) {
                array_push($params, $site, $day);
            }
            $db->run(
                "INSERT INTO rl_rollups $cols
         WITH v AS (SELECT * FROM rl_sessions s WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND $isVisit)
         " . implode(' UNION ALL ', $pieces),
                $params,
            );
            // A page's engaged time and scroll come per pageview first (its time added up, its deepest scroll),
            // as the raw report counts them.
            $db->run(
                "INSERT INTO rl_rollups (site, day, dim, value, visitors, visits, pageviews, views, engaged, scroll_sum, scroll_n)
         SELECT ?, ?, 'page', p.value, p.visitors, p.visits, p.pageviews, p.views, COALESCE(t.engaged, 0), COALESCE(t.scroll_sum, 0), COALESCE(t.scroll_n, 0)
         FROM (SELECT e.path AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(DISTINCT e.session) AS visits, COUNT(*) AS pageviews, $liveViews AS views
               {$ofDay('pageview')} GROUP BY e.path) p
         LEFT JOIN (SELECT value, SUM(total) AS engaged, SUM(deepest) AS scroll_sum, COUNT(deepest) AS scroll_n FROM (
               SELECT e.path AS value, SUM(e.engaged_ms) AS total, MAX(e.scroll) AS deepest {$ofDay('engagement')} GROUP BY e.path, e.pageview) x
               GROUP BY value) t ON t.value = p.value",
                [$site, $day, ...$window, ...$window],
            );
            $db->run(
                "INSERT INTO rl_rollups (site, day, dim, value, visitors, events)
         SELECT ?, ?, 'event', e.name, COUNT(DISTINCT e.visitor), COUNT(*) {$ofDay('event')} GROUP BY e.name",
                [$site, $day, ...$window],
            );
            $db->run('DELETE FROM rl_rollup_days WHERE site = ? AND day = ?', [$site, $day]);
            $db->run('INSERT INTO rl_rollup_days (site, day, start_at, end_at) VALUES (?, ?, ?, ?)', [$site, $day, $start, $end]);
        });
    }

    /**
     * The days of a site already built.
     *
     * @return list<string>
     */
    public function rollupDays(string $site): array
    {
        $days = [];
        foreach ($this->db->all('SELECT day FROM rl_rollup_days WHERE site = ?', [$site]) as $r) {
            $days[(string) $r['day']] = true;
        }
        return array_map('strval', array_keys($days));
    }

    /**
     * Forgets built days, all of a site's or those touching a stretch of time, so they are built again.
     *
     * @param array{before?: int, from?: int, to?: int} $range
     */
    public function clearRollups(string $site, array $range = []): void
    {
        $where = 'site = ?';
        $params = [$site];
        if (isset($range['before'])) {
            $where .= ' AND start_at < ?';
            $params[] = $range['before'];
        } elseif (isset($range['from'], $range['to'])) {
            $where .= ' AND start_at < ? AND end_at > ?';
            array_push($params, $range['to'], $range['from']);
        }
        $days = array_map(static fn (array $r): string => (string) $r['day'], $this->db->all("SELECT day FROM rl_rollup_days WHERE $where", $params));
        // The days stop counting as built first, so if this stops part way, no day is left marked built
        // without its rows. Rows of a day not built are never read, and building it replaces them. Another
        // process may build a day between the two deletes, so its mark goes again after its rows: the day
        // is then simply built once more.
        $this->db->run("DELETE FROM rl_rollup_days WHERE $where", $params);
        foreach ($days as $day) {
            $this->db->run('DELETE FROM rl_rollups WHERE site = ? AND day = ?', [$site, $day]);
            $this->db->run('DELETE FROM rl_rollup_days WHERE site = ? AND day = ?', [$site, $day]);
        }
    }

    /**
     * How to answer a range from rollups: the built days that lie wholly inside
     * it, and the stretches left over, which are read from the visits as usual.
     * Null when no built day helps.
     *
     * @return array{days: list<array{day: string, start: int|float, end: int|float}>, rest: list<array{0: int|float, 1: int|float}>}|null
     */
    private function rollupPlan(array $query, int $from, int $to): ?array
    {
        if ($query['filters']) {
            return null;
        }
        $rows = $this->db->all('SELECT day, start_at, end_at FROM rl_rollup_days WHERE site = ? AND start_at >= ? AND end_at <= ? ORDER BY start_at', [$query['site'], $from, $to]);
        if (!$rows) {
            return null;
        }
        $days = array_map(static fn (array $r): array => ['day' => (string) $r['day'], 'start' => Sql::num($r['start_at']), 'end' => Sql::num($r['end_at'])], $rows);
        $rest = [];
        $at = $from;
        foreach ($days as $d) {
            if ($d['start'] > $at) {
                $rest[] = [$at, $d['start']];
            }
            $at = max($at, $d['end']);
        }
        if ($at < $to) {
            $rest[] = [$at, $to];
        }
        return ['days' => $days, 'rest' => $rest];
    }

    /**
     * SQL for "a visit that started in one of these stretches".
     *
     * @param list<array{0: int|float, 1: int|float}> $rest
     * @return array{sql: string, params: list<int|float>}
     */
    private static function within(array $rest): array
    {
        if (!$rest) {
            return ['sql' => '1 = 0', 'params' => []];
        }
        return [
            'sql' => '(' . implode(' OR ', array_fill(0, count($rest), '(s.started_at >= ? AND s.started_at < ?)')) . ')',
            'params' => array_merge(...array_map(static fn (array $r): array => [$r[0], $r[1]], $rest)),
        ];
    }

    /**
     * A breakdown of a visit dimension or of pages from rollups and the visits
     * left over, merged, then sorted and cut to the page asked for.
     */
    private function rolledBreakdown(array $query, string $dimension, int $limit, int $offset): ?array
    {
        $page = $dimension === 'page';
        $event = $dimension === 'event';
        if (!$page && !$event && !Query::isSessionDimension($dimension)) {
            return null;
        }
        if ($query['filters']) {
            return null;
        }
        // Pages and events always go this way without filters, so a range gives the same answer whether its days are built or not.
        $plan = $this->rollupPlan($query, $query['from'], $query['to']) ?? ($page || $event ? ['days' => [], 'rest' => [[$query['from'], $query['to']]]] : null);
        if ($plan === null) {
            return null;
        }
        $zero = ['visitors' => 0, 'visits' => 0, 'pageviews' => 0, 'bounced' => 0, 'duration' => 0, 'engaged' => 0, 'views' => 0, 'scroll_sum' => 0, 'scroll_n' => 0, 'events' => 0];
        // Keyed by value in the order first seen. PHP would turn a key like "12" into a number, so each
        // value is kept beside its sums rather than as the key.
        /** @var array<string, array{0: string, 1: array<string, int|float>}> $sums */
        $sums = [];
        $bump = function (array $row) use (&$sums, $zero): void {
            $key = (string) $row['value'];
            $into = $sums["v$key"][1] ?? $zero;
            foreach ($into as $k => $n) {
                $into[$k] = $n + Sql::num($row[$k] ?? null);
            }
            $sums["v$key"] = [$key, $into];
        };
        if ($plan['days']) {
            $rolled = $this->db->all(
                'SELECT value, SUM(visitors) AS visitors, SUM(visits) AS visits, SUM(pageviews) AS pageviews, SUM(bounced) AS bounced, SUM(duration) AS duration,
           SUM(engaged) AS engaged, SUM(views) AS views, SUM(scroll_sum) AS scroll_sum, SUM(scroll_n) AS scroll_n, SUM(events) AS events
         FROM rl_rollups WHERE site = ? AND dim = ? AND day IN (' . Sql::BUILT_DAYS . ') GROUP BY value',
                [$query['site'], $dimension, $query['site'], $query['from'], $query['to']],
            );
            foreach ($rolled as $row) {
                $bump($row);
            }
        }
        $w = self::within($plan['rest']);
        $isVisit = Sql::IS_VISIT;
        if (($page || $event) && $plan['rest']) {
            // A visit's pageviews and events belong to the day it started, as in the rollups.
            // Bounded by time as well, so the events index finds them (see buildRollupDay).
            $lo = min(array_map(static fn (array $r) => $r[0], $plan['rest']));
            $hi = max(array_map(static fn (array $r) => $r[1], $plan['rest'])) + Sql::EVENT_TAIL_MS;
            $ofRest = static fn (string $kind): string => "FROM rl_events e JOIN rl_sessions s ON s.id = e.session WHERE e.site = ? AND e.kind = '$kind' AND e.ts >= ? AND e.ts < ? AND $isVisit AND {$w['sql']}";
            $at = [$query['site'], $lo, $hi, ...$w['params']];
            if ($page) {
                foreach ($this->db->all('SELECT e.path AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(DISTINCT e.session) AS visits, COUNT(*) AS pageviews, ' . Sql::LIVE_VIEWS . " AS views {$ofRest('pageview')} GROUP BY e.path", $at) as $row) {
                    $bump($row);
                }
                foreach ($this->db->all(
                    "SELECT value, SUM(total) AS engaged, SUM(deepest) AS scroll_sum, COUNT(deepest) AS scroll_n FROM (
             SELECT e.path AS value, SUM(e.engaged_ms) AS total, MAX(e.scroll) AS deepest {$ofRest('engagement')} GROUP BY e.path, e.pageview) t GROUP BY value",
                    $at,
                ) as $row) {
                    $bump($row);
                }
            } else {
                foreach ($this->db->all("SELECT e.name AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(*) AS events {$ofRest('event')} GROUP BY e.name", $at) as $row) {
                    $bump($row);
                }
            }
        } elseif ($page || $event) {
            // Every day of the range is built.
        } else {
            $col = 's.' . Query::SESSION_DIMENSIONS[$dimension];
            foreach ($this->db->all(
                "SELECT $col AS value, COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits, SUM(s.pageviews) AS pageviews,
           SUM(CASE WHEN " . Sql::BOUNCE . ' THEN 1 ELSE 0 END) AS bounced, SUM(' . Sql::DURATION . ") AS duration
         FROM rl_sessions s WHERE s.site = ? AND $isVisit AND {$w['sql']} AND $col <> '' GROUP BY $col",
                [$query['site'], ...$w['params']],
            ) as $row) {
                $bump($row);
            }
        }
        $entryExit = $dimension === 'entry' || $dimension === 'exit';
        $rows = array_values(array_filter($sums, static fn (array $e): bool => ($event || $e[0] !== '') && ($page ? $e[1]['pageviews'] > 0 : ($event ? $e[1]['events'] > 0 : $e[1]['visits'] > 0))));
        usort($rows, static function (array $p, array $q) use ($entryExit, $event, $page): int {
            [$a, $x] = $p;
            [$b, $y] = $q;
            $order = $entryExit ? [$y['visits'] - $x['visits']]
                : ($event ? [$y['visitors'] - $x['visitors'], $y['events'] - $x['events']]
                : ($page ? [$y['visitors'] - $x['visitors'], $y['pageviews'] - $x['pageviews']]
                : [$y['visitors'] - $x['visitors'], $y['visits'] - $x['visits']]));
            foreach ($order as $d) {
                if ($d != 0) {
                    return $d < 0 ? -1 : 1;
                }
            }
            return Sql::codeOrder($a, $b);
        });
        $out = [];
        foreach (array_slice($rows, $offset, $limit) as [$value, $x]) {
            if ($event) {
                $out[] = ['value' => $value, 'visitors' => $x['visitors'], 'events' => $x['events']];
                continue;
            }
            if ($page) {
                $out[] = [
                    'value' => $value,
                    'visitors' => $x['visitors'],
                    'pageviews' => $x['pageviews'],
                    // Over every pageview that could report its time, counting those that sent none (under a second) as none.
                    'timeOnPage' => $x['views'] > 0 ? self::whole(Js::round($x['engaged'] / $x['views'])) : 0,
                    'scrollDepth' => $x['scroll_n'] > 0 ? self::whole(Js::round($x['scroll_sum'] / $x['scroll_n'])) : 0,
                ];
                continue;
            }
            $row = ['value' => $value, 'visitors' => $x['visitors'], 'visits' => $x['visits'], 'bounceRate' => $x['visits'] > 0 ? $x['bounced'] / $x['visits'] : 0];
            if (!$entryExit) {
                $row['pageviews'] = $x['pageviews'];
                $row['visitDuration'] = $x['visits'] > 0 ? self::whole(Js::round($x['duration'] / $x['visits'])) : 0;
            }
            $out[] = $row;
        }
        return $out;
    }

    /** @return array{visitors: int|float, visits: int|float, pageviews: int|float, viewsPerVisit: int|float, bounceRate: int|float, visitDuration: int|float}|null */
    private function rolledStats(array $query): ?array
    {
        $plan = $this->rollupPlan($query, $query['from'], $query['to']);
        if ($plan === null) {
            return null;
        }
        $rolled = $this->db->all(
            'SELECT SUM(visitors) AS visitors, SUM(visits) AS visits, SUM(pageviews) AS pageviews, SUM(bounced) AS bounced, SUM(duration) AS duration
       FROM rl_rollups WHERE site = ? AND dim = \'\' AND day IN (' . Sql::BUILT_DAYS . ')',
            [$query['site'], $query['site'], $query['from'], $query['to']],
        )[0] ?? null;
        $w = self::within($plan['rest']);
        $raw = $this->db->all(
            'SELECT COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits, SUM(s.pageviews) AS pageviews,
         SUM(CASE WHEN ' . Sql::BOUNCE . ' THEN 1 ELSE 0 END) AS bounced, SUM(' . Sql::DURATION . ') AS duration
       FROM rl_sessions s WHERE s.site = ? AND ' . Sql::IS_VISIT . " AND {$w['sql']}",
            [$query['site'], ...$w['params']],
        )[0] ?? null;
        $add = static fn (string $k) => Sql::num($rolled[$k] ?? null) + Sql::num($raw[$k] ?? null);
        $visits = $add('visits');
        $pageviews = $add('pageviews');
        return self::statsOf($add('visitors'), $visits, $pageviews, $add('bounced'), $add('duration'));
    }

    /** @return array{visitors: int|float, visits: int|float, pageviews: int|float, viewsPerVisit: int|float, bounceRate: int|float, visitDuration: int|float} */
    private static function statsOf(int|float $visitors, int|float $visits, int|float $pageviews, int|float $bounced, int|float $duration): array
    {
        return [
            'visitors' => $visitors,
            'visits' => $visits,
            'pageviews' => $pageviews,
            'viewsPerVisit' => $visits > 0 ? self::whole(Js::round(($pageviews / $visits) * 100) / 100) : 0,
            'bounceRate' => $visits > 0 ? self::whole($bounced / $visits) : 0,
            'visitDuration' => $visits > 0 ? self::whole(Js::round($duration / $visits)) : 0,
        ];
    }

    /** A whole float as an int, as JavaScript holds one number type; anything else as it is. */
    private static function whole(int|float $n): int|float
    {
        return is_float($n) && is_finite($n) && $n == floor($n) && abs($n) < 2 ** 53 ? (int) $n : $n;
    }

    /** @param array{name?: string, timezone?: string} $overrides */
    public function setSiteOverrides(string $id, array $overrides): void
    {
        $this->db->run('UPDATE rl_sites SET overrides = ? WHERE id = ?', [Json::encode(Json::object($overrides)), $id]);
    }

    /** When the site last recorded a visit, or null if it never has. */
    public function lastSeen(string $site): int|float|null
    {
        $row = $this->db->all("SELECT MAX(ts) AS t FROM rl_events WHERE site = ? AND kind IN ('pageview', 'event')", [$site])[0] ?? null;
        return $row === null || $row['t'] === null ? null : Sql::num($row['t']);
    }

    /** @return list<array{id: string, name: string, hostnames: list<string>, timezone: string}> */
    public function sites(): array
    {
        $rows = $this->db->all('SELECT id, name, hostnames, timezone FROM rl_sites ORDER BY name, id');
        return array_map(static fn (array $row): array => [
            'id' => (string) $row['id'],
            'name' => (string) $row['name'],
            'hostnames' => Json::decode((string) $row['hostnames'], true),
            'timezone' => (string) $row['timezone'],
        ], $rows);
    }

    // Salts

    /** The salt for a day, made on first ask. Two racing callers agree on one. */
    public function salt(string $day, string $fresh): string
    {
        $this->db->run(Sql::upsert($this->db->dialect(), 'rl_salts', ['day', 'salt'], ['day'], []), [$day, $fresh]);
        $rows = $this->db->all('SELECT salt FROM rl_salts WHERE day = ?', [$day]);
        return isset($rows[0]['salt']) ? (string) $rows[0]['salt'] : $fresh;
    }

    public function saltIfExists(string $day): ?string
    {
        $rows = $this->db->all('SELECT salt FROM rl_salts WHERE day = ?', [$day]);
        return isset($rows[0]['salt']) ? (string) $rows[0]['salt'] : null;
    }

    /** Deletes every salt older than `day`, so old hashes can never be recomputed. */
    public function dropSaltsBefore(string $day): void
    {
        $this->db->run('DELETE FROM rl_salts WHERE day < ?', [$day]);
    }

    // Ingest

    /**
     * The visitor's open session: any of their hashes, active since `since`.
     *
     * @param list<string> $visitors
     * @return array{id: string, visitor: string}|null
     */
    public function openSession(string $site, array $visitors, int $since): ?array
    {
        if (!$visitors) {
            return null;
        }
        $rows = $this->db->all(
            'SELECT id, visitor FROM rl_sessions WHERE site = ? AND visitor IN (' . implode(', ', array_fill(0, count($visitors), '?')) . ') AND last_at >= ?
       ORDER BY last_at DESC, id LIMIT 1',
            [$site, ...array_values($visitors), $since],
        );
        return isset($rows[0]) ? ['id' => (string) $rows[0]['id'], 'visitor' => (string) $rows[0]['visitor']] : null;
    }

    public function insertSession(array $row): void
    {
        $this->db->run(
            'INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, engaged_ms, hostname, referrer_host, referrer_path,
        source, channel, utm_source, utm_medium, utm_campaign, utm_term, utm_content, country, region, city,
        browser, browser_version, os, os_version, device, screen, language)
       VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            [
                $row['id'], $row['site'], $row['visitor'], $row['startedAt'], $row['startedAt'], $row['hostname'], $row['referrerHost'], $row['referrerPath'],
                $row['source'], $row['channel'], $row['utmSource'], $row['utmMedium'], $row['utmCampaign'], $row['utmTerm'], $row['utmContent'],
                $row['country'], $row['region'], $row['city'], $row['browser'], $row['browserVersion'], $row['os'], $row['osVersion'], $row['device'],
                $row['screen'], $row['language'],
            ],
        );
    }

    /**
     * Counts a row into its session. An event with `reopen` false, one that joins a visit already ended,
     * counts without moving the session's last activity.
     */
    public function touchSession(string $id, int $ts, string $kind, string $path, bool $reopen = true): void
    {
        if ($kind === 'click') {
            $this->db->run('UPDATE rl_sessions SET last_at = ? WHERE id = ?', [$ts, $id]);
        } elseif ($kind === 'pageview') {
            $this->db->run(
                "UPDATE rl_sessions SET pageviews = pageviews + 1, last_at = ?, exit_path = ?,
           entry_path = CASE WHEN entry_path = '' THEN ? ELSE entry_path END WHERE id = ?",
                [$ts, $path, $path, $id],
            );
        } elseif ($reopen) {
            $this->db->run('UPDATE rl_sessions SET events = events + 1, last_at = ? WHERE id = ?', [$ts, $id]);
        } else {
            $this->db->run('UPDATE rl_sessions SET events = events + 1 WHERE id = ?', [$id]);
        }
    }

    public function addEngagement(string $id, int $ms): void
    {
        $this->db->run('UPDATE rl_sessions SET engaged_ms = COALESCE(engaged_ms, 0) + ? WHERE id = ?', [$ms, $id]);
    }

    /**
     * The pageview an engagement ping or event belongs to, with when its visit started and was last active.
     *
     * @return array{session: string, visitor: string, path: string, hostname: string, ts: int|float, startedAt: int|float, lastAt: int|float}|null
     */
    public function pageview(string $site, string $pageview): ?array
    {
        $row = $this->db->all(
            "SELECT e.session AS session, e.visitor AS visitor, e.path AS path, e.hostname AS hostname, e.ts AS ts, s.started_at AS started_at, s.last_at AS last_at
       FROM rl_events e JOIN rl_sessions s ON s.id = e.session WHERE e.site = ? AND e.pageview = ? AND e.kind = 'pageview' LIMIT 1",
            [$site, $pageview],
        )[0] ?? null;
        return $row === null ? null : [
            'session' => (string) $row['session'],
            'visitor' => (string) $row['visitor'],
            'path' => (string) $row['path'],
            'hostname' => (string) $row['hostname'],
            'ts' => Sql::num($row['ts']),
            'startedAt' => Sql::num($row['started_at']),
            'lastAt' => Sql::num($row['last_at']),
        ];
    }

    /**
     * After a late event or engagement ping joins an old visit (a tab left open overnight), the day
     * that visit started may already be added up. Forget that day so the next check builds it again.
     */
    public function touchedOldVisit(string $site, int $started, int $before): void
    {
        if ($started < $before) {
            $this->clearRollups($site, ['from' => $started, 'to' => $started + 1]);
        }
    }

    public function insertEvent(array $row): void
    {
        $props = $row['props'] ?? null;
        $this->db->run(
            'INSERT INTO rl_events (site, ts, kind, visitor, session, pageview, path, hostname, title, name, props, engaged_ms, scroll, link)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            [
                $row['site'], $row['ts'], $row['kind'], $row['visitor'], $row['session'], $row['pageview'], $row['path'], $row['hostname'], $row['title'],
                $row['name'], $props === null ? null : Json::encode(is_array($props) ? Json::object($props) : $props), $row['engagedMs'], $row['scroll'] ?? null, $row['link'],
            ],
        );
    }

    // Links

    /** The live link with a slug. Slugs are unique across every domain. */
    public function linkBySlug(string $slug): ?array
    {
        $rows = $this->db->all('SELECT * FROM rl_links WHERE slug = ? AND deleted_at IS NULL LIMIT 1', [$slug]);
        return isset($rows[0]) ? Sql::linkRow($rows[0]) : null;
    }

    public function linkById(string $id): ?array
    {
        $rows = $this->db->all('SELECT * FROM rl_links WHERE id = ? AND deleted_at IS NULL LIMIT 1', [$id]);
        return isset($rows[0]) ? Sql::linkRow($rows[0]) : null;
    }

    public function insertLink(array $link): void
    {
        $this->db->run(
            'INSERT INTO rl_links (id, site, domain, slug, name, url, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
            [$link['id'], $link['site'], $link['domain'], $link['slug'], $link['name'], $link['url'], $link['createdAt'], $link['updatedAt']],
        );
    }

    public function updateLink(array $link): void
    {
        $this->db->run('UPDATE rl_links SET domain = ?, slug = ?, name = ?, url = ?, updated_at = ? WHERE id = ?', [
            $link['domain'], $link['slug'], $link['name'], $link['url'], $link['updatedAt'], $link['id'],
        ]);
    }

    /** Hides a link and frees its slug; its clicks stay in the history. */
    public function deleteLink(string $id, int $now): void
    {
        $this->db->run('UPDATE rl_links SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL', [$now, $id]);
    }

    // Shares

    private static function shareRow(array $r): array
    {
        return ['id' => (string) $r['id'], 'site' => (string) $r['site'], 'name' => (string) ($r['name'] ?? ''), 'createdAt' => Js::number($r['created_at'])];
    }

    /** @return list<array{id: string, site: string, name: string, createdAt: int}> */
    public function shares(string $site): array
    {
        return array_map(self::shareRow(...), $this->db->all('SELECT id, site, name, created_at FROM rl_shares WHERE site = ? ORDER BY created_at DESC, id', [$site]));
    }

    public function shareById(string $id): ?array
    {
        $r = $this->db->all('SELECT id, site, name, created_at FROM rl_shares WHERE id = ?', [$id])[0] ?? null;
        return $r === null ? null : self::shareRow($r);
    }

    public function insertShare(array $share): void
    {
        $this->db->run('INSERT INTO rl_shares (id, site, name, created_at) VALUES (?, ?, ?, ?)', [$share['id'], $share['site'], $share['name'], $share['createdAt']]);
    }

    public function renameShare(string $id, string $name): void
    {
        $this->db->run('UPDATE rl_shares SET name = ? WHERE id = ?', [$name, $id]);
    }

    /** Deleting a share is how it is revoked: the link stops working at once. */
    public function deleteShare(string $id): void
    {
        $this->db->run('DELETE FROM rl_shares WHERE id = ?', [$id]);
    }

    // Funnels

    /** @return list<array{id: string, site: string, name: string, steps: list<array{kind: string, match: string}>, createdAt: int}> */
    public function funnels(string $site): array
    {
        return array_map(static fn (array $r): array => [
            'id' => (string) $r['id'],
            'site' => (string) $r['site'],
            'name' => (string) $r['name'],
            'steps' => Json::decode((string) $r['steps'], true),
            'createdAt' => Js::number($r['created_at']),
        ], $this->db->all('SELECT * FROM rl_funnels WHERE site = ? ORDER BY created_at, id', [$site]));
    }

    public function saveFunnel(array $f): void
    {
        $this->db->run(
            Sql::upsert($this->db->dialect(), 'rl_funnels', ['id', 'site', 'name', 'steps', 'created_at'], ['id'], ['name', 'steps']),
            [$f['id'], $f['site'], $f['name'], Json::encode(array_values($f['steps'])), $f['createdAt']],
        );
    }

    public function deleteFunnel(string $id): void
    {
        $this->db->run('DELETE FROM rl_funnels WHERE id = ?', [$id]);
    }

    /**
     * How many visits reached each step, in order, within the same visit. Step
     * one is the first matching row in the range; each later step must come
     * after the step before it. Filters choose which visits enter the funnel.
     *
     * @return list<int>
     */
    public function funnelCounts(array $query, array $funnel): array
    {
        // The rows of the picked visits that match any step, in order, read once and walked here: a join from
        // each step to the next is planned badly by Postgres, which cannot guess how many visits go on.
        $v = Sql::visitRows($query['filters'], $query['site'], $query['from'], $query['to'], $this->db->dialect());
        $scopes = array_map(fn (array $step): array => $this->goalScope(['kind' => $step['kind'], 'match' => $step['match'], 'name' => $step['match']]), $funnel['steps']);
        $cases = [];
        $any = [];
        $scopeParams = [];
        foreach ($scopes as $i => $scope) {
            $cases[] = "CASE WHEN {$scope['sql']} THEN 1 ELSE 0 END AS m$i";
            $any[] = "({$scope['sql']})";
            array_push($scopeParams, ...$scope['params']);
        }
        $rows = $this->db->all(
            'SELECT e.session AS session, ' . implode(', ', $cases) . "
       FROM {$v['from']} WHERE {$v['sql']} AND (" . implode(' OR ', $any) . ')
       ORDER BY e.session, e.ts, e.id',
            [...$scopeParams, ...$v['params'], ...$scopeParams],
        );
        $counts = array_fill(0, count($funnel['steps']), 0);
        $session = null;
        $started = false;
        $reached = 0;
        $close = function () use (&$counts, &$reached): void {
            for ($i = 0; $i < $reached; $i++) {
                $counts[$i]++;
            }
        };
        foreach ($rows as $row) {
            if (!$started || $row['session'] !== $session) {
                $close();
                $session = $row['session'];
                $started = true;
                $reached = 0;
            }
            // Each step is the first matching row after the step before, so two steps in the same millisecond
            // both count, and one row never counts as two steps.
            if ($reached < count($counts) && Sql::num($row["m$reached"]) == 1) {
                $reached++;
            }
        }
        $close();
        return $counts;
    }

    /**
     * Each visit's pageviews in order, at most `perVisit` of them, for journeys.
     * A window function keeps the first ones of each visit, so a long visit
     * cannot crowd the rest out. Visits belong to the range they started in.
     *
     * @return array{rows: list<array{session: string, path: string}>, sampled: bool}
     */
    public function journeyPages(array $query, int $perVisit): array
    {
        $scope = Sql::visitScope($query['filters'], $query['site'], $query['from'], $query['to'], $this->db->dialect());
        // The newest visits the filters pick, JOURNEY_VISITS at most, so a long range stays quick and small in memory.
        $newest = static fn (string $columns, int $limit): string => "SELECT $columns FROM rl_sessions s WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND " . Sql::IS_VISIT . "{$scope['sql']}
         ORDER BY s.started_at DESC, s.id LIMIT $limit";
        $visitParams = [$query['site'], $query['from'], $query['to'], ...$scope['params']];
        // How many there are, one past the cap telling whether it was reached, and when the oldest of them began,
        // so the rows are read from there on rather than from the start of a long range.
        $first = $this->db->all('SELECT COUNT(*) AS n, MIN(started_at) AS t FROM (' . $newest('s.started_at AS started_at', Sql::JOURNEY_VISITS + 1) . ') x', $visitParams)[0] ?? null;
        if (!Sql::num($first['n'] ?? null)) {
            return ['rows' => [], 'sampled' => false];
        }
        $from = max($query['from'], Sql::num($first['t'] ?? null));
        // MySQL takes no LIMIT in an IN list, but does in a table inside one.
        $visits = $this->db->dialect() === 'mysql' ? 'SELECT id FROM (' . $newest('s.id AS id', Sql::JOURNEY_VISITS) . ') x' : $newest('s.id', Sql::JOURNEY_VISITS);
        $rows = $this->db->all(
            // The visits are read as an IN list, which every database probes from the events side, so the
            // plan does not depend on the planner's statistics. Refreshes (the same page twice in a row) are
            // dropped before counting, so they never use up the steps.
            "WITH raw AS (
         SELECT e.session AS session, e.path AS path, e.ts AS ts, e.id AS id,
           LAG(e.path) OVER (PARTITION BY e.session ORDER BY e.ts, e.id) AS prev
         FROM rl_events e
         WHERE e.site = ? AND e.kind = 'pageview' AND e.ts >= ? AND e.ts < ? AND e.session IN ($visits)),
       v AS (
         SELECT session, path, ROW_NUMBER() OVER (PARTITION BY session ORDER BY ts, id) AS n
         FROM raw WHERE prev IS NULL OR prev <> path)
       SELECT session, path FROM v WHERE n <= ? ORDER BY session, n",
            [$query['site'], $from, $query['to'] + Sql::EVENT_TAIL_MS, ...$visitParams, $perVisit],
        );
        return [
            'rows' => array_map(static fn (array $r): array => ['session' => (string) $r['session'], 'path' => (string) $r['path']], $rows),
            'sampled' => Sql::num($first['n']) > Sql::JOURNEY_VISITS,
        ];
    }

    // API tokens

    private static function tokenRow(array $r): array
    {
        return [
            'id' => (string) $r['id'],
            'name' => (string) $r['name'],
            'site' => (string) ($r['site'] ?? ''),
            'scope' => match ($r['scope'] ?? null) {
                'manage' => 'manage',
                'embed' => 'embed',
                default => 'read',
            },
            'hash' => (string) $r['hash'],
            'hint' => (string) ($r['hint'] ?? ''),
            'createdAt' => Js::number($r['created_at']),
            'lastUsedAt' => ($r['last_used_at'] ?? null) === null ? null : Js::number($r['last_used_at']),
        ];
    }

    public function tokens(): array
    {
        return array_map(self::tokenRow(...), $this->db->all('SELECT * FROM rl_tokens ORDER BY created_at DESC, id'));
    }

    public function tokenByHash(string $hash): ?array
    {
        $row = $this->db->all('SELECT * FROM rl_tokens WHERE hash = ?', [$hash])[0] ?? null;
        return $row === null ? null : self::tokenRow($row);
    }

    public function insertToken(array $t): void
    {
        $this->db->run('INSERT INTO rl_tokens (id, name, site, scope, hash, hint, created_at, last_used_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)', [
            $t['id'],
            $t['name'],
            $t['site'],
            $t['scope'],
            $t['hash'],
            $t['hint'],
            $t['createdAt'],
            $t['lastUsedAt'] ?? null,
        ]);
    }

    public function touchToken(string $id, int $now): void
    {
        $this->db->run('UPDATE rl_tokens SET last_used_at = ? WHERE id = ?', [$now, $id]);
    }

    /** Deleting a token is how it is revoked: it stops working at once. */
    public function deleteToken(string $id): bool
    {
        return $this->changed('DELETE FROM rl_tokens WHERE id = ?', [$id]) === 1;
    }

    // Settings

    public function setting(string $key): ?string
    {
        $row = $this->db->all('SELECT value FROM rl_settings WHERE "key" = ?', [$key])[0] ?? null;
        return $row === null ? null : (string) $row['value'];
    }

    /**
     * Every setting whose key starts with a prefix, such as each connected install's.
     *
     * @return list<array{key: string, value: string}>
     */
    public function settingsStartingWith(string $prefix): array
    {
        $rows = $this->db->all("SELECT \"key\", value FROM rl_settings WHERE \"key\" LIKE ? ESCAPE '\\'", [Sql::escapeLike($prefix) . '%']);
        return array_map(static fn (array $r): array => ['key' => (string) $r['key'], 'value' => (string) $r['value']], $rows);
    }

    /** Reads a setting and deletes it. Of two callers at once, only the one whose delete took the row gets its value. */
    public function takeSetting(string $key): ?string
    {
        $value = $this->setting($key);
        if ($value === null) {
            return null;
        }
        $sql = 'DELETE FROM rl_settings WHERE "key" = ?';
        $gone = $this->db->dialect() === 'mysql' && method_exists($this->db, 'affected')
            ? $this->db->affected($sql, [$key])
            : count($this->db->all("$sql RETURNING \"key\"", [$key]));
        return $gone === 1 ? $value : null;
    }

    public function setSetting(string $key, ?string $value): void
    {
        if ($value === null) {
            $this->db->run('DELETE FROM rl_settings WHERE "key" = ?', [$key]);
        } else {
            $this->db->run(Sql::upsert($this->db->dialect(), 'rl_settings', ['"key"', 'value'], ['"key"'], ['value']), [$key, $value]);
        }
    }

    // Email reports

    private static function reportRow(array $r): array
    {
        return [
            'id' => (string) $r['id'],
            'site' => (string) $r['site'],
            'email' => (string) $r['email'],
            'frequency' => (string) $r['frequency'],
            'lang' => (string) ($r['lang'] ?? 'en'),
            'token' => (string) $r['token'],
            'origin' => (string) ($r['origin'] ?? ''),
            'lastPeriod' => (string) ($r['last_period'] ?? ''),
            'lastSentAt' => ($r['last_sent_at'] ?? null) === null ? null : Js::number($r['last_sent_at']),
            'createdAt' => Js::number($r['created_at']),
        ];
    }

    public function reports(?string $site = null): array
    {
        $rows = $site !== null && $site !== ''
            ? $this->db->all('SELECT * FROM rl_reports WHERE site = ? ORDER BY created_at, id', [$site])
            : $this->db->all('SELECT * FROM rl_reports ORDER BY created_at, id');
        return array_map(self::reportRow(...), $rows);
    }

    /** @param 'id'|'token' $field */
    public function reportBy(string $field, string $value): ?array
    {
        $row = $this->db->all('SELECT * FROM rl_reports WHERE ' . ($field === 'id' ? 'id' : 'token') . ' = ?', [$value])[0] ?? null;
        return $row === null ? null : self::reportRow($row);
    }

    public function insertReport(array $r): void
    {
        $this->db->run(
            'INSERT INTO rl_reports (id, site, email, frequency, lang, token, origin, last_period, last_sent_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            [$r['id'], $r['site'], $r['email'], $r['frequency'], $r['lang'], $r['token'], $r['origin'], $r['lastPeriod'], $r['lastSentAt'] ?? null, $r['createdAt']],
        );
    }

    /** Records a period as sent. Only one caller wins, so two cron runs at once cannot both send it. */
    public function claimReport(string $id, string $period, int $now): bool
    {
        // One statement, so of two cron runs at once only one gets the row back.
        return $this->changed('UPDATE rl_reports SET last_period = ?, last_sent_at = ? WHERE id = ? AND last_period <> ?', [$period, $now, $id, $period]) === 1;
    }

    /** Puts a period back when its email failed, so the next run tries again. */
    public function releaseReport(string $id, string $period, string $previous): void
    {
        $this->db->run('UPDATE rl_reports SET last_period = ? WHERE id = ? AND last_period = ?', [$previous, $id, $period]);
    }

    public function deleteReport(string $id): void
    {
        $this->db->run('DELETE FROM rl_reports WHERE id = ?', [$id]);
    }

    // Goals

    public function goals(?string $site = null): array
    {
        $rows = $site !== null && $site !== ''
            ? $this->db->all('SELECT * FROM rl_goals WHERE site = ? ORDER BY created_at, id', [$site])
            : $this->db->all('SELECT * FROM rl_goals ORDER BY created_at, id');
        return array_map(Sql::goalRow(...), $rows);
    }

    public function goalById(string $id): ?array
    {
        $row = $this->db->all('SELECT * FROM rl_goals WHERE id = ?', [$id])[0] ?? null;
        return $row === null ? null : Sql::goalRow($row);
    }

    public function saveGoal(array $g, ?array $before = null): void
    {
        // A click goal is counted by its name, which the tracker sends as the event
        // name. Renaming one renames its past clicks too, so its history stays.
        if ($before !== null && $before['kind'] === 'click' && $g['kind'] === 'click' && $before['name'] !== $g['name']) {
            $this->db->run("UPDATE rl_events SET name = ? WHERE site = ? AND kind = 'event' AND name = ?", [$g['name'], $g['site'], $before['name']]);
        }
        $this->db->run(
            Sql::upsert(
                $this->db->dialect(),
                'rl_goals',
                ['id', 'site', 'name', 'kind', '"match"', 'click_by', 'value_mode', 'value', 'value_prop', 'currency', 'created_at'],
                ['id'],
                ['name', 'kind', '"match"', 'click_by', 'value_mode', 'value', 'value_prop', 'currency'],
            ),
            [$g['id'], $g['site'], $g['name'], $g['kind'], $g['match'], $g['clickBy'], $g['valueMode'], $g['value'], $g['valueProp'], $g['currency'], $g['createdAt']],
        );
    }

    public function deleteGoal(string $id): void
    {
        $this->db->run('DELETE FROM rl_goals WHERE id = ?', [$id]);
    }

    /**
     * The events a goal counts, as a WHERE fragment over rl_events e.
     *
     * @return array{sql: string, params: list<mixed>}
     */
    private function goalScope(array $goal): array
    {
        if ($goal['kind'] === 'page') {
            if (!str_contains($goal['match'], '*')) {
                return ['sql' => "e.kind = 'pageview' AND e.path = ?", 'params' => [$goal['match']]];
            }
            return $this->db->dialect() !== 'sqlite'
                // Postgres's LIKE heeds case, and so does MySQL's under Runlight's binary collation.
                ? ['sql' => "e.kind = 'pageview' AND e.path LIKE ? ESCAPE '\\'", 'params' => [Sql::likePattern($goal['match'])]]
                // SQLite's LIKE ignores case; GLOB does not, so every database agrees with the others and with exact matches.
                : ['sql' => "e.kind = 'pageview' AND e.path GLOB ?", 'params' => [Sql::globPattern($goal['match'])]];
        }
        // Event goals count the named event; click goals count the event the tracker sends for them.
        return ['sql' => "e.kind = 'event' AND e.name = ?", 'params' => [$goal['kind'] === 'click' ? $goal['name'] : $goal['match']]];
    }

    /**
     * A numeric event property for one row, as SQL (0 when it is not a number). Property names are checked before they get here.
     *
     * @return array{sql: string, params: list<mixed>}
     */
    private function propValue(string $prop): array
    {
        if ($this->db->dialect() === 'postgres') {
            return [
                'sql' => '(CASE WHEN (e.props::jsonb ->> ?) ~ \'^-?[0-9]+(\.[0-9]+)?$\' THEN (e.props::jsonb ->> ?)::numeric ELSE 0 END)',
                'params' => [$prop, $prop],
            ];
        }
        $path = "\$.\"$prop\"";
        if ($this->db->dialect() === 'mysql') {
            // As SQLite: a JSON number as it is, or text of digits with an optional sign and one decimal point.
            $value = 'JSON_EXTRACT(e.props, ?)';
            return [
                'sql' => "(CASE
          WHEN JSON_TYPE($value) IN ('INTEGER', 'UNSIGNED INTEGER', 'DOUBLE', 'DECIMAL') THEN CAST($value AS DOUBLE)
          WHEN JSON_TYPE($value) = 'STRING' AND JSON_UNQUOTE($value) REGEXP '^-?[0-9]+([.][0-9]+)?$' THEN CAST(JSON_UNQUOTE($value) AS DOUBLE)
          ELSE 0 END)",
                'params' => array_fill(0, 5, $path),
            ];
        }
        // As Postgres's pattern: a JSON number, or text of digits with an optional sign and one decimal point.
        $text = 'CAST(json_extract(e.props, ?) AS TEXT)';
        return [
            'sql' => "(CASE
        WHEN json_type(e.props, ?) IN ('integer', 'real') THEN json_extract(e.props, ?)
        WHEN json_type(e.props, ?) = 'text' AND $text GLOB '[0-9]*' AND $text NOT GLOB '*[^0-9.]*' AND $text NOT GLOB '*.*.*' AND $text NOT GLOB '*.' THEN CAST($text AS REAL)
        WHEN json_type(e.props, ?) = 'text' AND $text GLOB '-[0-9]*' AND substr($text, 2) NOT GLOB '*[^0-9.]*' AND $text NOT GLOB '*.*.*' AND $text NOT GLOB '*.' THEN CAST($text AS REAL)
        ELSE 0 END)",
            'params' => array_fill(0, 14, $path),
        ];
    }

    /**
     * The property names sent with an event in a query's range, most used first.
     *
     * @return list<array{key: string, events: int}>
     */
    public function eventPropKeys(array $query, string $event): array
    {
        $v = Sql::visitRows($query['filters'], $query['site'], $query['from'], $query['to'], $this->db->dialect());
        $where = "{$v['sql']} AND e.kind = 'event' AND e.name = ? AND e.props IS NOT NULL";
        $params = [...$v['params'], $event];
        $rows = match ($this->db->dialect()) {
            // Each key as a row of its own, compared and sorted by code point like every other value.
            'mysql' => $this->db->all(
                "SELECT j.k AS \"key\", COUNT(*) AS events FROM {$v['from']}
             CROSS JOIN JSON_TABLE(JSON_KEYS(CASE WHEN JSON_TYPE(e.props) = 'OBJECT' THEN e.props ELSE '{}' END), '\$[*]' COLUMNS (k VARCHAR(255) COLLATE " . Sql::MYSQL_COLLATION . " PATH '\$')) j
             WHERE $where GROUP BY j.k ORDER BY events DESC, j.k LIMIT 30",
                $params,
            ),
            'postgres' => $this->db->all(
                "SELECT k AS \"key\", COUNT(*) AS events FROM {$v['from']} CROSS JOIN LATERAL jsonb_object_keys(CASE WHEN jsonb_typeof(e.props::jsonb) = 'object' THEN e.props::jsonb ELSE '{}'::jsonb END) AS k
             WHERE $where GROUP BY k ORDER BY events DESC, k{$this->textOrder()} LIMIT 30",
                $params,
            ),
            default => $this->db->all(
                "SELECT j.key AS \"key\", COUNT(*) AS events FROM {$v['from']}, json_each(e.props) j
             WHERE $where AND json_type(e.props) = 'object' GROUP BY j.key ORDER BY events DESC, key{$this->textOrder()} LIMIT 30",
                $params,
            ),
        };
        return array_map(static fn (array $r): array => ['key' => (string) $r['key'], 'events' => Sql::num($r['events'])], $rows);
    }

    /**
     * The values one property of an event took, with how often and by how many visitors.
     *
     * @return list<array{value: string, events: int, visitors: int}>
     */
    public function eventPropValues(array $query, string $event, string $key, int $limit): array
    {
        $v = Sql::visitRows($query['filters'], $query['site'], $query['from'], $query['to'], $this->db->dialect());
        $value = match ($this->db->dialect()) {
            'postgres' => '(e.props::jsonb ->> ?)',
            'mysql' => '(JSON_UNQUOTE(JSON_EXTRACT(e.props, ?)) COLLATE ' . Sql::MYSQL_COLLATION . ')',
            default => 'CAST(json_extract(e.props, ?) AS TEXT)',
        };
        $path = $this->db->dialect() === 'postgres' ? $key : "\$.\"$key\"";
        $rows = $this->db->all(
            "SELECT * FROM (SELECT $value AS value, COUNT(*) AS events, COUNT(DISTINCT e.visitor) AS visitors FROM {$v['from']}
         WHERE {$v['sql']} AND e.kind = 'event' AND e.name = ? AND $value IS NOT NULL GROUP BY 1) t
       ORDER BY events DESC, value{$this->textOrder()} LIMIT ?",
            [$path, ...$v['params'], $event, $path, $limit],
        );
        return array_map(static fn (array $r): array => ['value' => (string) $r['value'], 'events' => Sql::num($r['events']), 'visitors' => Sql::num($r['visitors'])], $rows);
    }

    /** The floating point type to cast to, which MySQL names in one word. */
    private function double(): string
    {
        return $this->db->dialect() === 'mysql' ? 'DOUBLE' : 'DOUBLE PRECISION';
    }

    /**
     * A goal's worth for one converting row, as SQL.
     *
     * @return array{sql: string, params: list<mixed>}
     */
    private function revenueValue(array $goal): array
    {
        if ($goal['valueMode'] === 'prop' && $goal['valueProp'] !== '') {
            return $this->propValue($goal['valueProp']);
        }
        if ($goal['valueMode'] === 'fixed') {
            return ['sql' => "CAST(? AS {$this->double()})", 'params' => [$goal['value']]];
        }
        return ['sql' => '0', 'params' => []];
    }

    /** Math.round(n * 100) / 100, for money. */
    private static function cents(int|float $n): int|float
    {
        return self::whole(Js::round($n * 100) / 100);
    }

    /**
     * Every goal's totals in one pass over the range's events, instead of a query
     * per goal: each goal adds a conditional count, distinct count, and sum.
     *
     * @return array<string, array{conversions: int, visitors: int, revenue: int|float}> keyed by goal id
     */
    public function goalTotalsAll(array $query, array $goals): array
    {
        $out = [];
        $v = Sql::visitRows($query['filters'], $query['site'], $query['from'], $query['to'], $this->db->dialect());
        // As many goals per query as keep it under D1's parameter limit.
        $chunks = [[]];
        $count = count($v['params']);
        foreach ($goals as $goal) {
            $cost = count($this->goalScope($goal)['params']) * 4 + count($this->revenueValue($goal)['params']);
            if ($chunks[count($chunks) - 1] && $count + $cost > Sql::MAX_PARAMS) {
                $chunks[] = [];
                $count = count($v['params']);
            }
            $chunks[count($chunks) - 1][] = $goal;
            $count += $cost;
        }
        foreach ($chunks as $chunk) {
            if (!$chunk) {
                continue;
            }
            $columns = [];
            $params = [];
            // Only rows some goal of the chunk counts are read.
            $any = [];
            $anyParams = [];
            foreach ($chunk as $i => $goal) {
                $scope = $this->goalScope($goal);
                $value = $this->revenueValue($goal);
                array_push(
                    $columns,
                    "SUM(CASE WHEN {$scope['sql']} THEN 1 ELSE 0 END) AS c$i",
                    "COUNT(DISTINCT CASE WHEN {$scope['sql']} THEN e.visitor END) AS v$i",
                    "SUM(CASE WHEN {$scope['sql']} THEN {$value['sql']} ELSE 0 END) AS r$i",
                );
                array_push($params, ...$scope['params'], ...$scope['params'], ...$scope['params'], ...$value['params']);
                $any[] = "({$scope['sql']})";
                array_push($anyParams, ...$scope['params']);
            }
            $row = $this->db->all(
                'SELECT ' . implode(', ', $columns) . " FROM {$v['from']}
         WHERE {$v['sql']} AND e.kind IN ('pageview', 'event') AND (" . implode(' OR ', $any) . ')',
                [...$params, ...$v['params'], ...$anyParams],
            )[0] ?? null;
            foreach ($chunk as $i => $goal) {
                $out[$goal['id']] = ['conversions' => Sql::num($row["c$i"] ?? null), 'visitors' => Sql::num($row["v$i"] ?? null), 'revenue' => self::cents(Sql::num($row["r$i"] ?? null))];
            }
        }
        return $out;
    }

    /** @return array{sql: string, params: list<mixed>} */
    private function revenueSql(array $goal): array
    {
        if ($goal['valueMode'] === 'prop' && $goal['valueProp'] !== '') {
            $value = $this->propValue($goal['valueProp']);
            return ['sql' => "SUM({$value['sql']})", 'params' => $value['params']];
        }
        // Cast, so Postgres does not read the bound value as a bigint and refuse 9.99.
        if ($goal['valueMode'] === 'fixed') {
            return ['sql' => "COUNT(*) * CAST(? AS {$this->double()})", 'params' => [$goal['value']]];
        }
        return ['sql' => '0', 'params' => []];
    }

    /**
     * One goal's conversions, converting visitors, and revenue for a query's range and filters.
     *
     * @return array{conversions: int, visitors: int, revenue: int|float}
     */
    public function goalTotals(array $query, array $goal): array
    {
        $v = Sql::visitRows($query['filters'], $query['site'], $query['from'], $query['to'], $this->db->dialect());
        $scope = $this->goalScope($goal);
        $revenue = $this->revenueSql($goal);
        $row = $this->db->all(
            "SELECT COUNT(*) AS conversions, COUNT(DISTINCT e.visitor) AS visitors, {$revenue['sql']} AS revenue
       FROM {$v['from']} WHERE {$v['sql']} AND {$scope['sql']}",
            [...$revenue['params'], ...$v['params'], ...$scope['params']],
        )[0] ?? null;
        return ['conversions' => Sql::num($row['conversions'] ?? null), 'visitors' => Sql::num($row['visitors'] ?? null), 'revenue' => self::cents(Sql::num($row['revenue'] ?? null))];
    }

    /**
     * A goal's conversions split by where the visit came from, or by the page it happened on.
     *
     * @param 'source'|'channel'|'path' $by
     * @return list<array{value: string, conversions: int, visitors: int, revenue: int|float}>
     */
    public function goalBreakdown(array $query, array $goal, string $by, int $limit = 10): array
    {
        $v = Sql::visitRows($query['filters'], $query['site'], $query['from'], $query['to'], $this->db->dialect());
        $col = $by === 'path' ? 'e.path' : "s.$by";
        $scope = $this->goalScope($goal);
        $revenue = $this->revenueSql($goal);
        $rows = $this->db->all(
            "SELECT $col AS value, COUNT(*) AS conversions, COUNT(DISTINCT e.visitor) AS visitors, {$revenue['sql']} AS revenue
       FROM {$v['from']} WHERE {$v['sql']} AND {$scope['sql']}
       GROUP BY $col ORDER BY conversions DESC, $col{$this->textOrder()} LIMIT ?",
            [...$revenue['params'], ...$v['params'], ...$scope['params'], $limit],
        );
        return array_map(static fn (array $r): array => [
            'value' => (string) ($r['value'] ?? ''),
            'conversions' => Sql::num($r['conversions']),
            'visitors' => Sql::num($r['visitors']),
            'revenue' => self::cents(Sql::num($r['revenue'])),
        ], $rows);
    }

    /**
     * A goal's conversions and revenue in each bucket, by when each visit started.
     *
     * @param list<array{start: int, end: int}> $buckets
     * @return list<array{start: int, conversions: int, revenue: int|float}>
     */
    public function goalSeries(array $query, array $goal, array $buckets): array
    {
        if (!$buckets) {
            return [];
        }
        $scope = $this->goalScope($goal);
        $revenue = $this->revenueSql($goal);
        // Each bucket binds three values; the rest are fixed. As many buckets a statement as keep it under D1's 100.
        $fixed = count($revenue['params']) + count($scope['params']) + count(Sql::visitRows($query['filters'], $query['site'], 0, 0, $this->db->dialect())['params']);
        $size = max(1, min(Sql::BUCKETS_PER_QUERY, (int) floor((Sql::MAX_PARAMS - $fixed) / 3)));
        if (count($buckets) > $size) {
            return Sql::inPieces($buckets, $size, fn (array $piece): array => $this->goalSeries($query, $goal, $piece));
        }
        $last = $buckets[count($buckets) - 1];
        $v = Sql::visitRows($query['filters'], $query['site'], $buckets[0]['start'], $last['end'], $this->db->dialect());
        $rows = $this->db->all(
            'WITH b (i, bs, be) AS (' . Sql::bucketTable($this->db->dialect(), $buckets) . ")
       SELECT b.i AS i, COUNT(*) AS conversions, {$revenue['sql']} AS revenue
       FROM {$v['from']} CROSS JOIN b
       WHERE {$v['sql']} AND s.started_at >= b.bs AND s.started_at < b.be AND {$scope['sql']}
       GROUP BY b.i",
            [...self::bucketParams($buckets), ...$revenue['params'], ...$v['params'], ...$scope['params']],
        );
        $found = [];
        foreach ($rows as $r) {
            $found[(int) Sql::num($r['i'])] = $r;
        }
        $out = [];
        foreach ($buckets as $i => $b) {
            $out[] = ['start' => $b['start'], 'conversions' => Sql::num($found[$i]['conversions'] ?? null), 'revenue' => self::cents(Sql::num($found[$i]['revenue'] ?? null))];
        }
        return $out;
    }

    /** @param list<array{start: int, end: int}> $buckets */
    private static function bucketParams(array $buckets): array
    {
        $params = [];
        foreach (array_values($buckets) as $i => $b) {
            array_push($params, $i, $b['start'], $b['end']);
        }
        return $params;
    }

    /** @return list<array{domain: string, site: string}> */
    public function linkDomains(): array
    {
        return array_map(static fn (array $r): array => ['domain' => (string) $r['domain'], 'site' => (string) $r['site']], $this->db->all('SELECT domain, site FROM rl_link_domains ORDER BY domain'));
    }

    public function addLinkDomain(string $domain, string $site, int $now): void
    {
        $this->db->run(Sql::upsert($this->db->dialect(), 'rl_link_domains', ['domain', 'site', 'created_at'], ['domain'], []), [$domain, $site, $now]);
    }

    /**
     * Removes a domain. Its links keep it as their home and fall back to the
     * app's own link path until the domain is added again.
     */
    public function removeLinkDomain(string $domain): void
    {
        $this->db->run('DELETE FROM rl_link_domains WHERE domain = ?', [$domain]);
    }

    /**
     * A site's links, newest first, with their clicks in a range. Clicks
     * imported as daily counts have no visitor, so they add to clicks only.
     *
     * @return list<array<string, mixed>> LinkRow with clicks and visitors
     */
    public function links(string $site, int $from, int $to): array
    {
        $rows = $this->db->all(
            "SELECT l.*, COALESCE(c.clicks, 0) AS clicks, COALESCE(c.visitors, 0) AS visitors
       FROM rl_links l LEFT JOIN (
         SELECT link, COUNT(*) AS clicks, COUNT(DISTINCT NULLIF(visitor, '')) AS visitors FROM rl_events
         WHERE site = ? AND kind = 'click' AND ts >= ? AND ts < ? GROUP BY link
       ) c ON c.link = l.id
       WHERE l.site = ? AND l.deleted_at IS NULL
       ORDER BY l.created_at DESC, l.id",
            [$site, $from, $to, $site],
        );
        return array_map(static fn (array $row): array => [...Sql::linkRow($row), 'clicks' => Sql::num($row['clicks']), 'visitors' => Sql::num($row['visitors'])], $rows);
    }

    /**
     * One link's clicks per bucket.
     *
     * @param list<array{start: int, end: int}> $buckets
     * @return list<array{start: int, clicks: int, visitors: int}>
     */
    public function linkSeries(string $site, string $link, array $buckets): array
    {
        if (!$buckets) {
            return [];
        }
        if (count($buckets) > Sql::BUCKETS_PER_QUERY) {
            return Sql::inPieces($buckets, Sql::BUCKETS_PER_QUERY, fn (array $piece): array => $this->linkSeries($site, $link, $piece));
        }
        $rows = $this->db->all(
            'WITH b (i, bs, be) AS (' . Sql::bucketTable($this->db->dialect(), $buckets) . ")
       SELECT b.i AS i, COUNT(*) AS clicks, COUNT(DISTINCT NULLIF(e.visitor, '')) AS visitors
       FROM b JOIN rl_events e ON e.link = ? AND e.ts >= b.bs AND e.ts < b.be
       WHERE e.site = ? AND e.kind = 'click' GROUP BY b.i",
            [...self::bucketParams($buckets), $link, $site],
        );
        $found = [];
        foreach ($rows as $r) {
            $found[(int) Sql::num($r['i'])] = $r;
        }
        $out = [];
        foreach (array_values($buckets) as $i => $bucket) {
            $out[] = ['start' => $bucket['start'], 'clicks' => Sql::num($found[$i]['clicks'] ?? null), 'visitors' => Sql::num($found[$i]['visitors'] ?? null)];
        }
        return $out;
    }

    /**
     * One link's clicks by a visit dimension: where they came from, where they were, what they used.
     *
     * @return list<array{value: string, visitors: int, events: int}>
     */
    public function linkBreakdown(string $site, string $link, int $from, int $to, string $dimension, int $limit): array
    {
        $col = 's.' . Query::SESSION_DIMENSIONS[$dimension];
        $rows = $this->db->all(
            "SELECT $col AS value, COUNT(*) AS clicks, COUNT(DISTINCT e.visitor) AS visitors
       FROM rl_events e JOIN rl_sessions s ON s.id = e.session
       WHERE e.site = ? AND e.link = ? AND e.kind = 'click' AND e.ts >= ? AND e.ts < ? AND $col <> ''
       GROUP BY $col ORDER BY clicks DESC, $col{$this->textOrder()} LIMIT ?",
            [$site, $link, $from, $to, $limit],
        );
        return array_map(static fn (array $row): array => ['value' => (string) $row['value'], 'visitors' => Sql::num($row['visitors']), 'events' => Sql::num($row['clicks'])], $rows);
    }

    // Reports

    /**
     * Ties are broken by the value in code point order, the order the rolled-up path sorts in, so a report
     * reads the same before and after its days are built. Postgres would otherwise use its locale's order.
     * MySQL's columns already sort this way; a value worked out from JSON may not.
     */
    private function textOrder(): string
    {
        return match ($this->db->dialect()) {
            'postgres' => ' COLLATE "C"',
            'mysql' => ' COLLATE ' . Sql::MYSQL_COLLATION,
            default => '',
        };
    }

    /** When Runlight itself first counted a visit, leaving out imported history. */
    public function firstOwnVisit(string $site): int|float|null
    {
        // A session opened only by a short link click is not a visit, so it does not count as the first.
        $row = $this->db->all('SELECT MIN(started_at) AS t FROM rl_sessions s WHERE s.site = ? AND s.imported = 0 AND ' . Sql::IS_VISIT, [$site])[0] ?? null;
        return $row === null || $row['t'] === null ? null : Sql::num($row['t']);
    }

    /** When the site's first visit was recorded, or null with no data yet. */
    public function firstSeen(string $site): int|float|null
    {
        $row = $this->db->all('SELECT MIN(started_at) AS t FROM rl_sessions WHERE site = ?', [$site])[0] ?? null;
        return $row === null || $row['t'] === null ? null : Sql::num($row['t']);
    }

    /** Just the visitor count from stats(), in one query, for conversion rates. */
    public function visitors(array $query): int|float
    {
        $scope = Sql::visitScope($query['filters'], $query['site'], $query['from'], $query['to'], $this->db->dialect());
        $row = $this->db->all(
            'SELECT COUNT(DISTINCT s.visitor) AS visitors FROM rl_sessions s WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND ' . Sql::IS_VISIT . $scope['sql'],
            [$query['site'], $query['from'], $query['to'], ...$scope['params']],
        )[0] ?? null;
        return Sql::num($row['visitors'] ?? null);
    }

    /** @return array{visitors: int|float, visits: int|float, pageviews: int|float, viewsPerVisit: int|float, bounceRate: int|float, visitDuration: int|float} */
    public function stats(array $query): array
    {
        $rolled = $this->rolledStats($query);
        if ($rolled !== null) {
            return $rolled;
        }
        // Filtered or not, the numbers describe visits that started in the range (see visitScope).
        $scope = Sql::visitScope($query['filters'], $query['site'], $query['from'], $query['to'], $this->db->dialect());
        $pv = Sql::pageviewsOf($query['filters'], $query['site'], $query['from'], $query['to'], $this->db->dialect());
        $row = $this->db->all(
            'SELECT COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits, SUM(' . ($pv ? 'COALESCE(pv.n, 0)' : 's.pageviews') . ') AS pageviews,
         SUM(CASE WHEN ' . Sql::BOUNCE . ' THEN 1 ELSE 0 END) AS bounced, SUM(' . Sql::DURATION . ') AS duration
       FROM rl_sessions s ' . ($pv ? "LEFT JOIN {$pv['sql']} pv ON pv.session = s.id" : '') . '
       WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND ' . Sql::IS_VISIT . $scope['sql'],
            [...($pv['params'] ?? []), $query['site'], $query['from'], $query['to'], ...$scope['params']],
        )[0] ?? null;
        return self::statsOf(Sql::num($row['visitors'] ?? null), Sql::num($row['visits'] ?? null), Sql::num($row['pageviews'] ?? null), Sql::num($row['bounced'] ?? null), Sql::num($row['duration'] ?? null));
    }

    /**
     * @param array{site: string, filters: list<array>} $query
     * @param list<array{start: int, end: int}> $buckets
     * @return list<array{start: int, visitors: int, visits: int, pageviews: int, viewsPerVisit: int|float, bounceRate: int|float, visitDuration: int}>
     */
    public function series(array $query, array $buckets): array
    {
        $buckets = array_values($buckets);
        if (!$buckets) {
            return [];
        }
        if (count($buckets) > Sql::BUCKETS_PER_QUERY) {
            return Sql::inPieces($buckets, Sql::BUCKETS_PER_QUERY, fn (array $piece): array => $this->series($query, $piece));
        }
        $params = self::bucketParams($buckets);
        $first = $buckets[0]['start'];
        $last = $buckets[count($buckets) - 1]['end'];
        $dialect = $this->db->dialect();
        // Filtered or not, each bucket counts the visits that started in it (see visitScope).
        $scope = Sql::visitScope($query['filters'], $query['site'], $first, $last, $dialect);
        $pv = Sql::pageviewsOf($query['filters'], $query['site'], $first, $last, $dialect);
        // Built days that fit inside one bucket come from rollups; the rest from the visits.
        $plan = $this->rollupPlan($query, $first, $last);
        $inBucket = static function (array $d) use ($buckets): int {
            foreach ($buckets as $i => $b) {
                if ($b['start'] <= $d['start'] && $d['end'] <= $b['end']) {
                    return $i;
                }
            }
            return -1;
        };
        $used = $plan ? array_values(array_filter($plan['days'], static fn (array $d): bool => $inBucket($d) >= 0)) : [];
        $rest = null;
        if ($used) {
            $rest = [];
            $from = $first;
            foreach ($used as $d) {
                if ($d['start'] > $from) {
                    $rest[] = [$from, $d['start']];
                }
                $from = max($from, $d['end']);
            }
            if ($from < $last) {
                $rest[] = [$from, $last];
            }
        }
        // MySQL joins the buckets to every visit of the site unless told the whole range as well.
        $w = $rest !== null ? self::within($rest) : ($dialect === 'mysql' ? self::within([[$first, $last]]) : ['sql' => '1 = 1', 'params' => []]);
        // Filters and scattered unbuilt days add values of their own; when they would pass D1's 100, the
        // buckets go in halves.
        if (count($params) + 1 + count($w['params']) + count($scope['params']) + count($pv['params'] ?? []) > Sql::MAX_PARAMS && count($buckets) > 1) {
            $half = (int) ceil(count($buckets) / 2);
            return [...$this->series($query, array_slice($buckets, 0, $half)), ...$this->series($query, array_slice($buckets, $half))];
        }
        $sums = [];
        $bump = function (int $i, array $row) use (&$sums): void {
            $into = $sums[$i] ?? ['visitors' => 0, 'n' => 0, 'views' => 0, 'bounced' => 0, 'duration' => 0];
            foreach ($into as $k => $n) {
                $into[$k] = $n + Sql::num($row[$k] ?? null);
            }
            $sums[$i] = $into;
        };
        if ($used) {
            $rolled = $this->db->all(
                "SELECT day, visitors, visits AS n, pageviews AS views, bounced, duration FROM rl_rollups WHERE site = ? AND dim = '' AND day IN (" . Sql::BUILT_DAYS . ')',
                [$query['site'], $query['site'], $first, $last],
            );
            $at = [];
            foreach ($used as $d) {
                $at['d' . $d['day']] = $inBucket($d);
            }
            foreach ($rolled as $row) {
                if (isset($at['d' . $row['day']])) {
                    $bump($at['d' . $row['day']], $row);
                }
            }
        }
        $rows = $this->db->all(
            'WITH b (i, bs, be) AS (' . Sql::bucketTable($dialect, $buckets) . ')
       SELECT b.i AS i, COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS n, SUM(' . ($pv ? 'COALESCE(pv.n, 0)' : 's.pageviews') . ') AS views,
         SUM(CASE WHEN ' . Sql::BOUNCE . ' THEN 1 ELSE 0 END) AS bounced, SUM(' . Sql::DURATION . ') AS duration
       FROM b JOIN rl_sessions s ON s.site = ? AND s.started_at >= b.bs AND s.started_at < b.be
       ' . ($pv ? "LEFT JOIN {$pv['sql']} pv ON pv.session = s.id" : '') . '
       WHERE ' . Sql::IS_VISIT . $scope['sql'] . " AND {$w['sql']}
       GROUP BY b.i",
            [...$params, $query['site'], ...($pv['params'] ?? []), ...$scope['params'], ...$w['params']],
        );
        foreach ($rows as $row) {
            $bump((int) Sql::num($row['i']), $row);
        }
        $out = [];
        foreach ($buckets as $i => $bucket) {
            $row = $sums[$i] ?? null;
            $n = Sql::num($row['n'] ?? null);
            $views = Sql::num($row['views'] ?? null);
            $out[] = [
                'start' => $bucket['start'],
                'visitors' => Sql::num($row['visitors'] ?? null),
                'visits' => $n,
                'pageviews' => $views,
                'viewsPerVisit' => $n > 0 ? self::whole(Js::round(($views / $n) * 100) / 100) : 0,
                'bounceRate' => $n > 0 ? self::whole(Sql::num($row['bounced'] ?? null) / $n) : 0,
                'visitDuration' => $n > 0 ? self::whole(Js::round(Sql::num($row['duration'] ?? null) / $n)) : 0,
            ];
        }
        return $out;
    }

    /** @return list<array<string, mixed>> BreakdownRow */
    public function breakdown(array $query, string $dimension, int $limit, int $offset): array
    {
        $page = [$limit, $offset];
        $dialect = $this->db->dialect();
        if ($dimension === 'ai_agent' || $dimension === 'ai_page') {
            $col = $dimension === 'ai_agent' ? 'e.name' : 'e.path';
            $rows = $this->db->all(
                "SELECT $col AS value, COUNT(*) AS fetches FROM rl_events e
         WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'fetch'
         GROUP BY $col ORDER BY fetches DESC, $col{$this->textOrder()} LIMIT ? OFFSET ?",
                [$query['site'], $query['from'], $query['to'], ...$page],
            );
            return array_map(static fn (array $row): array => ['value' => (string) $row['value'], 'visitors' => 0, 'fetches' => Sql::num($row['fetches'])], $rows);
        }

        $rolled = $this->rolledBreakdown($query, $dimension, $limit, $offset);
        if ($rolled !== null) {
            return $rolled;
        }

        // Filtered or not, the visits are those that started in the range (see visitScope).
        $scope = Sql::visitScope($query['filters'], $query['site'], $query['from'], $query['to'], $dialect);
        if (Query::isSessionDimension($dimension)) {
            $pv = Sql::pageviewsOf($query['filters'], $query['site'], $query['from'], $query['to'], $dialect);
            $col = 's.' . Query::SESSION_DIMENSIONS[$dimension];
            $entryExit = $dimension === 'entry' || $dimension === 'exit';
            $rows = $this->db->all(
                "SELECT $col AS value, COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits, SUM(" . ($pv ? 'COALESCE(pv.n, 0)' : 's.pageviews') . ') AS pageviews,
           SUM(CASE WHEN ' . Sql::BOUNCE . ' THEN 1 ELSE 0 END) AS bounced, SUM(' . Sql::DURATION . ') AS duration
         FROM rl_sessions s ' . ($pv ? "LEFT JOIN {$pv['sql']} pv ON pv.session = s.id" : '') . '
         WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND ' . Sql::IS_VISIT . $scope['sql'] . " AND $col <> ''
         GROUP BY $col ORDER BY " . ($entryExit ? 'visits DESC' : 'visitors DESC, visits DESC') . ", $col{$this->textOrder()} LIMIT ? OFFSET ?",
                [...($pv['params'] ?? []), $query['site'], $query['from'], $query['to'], ...$scope['params'], ...$page],
            );
            return array_map(static function (array $row) use ($entryExit): array {
                $visits = Sql::num($row['visits']);
                $out = [
                    'value' => (string) $row['value'],
                    'visitors' => Sql::num($row['visitors']),
                    'visits' => $visits,
                    'bounceRate' => $visits > 0 ? self::whole(Sql::num($row['bounced']) / $visits) : 0,
                ];
                if (!$entryExit) {
                    $out['pageviews'] = Sql::num($row['pageviews']);
                    $out['visitDuration'] = $visits > 0 ? self::whole(Js::round(Sql::num($row['duration']) / $visits)) : 0;
                }
                return $out;
            }, $rows);
        }

        // Rows from the visits that started in the range and that the filters pick, narrowed by any filter on
        // the same kind of row ("page is /pricing" on pages), as the rollups count them.
        $within = function (array $dimensions) use ($query, $scope, $dialect): array {
            $rows = Sql::rowScope($query['filters'], $dimensions, $dialect);
            return [
                'sql' => ' AND e.session IN (SELECT s.id FROM rl_sessions s WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND ' . Sql::IS_VISIT . "{$scope['sql']}){$rows['sql']}",
                'params' => [$query['site'], $query['from'], $query['to'], ...$scope['params'], ...$rows['params']],
                'to' => $query['to'] + Sql::EVENT_TAIL_MS,
            ];
        };

        if ($dimension === 'page' || $dimension === 'hostname') {
            $col = 'e.' . Query::EVENT_DIMENSIONS[$dimension];
            $w = $within(['page', 'hostname']);
            $rows = $this->db->all(
                "SELECT $col AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(*) AS pageviews, " . Sql::LIVE_VIEWS . " AS views
         FROM rl_events e
         WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'pageview'{$w['sql']}
         GROUP BY $col ORDER BY visitors DESC, pageviews DESC, $col{$this->textOrder()} LIMIT ? OFFSET ?",
                [$query['site'], $query['from'], $w['to'], ...$w['params'], ...$page],
            );
            $out = array_map(static fn (array $row): array => ['value' => (string) $row['value'], 'visitors' => Sql::num($row['visitors']), 'pageviews' => Sql::num($row['pageviews'])], $rows);
            $live = [];
            foreach ($rows as $row) {
                $live['v' . $row['value']] = Sql::num($row['views']);
            }
            if ($dimension === 'page' && $out) {
                // Each pageview's engaged time added up and its deepest scroll, then the mean over pageviews. Filters add
                // values of their own, so fewer paths go in each statement, keeping it within D1's 100.
                $size = max(1, min(Sql::VALUES_PER_QUERY, Sql::MAX_PARAMS - 3 - count($w['params'])));
                $times = Sql::inPieces($out, $size, fn (array $piece): array => $this->db->all(
                    "SELECT value, SUM(total) AS total, COUNT(*) AS views, AVG(deepest) AS scroll FROM (
               SELECT e.path AS value, SUM(e.engaged_ms) AS total, MAX(e.scroll) AS deepest
               FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'engagement'{$w['sql']}
               AND e.path IN (" . implode(', ', array_fill(0, count($piece), '?')) . ') GROUP BY e.path, e.pageview) t GROUP BY value',
                    [$query['site'], $query['from'], $w['to'], ...$w['params'], ...array_column($piece, 'value')],
                ));
                $byPath = [];
                foreach ($times as $t) {
                    $byPath['v' . $t['value']] = $t;
                }
                foreach ($out as &$row) {
                    $time = $byPath['v' . $row['value']] ?? null;
                    $views = $live['v' . $row['value']] ?? 0;
                    $row['timeOnPage'] = $time !== null && $views ? self::whole(Js::round(Sql::num($time['total']) / $views)) : 0;
                    $row['scrollDepth'] = $time === null || $time['scroll'] === null ? 0 : self::whole(Js::round(Sql::num($time['scroll'])));
                }
                unset($row);
            }
            return $out;
        }

        if ($dimension === 'event') {
            $w = $within(['event']);
            $rows = $this->db->all(
                "SELECT e.name AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(*) AS events
         FROM rl_events e
         WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'event'{$w['sql']}
         GROUP BY e.name ORDER BY visitors DESC, events DESC, e.name{$this->textOrder()} LIMIT ? OFFSET ?",
                [$query['site'], $query['from'], $w['to'], ...$w['params'], ...$page],
            );
            return array_map(static fn (array $row): array => ['value' => (string) $row['value'], 'visitors' => Sql::num($row['visitors']), 'events' => Sql::num($row['events'])], $rows);
        }

        return [];
    }

    /**
     * Visits by quarter hour since the epoch, which the caller folds into local weekdays and hours,
     * keeping time zones (DST included) out of SQL. Quarters, not hours, so a site in a
     * half-hour or 45-minute timezone (India, Nepal) folds each into the right local hour.
     *
     * @return list<array{quarter: int, visits: int, visitors: int, pageviews: int, bounced: int}>
     */
    public function hourly(array $query): array
    {
        $dialect = $this->db->dialect();
        $plan = $this->rollupPlan($query, $query['from'], $query['to']);
        if ($plan !== null) {
            $sums = [];
            $bump = function (int|float $quarter, array $row) use (&$sums): void {
                $key = (string) $quarter;
                $into = $sums[$key] ?? ['quarter' => $quarter, 'visits' => 0, 'visitors' => 0, 'pageviews' => 0, 'bounced' => 0];
                $into['visits'] += Sql::num($row['visits'] ?? null);
                $into['visitors'] += Sql::num($row['visitors'] ?? null);
                $into['pageviews'] += Sql::num($row['pageviews'] ?? null);
                $into['bounced'] += Sql::num($row['bounced'] ?? null);
                $sums[$key] = $into;
            };
            $rolled = $this->db->all(
                "SELECT value, visits, visitors, pageviews, bounced FROM rl_rollups WHERE site = ? AND dim = 'quarter' AND day IN (" . Sql::BUILT_DAYS . ')',
                [$query['site'], $query['site'], $query['from'], $query['to']],
            );
            foreach ($rolled as $row) {
                $bump(Js::number((string) $row['value']), $row);
            }
            $w = self::within($plan['rest']);
            $raw = $this->db->all(
                'SELECT ' . Sql::div($dialect, 's.started_at', 900000) . ' AS quarter, COUNT(*) AS visits, COUNT(DISTINCT s.visitor) AS visitors,
           SUM(s.pageviews) AS pageviews, SUM(CASE WHEN ' . Sql::BOUNCE . " THEN 1 ELSE 0 END) AS bounced
         FROM rl_sessions s WHERE s.site = ? AND {$w['sql']} AND " . Sql::IS_VISIT . ' GROUP BY 1',
                [$query['site'], ...$w['params']],
            );
            foreach ($raw as $row) {
                $bump(self::whole(floor(Sql::num($row['quarter']))), $row);
            }
            return array_values($sums);
        }
        $matching = Sql::visitScope($query['filters'], $query['site'], $query['from'], $query['to'], $dialect);
        // A page filter counts that page's views as pageviews here too, as the cards do.
        $pv = Sql::pageviewsOf($query['filters'], $query['site'], $query['from'], $query['to'], $dialect);
        $rows = $this->db->all(
            'SELECT ' . Sql::div($dialect, 's.started_at', 900000) . ' AS quarter, COUNT(*) AS visits, COUNT(DISTINCT s.visitor) AS visitors,
         SUM(' . ($pv ? 'COALESCE(pv.n, 0)' : 's.pageviews') . ') AS pageviews, SUM(CASE WHEN ' . Sql::BOUNCE . ' THEN 1 ELSE 0 END) AS bounced
       FROM rl_sessions s ' . ($pv ? "LEFT JOIN {$pv['sql']} pv ON pv.session = s.id" : '') . '
       WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND ' . Sql::IS_VISIT . $matching['sql'] . '
       GROUP BY 1',
            [...($pv['params'] ?? []), $query['site'], $query['from'], $query['to'], ...$matching['params']],
        );
        return array_map(static fn (array $row): array => [
            'quarter' => self::whole(floor(Sql::num($row['quarter']))),
            'visits' => Sql::num($row['visits']),
            'visitors' => Sql::num($row['visitors']),
            'pageviews' => Sql::num($row['pageviews']),
            'bounced' => Sql::num($row['bounced']),
        ], $rows);
    }

    /** @return array{visitors: int, pages: list<array{value: string, visitors: int}>, sources: list<array{value: string, visitors: int}>, countries: list<array{value: string, visitors: int}>, minutes: list<int>, recent: list<array<string, mixed>>} */
    public function realtime(string $site, int $now): array
    {
        $since = $now - 5 * 60_000;
        $active = $this->db->all(
            "SELECT COUNT(DISTINCT visitor) AS n FROM rl_events WHERE site = ? AND ts >= ? AND kind IN ('pageview', 'event', 'engagement')",
            [$site, $since],
        )[0] ?? null;
        $pages = $this->db->all(
            "SELECT path AS value, COUNT(DISTINCT visitor) AS visitors FROM rl_events
       WHERE site = ? AND ts >= ? AND kind = 'pageview' GROUP BY path ORDER BY visitors DESC, path{$this->textOrder()} LIMIT 10",
            [$site, $since],
        );
        $sources = $this->db->all(
            "SELECT s.source AS value, COUNT(DISTINCT e.visitor) AS visitors FROM rl_events e JOIN rl_sessions s ON s.id = e.session
       WHERE e.site = ? AND e.ts >= ? AND e.kind IN ('pageview', 'event') AND s.source <> ''
       GROUP BY s.source ORDER BY visitors DESC, s.source{$this->textOrder()} LIMIT 10",
            [$site, $since],
        );
        $start = (int) floor($now / 60_000) * 60_000 - 29 * 60_000;
        $perMinute = $this->db->all(
            'SELECT ' . Sql::div($this->db->dialect(), '(ts - ?)', 60000) . " AS m, COUNT(*) AS n FROM rl_events
       WHERE site = ? AND ts >= ? AND kind = 'pageview' GROUP BY 1",
            [$start, $site, $start],
        );
        $minutes = array_fill(0, 30, 0);
        foreach ($perMinute as $row) {
            $index = (int) floor(Sql::num($row['m']));
            if ($index >= 0 && $index < 30) {
                $minutes[$index] += Sql::num($row['n']);
            }
        }
        $countries = $this->db->all(
            "SELECT s.country AS value, COUNT(DISTINCT e.visitor) AS visitors FROM rl_events e JOIN rl_sessions s ON s.id = e.session
       WHERE e.site = ? AND e.ts >= ? AND e.kind IN ('pageview', 'event') AND s.country <> ''
       GROUP BY s.country ORDER BY visitors DESC, s.country{$this->textOrder()} LIMIT 10",
            [$site, $since],
        );
        $recent = $this->db->all(
            "SELECT e.ts, e.kind, e.path, e.name, s.country, s.city, s.source, s.device FROM rl_events e JOIN rl_sessions s ON s.id = e.session
       WHERE e.site = ? AND e.ts >= ? AND e.kind IN ('pageview', 'event') ORDER BY e.ts DESC, e.id DESC LIMIT 20",
            [$site, $start],
        );
        $pairs = static fn (array $rows): array => array_map(static fn (array $row): array => ['value' => (string) $row['value'], 'visitors' => Sql::num($row['visitors'])], $rows);
        return [
            'visitors' => Sql::num($active['n'] ?? null),
            'pages' => $pairs($pages),
            'sources' => $pairs($sources),
            'countries' => $pairs($countries),
            'minutes' => $minutes,
            'recent' => array_map(static fn (array $r): array => [
                'ts' => Sql::num($r['ts']),
                'kind' => (string) $r['kind'],
                'path' => (string) ($r['path'] ?? ''),
                'name' => (string) ($r['name'] ?? ''),
                'country' => (string) ($r['country'] ?? ''),
                'city' => (string) ($r['city'] ?? ''),
                'source' => (string) ($r['source'] ?? ''),
                'device' => (string) ($r['device'] ?? ''),
            ], $recent),
        ];
    }
}
