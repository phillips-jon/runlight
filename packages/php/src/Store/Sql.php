<?php

declare(strict_types=1);

namespace Runlight\Store;

use Runlight\Js;
use Runlight\Query;
use Runlight\Sources;

/**
 * The SQL that store.ts builds outside its class: the schema, filters as conditions, and the small pieces
 * every report shares. Each statement is the TypeScript one, for each dialect ("sqlite", "postgres",
 * "mysql"), so one database serves either implementation.
 *
 * A filter is array{dimension: string, op: string, value: string}. A piece of SQL with its values is
 * array{sql: string, params: list<mixed>}.
 */
final class Sql
{
    /** A session's bounce: one page, nothing clicked that was tracked, under ten seconds engaged. */
    public const BOUNCE_MS = 10_000;
    public const BOUNCE = '(s.pageviews = 1 AND s.events = 0 AND (s.engaged_ms IS NULL OR s.engaged_ms < 10000))';
    public const VISIT_KINDS = "e.kind IN ('pageview', 'event')";

    /**
     * Cloudflare D1 takes at most 100 bound parameters a statement, so lists that grow with the
     * range (chart buckets, values) go in pieces, and built days are chosen by their dates.
     */
    public const BUCKETS_PER_QUERY = 30;
    public const VALUES_PER_QUERY = 50;
    /** The most values one statement binds: D1's 100, less a little. */
    public const MAX_PARAMS = 96;
    /** The built days inside a range, as a subquery taking (site, from, to). */
    public const BUILT_DAYS = 'SELECT day FROM rl_rollup_days WHERE site = ? AND start_at >= ? AND end_at <= ?';

    /** The most visits journeys reads, newest first. */
    public const JOURNEY_VISITS = 20_000;

    /** How long after a visit starts its events are looked for: far past any real visit. */
    public const EVENT_TAIL_MS = 2 * 86_400_000;

    public const PIECE_MS = 86_400_000;

    /**
     * Pageviews that can report engaged time: the tracker's, which carry a pageview id. Imported history has
     * none, so time on page is the mean over these, counting a view that reported nothing (under a second) as none.
     */
    public const LIVE_VIEWS = "SUM(CASE WHEN e.pageview <> '' THEN 1 ELSE 0 END)";

    /** A session that is a visit: a short link click alone opens one that is not. */
    public const IS_VISIT = '(s.pageviews > 0 OR s.events > 0)';

    /** Engaged time, or for imported visits with none, first to last request. */
    public const DURATION = 'COALESCE(s.engaged_ms, s.last_at - s.started_at)';

    public const SCHEMA_VERSION = 11;

    /**
     * MySQL's text collation: UTF-8 compared and sorted by code point, case and trailing spaces included,
     * as SQLite and Postgres's "C" collation do. MariaDB has it too, from 11.4.
     */
    public const MYSQL_COLLATION = 'utf8mb4_0900_bin';

    private const PATH_DIMENSIONS = ['page', 'entry', 'exit'];

    /**
     * Orders text by code point, as SQLite and Postgres's "C" collation do (JavaScript's < compares UTF-16
     * units). UTF-8 bytes sort in code point order, so the bytes are compared.
     */
    public static function codeOrder(string $a, string $b): int
    {
        return strcmp($a, $b);
    }

    /**
     * Runs a query over pieces of a list and joins the answers, in order.
     *
     * @template T
     * @template R
     * @param list<T> $items
     * @param callable(list<T>): list<R> $run
     * @return list<R>
     */
    public static function inPieces(array $items, int $size, callable $run): array
    {
        $out = [];
        for ($i = 0; $i < count($items); $i += $size) {
            array_push($out, ...$run(array_slice($items, $i, $size)));
        }
        return $out;
    }

    /** @return list<string> */
    public static function schema(string $dialect): array
    {
        $my = $dialect === 'mysql';
        $id = $dialect === 'postgres' ? 'BIGSERIAL PRIMARY KEY' : ($my ? 'BIGINT AUTO_INCREMENT PRIMARY KEY' : 'INTEGER PRIMARY KEY AUTOINCREMENT');
        // MySQL keys and indexes TEXT only by a prefix, so there a column that is keyed, indexed, grouped, or
        // sorted is VARCHAR, sized past anything Runlight writes to it. Elsewhere text is text.
        $str = static fn (int $n): string => $my ? "VARCHAR($n)" : 'TEXT';
        $text = static fn (int $n): string => $str($n) . " NOT NULL DEFAULT ''";
        // Free text that is never keyed. MySQL takes a default for it only as an expression.
        $long = static fn (string $fallback): string => $my ? "MEDIUMTEXT NOT NULL DEFAULT ('$fallback')" : "TEXT NOT NULL DEFAULT '$fallback'";
        $table = $my ? ' DEFAULT CHARSET=utf8mb4 COLLATE=' . self::MYSQL_COLLATION : '';
        $site = $str(100);
        $key = $str(100);
        $path = 1000;
        $medium = $my ? 'MEDIUMTEXT' : 'TEXT';
        return [
            "CREATE TABLE IF NOT EXISTS rl_meta (\"key\" {$str(100)} PRIMARY KEY, value $medium NOT NULL)$table",
            "CREATE TABLE IF NOT EXISTS rl_sites (
      id $site PRIMARY KEY, name {$text(200)}, hostnames {$long('[]')},
      timezone {$str(64)} NOT NULL DEFAULT 'UTC', created_at BIGINT NOT NULL,
      overrides {$long('{}')})$table",
            "CREATE TABLE IF NOT EXISTS rl_salts (day {$str(32)} PRIMARY KEY, salt {$str(255)} NOT NULL)$table",
            "CREATE TABLE IF NOT EXISTS rl_sessions (
      id $key PRIMARY KEY, site $site NOT NULL, visitor $key NOT NULL,
      started_at BIGINT NOT NULL, last_at BIGINT NOT NULL,
      entry_path {$text($path)}, exit_path {$text($path)},
      pageviews INTEGER NOT NULL DEFAULT 0, events INTEGER NOT NULL DEFAULT 0,
      engaged_ms BIGINT, imported INTEGER NOT NULL DEFAULT 0,
      hostname {$text(255)}, referrer_host {$text(255)}, referrer_path {$text(500)},
      source {$text(200)}, channel {$text(100)},
      utm_source {$text(200)}, utm_medium {$text(200)}, utm_campaign {$text(200)}, utm_term {$text(200)}, utm_content {$text(200)},
      country {$text(16)}, region {$text(100)}, city {$text(100)},
      browser {$text(100)}, browser_version {$text(100)}, os {$text(100)}, os_version {$text(100)},
      device {$text(50)}, screen {$text(50)}, language {$text(50)})$table",
            'CREATE INDEX IF NOT EXISTS rl_sessions_site_started ON rl_sessions (site, started_at)',
            // MySQL takes an index that leads with the site as a way to read all of a site's rows, even where a
            // range of time would read far fewer, so there an index for looking a value up leads with that value.
            'CREATE INDEX IF NOT EXISTS rl_sessions_visitor ON rl_sessions (' . ($my ? 'visitor, site' : 'site, visitor') . ', last_at)',
            "CREATE TABLE IF NOT EXISTS rl_events (
      id $id, site $site NOT NULL, ts BIGINT NOT NULL, kind {$str(20)} NOT NULL,
      visitor {$text(100)}, session {$text(100)}, pageview {$text(100)},
      path {$text($path)}, hostname {$text(255)}, title {$text(500)}, name {$text(255)}, props $medium,
      engaged_ms BIGINT NOT NULL DEFAULT 0, scroll INTEGER, link {$text(100)})$table",
            'CREATE INDEX IF NOT EXISTS rl_events_site_ts ON rl_events (site, ts)',
            // Goals and events read one kind of row in a range; created on start for older databases too.
            'CREATE INDEX IF NOT EXISTS rl_events_site_kind_ts ON rl_events (site, kind, ts)',
            'CREATE INDEX IF NOT EXISTS rl_events_pageview ON rl_events (' . ($my ? 'pageview, site' : 'site, pageview') . ')',
            // Page and event filters find the visits they pick through these, rather than reading every row in the range.
            // MySQL indexes the first 255 characters of a path, which is enough to find it.
            'CREATE INDEX IF NOT EXISTS rl_events_site_path ON rl_events (' . ($my ? 'path(255), site' : 'site, path') . ', ts)',
            // MySQL has no partial index, so its index of event names holds the kind too.
            $my
                ? 'CREATE INDEX IF NOT EXISTS rl_events_site_name ON rl_events (name, site, kind, ts)'
                : "CREATE INDEX IF NOT EXISTS rl_events_site_name ON rl_events (site, name, ts) WHERE kind = 'event'",
            // Version 3: short links; "" is the app's own domain. Version 4: a slug is unique
            // across every domain, so a link whose domain is removed can fall back to the
            // app's own link path without colliding with another. MySQL has no partial index,
            // so there a generated column holds the slug of a live link only, and is unique.
            "CREATE TABLE IF NOT EXISTS rl_links (
      id $key PRIMARY KEY, site $site NOT NULL, domain {$text(255)}, slug {$str(255)} NOT NULL,
      name {$text(255)}, url {$str(4000)} NOT NULL, created_at BIGINT NOT NULL, updated_at BIGINT NOT NULL,
      deleted_at BIGINT" . ($my ? ', live_slug VARCHAR(255) AS (CASE WHEN deleted_at IS NULL THEN slug END) VIRTUAL' : '') . ")$table",
            $my
                ? 'CREATE UNIQUE INDEX IF NOT EXISTS rl_links_slug_unique ON rl_links (live_slug)'
                : 'CREATE UNIQUE INDEX IF NOT EXISTS rl_links_slug_unique ON rl_links (slug) WHERE deleted_at IS NULL',
            'CREATE INDEX IF NOT EXISTS rl_events_link ON rl_events (link, ts)',
            "CREATE TABLE IF NOT EXISTS rl_link_domains (domain {$str(255)} PRIMARY KEY, site $site NOT NULL, created_at BIGINT NOT NULL)$table",
            // Version 5: share links.
            "CREATE TABLE IF NOT EXISTS rl_shares (id $key PRIMARY KEY, site $site NOT NULL, name {$text(255)}, created_at BIGINT NOT NULL)$table",
            // Version 6: goals.
            "CREATE TABLE IF NOT EXISTS rl_goals (
      id $key PRIMARY KEY, site $site NOT NULL, name {$str(255)} NOT NULL, kind {$str(20)} NOT NULL, \"match\" {$str(1000)} NOT NULL,
      click_by {$text(20)}, value_mode {$str(20)} NOT NULL DEFAULT 'none', value " . ($my ? 'DOUBLE' : 'REAL') . " NOT NULL DEFAULT 0,
      value_prop {$text(255)}, currency {$str(10)} NOT NULL DEFAULT 'USD', created_at BIGINT NOT NULL)$table",
            // Version 7: install-wide settings (the mail service) and email report subscriptions.
            "CREATE TABLE IF NOT EXISTS rl_settings (\"key\" {$str(255)} PRIMARY KEY, value $medium NOT NULL)$table",
            "CREATE TABLE IF NOT EXISTS rl_reports (
      id $key PRIMARY KEY, site $site NOT NULL, email {$str(320)} NOT NULL, frequency {$str(20)} NOT NULL,
      lang {$str(20)} NOT NULL DEFAULT 'en', token {$str(128)} NOT NULL, origin {$text(500)},
      last_period {$text(40)}, last_sent_at BIGINT, created_at BIGINT NOT NULL)$table",
            'CREATE UNIQUE INDEX IF NOT EXISTS rl_reports_token ON rl_reports (token)',
            // Version 8: read-only API tokens, for scripts and AI assistants over MCP.
            "CREATE TABLE IF NOT EXISTS rl_tokens (
      id $key PRIMARY KEY, name {$str(255)} NOT NULL, site {$text(100)}, hash {$str(128)} NOT NULL, hint {$text(20)},
      created_at BIGINT NOT NULL, last_used_at BIGINT, scope {$str(20)} NOT NULL DEFAULT 'read')$table",
            'CREATE UNIQUE INDEX IF NOT EXISTS rl_tokens_hash ON rl_tokens (hash)',
            // Version 9: funnels.
            "CREATE TABLE IF NOT EXISTS rl_funnels (id $key PRIMARY KEY, site $site NOT NULL, name {$str(255)} NOT NULL, steps $medium NOT NULL, created_at BIGINT NOT NULL)$table",
            // Version 11: daily rollups. A day is the site's own local day; rl_rollup_days
            // says which days are built and where they begin and end.
            "CREATE TABLE IF NOT EXISTS rl_rollup_days (site $site NOT NULL, day {$str(32)} NOT NULL, start_at BIGINT NOT NULL, end_at BIGINT NOT NULL, PRIMARY KEY (site, day))$table",
            'CREATE INDEX IF NOT EXISTS rl_rollup_days_range ON rl_rollup_days (site, start_at)',
            // A value can be a whole path, longer than MySQL's keys allow, so there the rows of a day are
            // found by an index without it; a day's rows are only ever written all at once.
            "CREATE TABLE IF NOT EXISTS rl_rollups (
      site $site NOT NULL, day {$str(32)} NOT NULL, dim {$str(32)} NOT NULL, value {$text($path)},
      visitors BIGINT NOT NULL DEFAULT 0, visits BIGINT NOT NULL DEFAULT 0, pageviews BIGINT NOT NULL DEFAULT 0,
      bounced BIGINT NOT NULL DEFAULT 0, duration BIGINT NOT NULL DEFAULT 0,
      engaged BIGINT NOT NULL DEFAULT 0, views BIGINT NOT NULL DEFAULT 0, scroll_sum BIGINT NOT NULL DEFAULT 0, scroll_n BIGINT NOT NULL DEFAULT 0,
      events BIGINT NOT NULL DEFAULT 0,
      " . ($my ? 'KEY rl_rollups_day (site, dim, day)' : 'PRIMARY KEY (site, dim, day, value)') . ")$table",
        ];
    }

    /** @return array{id: string, site: string, name: string, kind: string, match: string, clickBy: string, valueMode: string, value: int|float, valueProp: string, currency: string, createdAt: int|float} */
    public static function goalRow(array $r): array
    {
        return [
            'id' => (string) $r['id'],
            'site' => (string) $r['site'],
            'name' => (string) $r['name'],
            'kind' => (string) $r['kind'],
            'match' => (string) $r['match'],
            'clickBy' => (string) ($r['click_by'] ?? ''),
            'valueMode' => (string) $r['value_mode'],
            'value' => Js::number($r['value'] ?? 0),
            'valueProp' => (string) ($r['value_prop'] ?? ''),
            'currency' => (string) ($r['currency'] ?? 'USD'),
            'createdAt' => Js::number($r['created_at']),
        ];
    }

    /** A `*` pattern as SQLite GLOB, everything else taken literally ([ and ? are GLOB's own). */
    public static function globPattern(string $pattern): string
    {
        return implode('*', array_map(static fn (string $part): string => (string) preg_replace('/[[?]/', '[$0]', $part), explode('*', $pattern)));
    }

    /** A `*` pattern as SQL LIKE, everything else taken literally. */
    public static function likePattern(string $pattern): string
    {
        return implode('%', array_map(self::escapeLike(...), explode('*', $pattern)));
    }

    /**
     * An INSERT that updates the row already there with the same key, or with `update` empty leaves it be.
     * MySQL says it its own way, and has no other unique key on these tables to trip over.
     *
     * @param list<string> $columns
     * @param list<string> $key
     * @param list<string> $update
     */
    public static function upsert(string $dialect, string $table, array $columns, array $key, array $update): string
    {
        $insert = "INSERT INTO $table (" . implode(', ', $columns) . ') VALUES (' . implode(', ', array_fill(0, count($columns), '?')) . ')';
        if ($dialect === 'mysql') {
            $set = array_map(static fn (string $c): string => "$c = " . ($update ? "VALUES($c)" : $c), $update ?: [$key[0]]);
            return "$insert ON DUPLICATE KEY UPDATE " . implode(', ', $set);
        }
        return "$insert ON CONFLICT (" . implode(', ', $key) . ') DO '
            . ($update ? 'UPDATE SET ' . implode(', ', array_map(static fn (string $c): string => "$c = excluded.$c", $update)) : 'NOTHING');
    }

    /** Whole-number division, which MySQL's `/` is not. */
    public static function div(string $dialect, string $a, int $b): string
    {
        return $dialect === 'mysql' ? "($a DIV $b)" : "($a / $b)";
    }

    /** A value as text: MySQL casts to CHAR, and has no TEXT type to cast to. */
    public static function asText(string $dialect, string $value): string
    {
        return "CAST($value AS " . ($dialect === 'mysql' ? 'CHAR' : 'TEXT') . ')';
    }

    /**
     * A table of buckets (i, bs, be) for a WITH clause. Postgres is told the first row's types; MySQL
     * and MariaDB write a table of values differently from each other, so they get a UNION of rows.
     *
     * @param list<array{start: int, end: int}> $buckets
     */
    public static function bucketTable(string $dialect, array $buckets): string
    {
        if ($dialect === 'mysql') {
            return implode(' UNION ALL ', array_map(static fn (int $i): string => $i === 0 ? 'SELECT ? AS i, ? AS bs, ? AS be' : 'SELECT ?, ?, ?', array_keys($buckets)));
        }
        $cast = $dialect === 'postgres';
        return 'VALUES ' . implode(', ', array_map(static fn (int $i): string => $cast && $i === 0 ? '(CAST(? AS INTEGER), CAST(? AS BIGINT), CAST(? AS BIGINT))' : '(?, ?, ?)', array_keys($buckets)));
    }

    /** @return array{id: string, site: string, domain: string, slug: string, name: string, url: string, createdAt: int|float, updatedAt: int|float} */
    public static function linkRow(array $row): array
    {
        return [
            'id' => (string) $row['id'],
            'site' => (string) $row['site'],
            'domain' => (string) ($row['domain'] ?? ''),
            'slug' => (string) $row['slug'],
            'name' => (string) ($row['name'] ?? ''),
            'url' => (string) $row['url'],
            'createdAt' => Js::number($row['created_at']),
            'updatedAt' => Js::number($row['updated_at']),
        ];
    }

    /** Number(value ?? 0), or 0 when that is not finite. Whole numbers come back as int. */
    public static function num(mixed $value): int|float
    {
        $n = Js::number($value ?? 0);
        if (is_float($n) && !is_finite($n)) {
            return 0;
        }
        return $n;
    }

    public static function escapeLike(string $value): string
    {
        return (string) preg_replace('/[\\\\%_]/', '\\\\$0', $value);
    }

    public static function column(string $dimension): string
    {
        return Query::isSessionDimension($dimension) ? 's.' . Query::SESSION_DIMENSIONS[$dimension] : 'e.' . Query::EVENT_DIMENSIONS[$dimension];
    }

    /** Text in the form a recorded path holds it, percent-encoded, as part of a path or as a whole one. */
    public static function asRecorded(string $value, bool $whole): string
    {
        $path = Sources::recordedPath($whole || str_starts_with($value, '/') ? $value : "/$value");
        if ($path === null) {
            return $value;
        }
        return $whole || str_starts_with($value, '/') ? $path : substr($path, 1);
    }

    /** A GLOB pattern for text containing `value` in any mix of upper and lower case, letter by letter. */
    public static function anyCase(string $value): string
    {
        $out = '*';
        foreach (mb_str_split(Js::scrub($value), 1, 'UTF-8') as $ch) {
            $lower = Js::lower($ch);
            $upper = Js::upper($ch);
            if ($lower !== $upper && mb_strlen($lower, 'UTF-8') === 1 && mb_strlen($upper, 'UTF-8') === 1) {
                $out .= "[$lower$upper]";
            } else {
                $out .= $ch === '*' || $ch === '?' || $ch === '[' ? "[$ch]" : $ch;
            }
        }
        return "$out*";
    }

    /**
     * One filter as a condition on its own column, with "is not" flipped to "is" when `positive` asks.
     *
     * @param array{dimension: string, op: string, value: string} $filter
     * @return array{sql: string, params: list<mixed>}
     */
    public static function condition(array $filter, string $dialect, bool $positive = false): array
    {
        $col = self::column($filter['dimension']);
        $op = $positive && $filter['op'] === 'not' ? 'is' : $filter['op'];
        // Paths are recorded percent-encoded, as the browser's URL parser writes them, so "/café" is matched as
        // "/caf%C3%A9", just as a goal for it is.
        $path = in_array($filter['dimension'], self::PATH_DIMENSIONS, true);
        $value = $filter['value'];
        if ($op === 'is' || $op === 'not') {
            return ['sql' => "$col " . ($op === 'is' ? '=' : '<>') . ' ?', 'params' => [$path ? self::asRecorded($value, true) : $value]];
        }
        if ($path) {
            // An encoded letter's case is in its bytes (%C3%9C is Ü, %C3%BC is ü), which no database folds, so a
            // path is also tried in lower, upper, and title case, encoded each way.
            $title = (string) preg_replace_callback(
                '/(^|[' . Js::SPACE . '\-\/_.])(\p{L})/u',
                static fn (array $m): string => $m[1] . Js::upper($m[2]),
                Js::lower($value),
            );
            $forms = array_values(array_unique(array_map(
                static fn (string $f): string => self::asRecorded($f, false),
                [$value, Js::lower($value), Js::upper($value), $title],
            )));
            $lower = $dialect !== 'sqlite';
            $one = $lower ? "LOWER($col) LIKE ? ESCAPE '\\'" : "$col LIKE ? ESCAPE '\\'";
            return [
                'sql' => '(' . implode(' OR ', array_fill(0, count($forms), $one)) . ')',
                'params' => array_map(static fn (string $f): string => '%' . self::escapeLike($lower ? Js::lower($f) : $f) . '%', $forms),
            ];
        }
        // Postgres and MySQL lower case any letter, so both sides lowered find any mix. Their LIKE then
        // compares exactly: Postgres's always, MySQL's under Runlight's binary collation.
        if ($dialect !== 'sqlite') {
            return ['sql' => "LOWER($col) LIKE ? ESCAPE '\\'", 'params' => ['%' . self::escapeLike(Js::lower($value)) . '%']];
        }
        // SQLite's LIKE and LOWER ignore case for ASCII letters only, so "über" would never find "Über". GLOB with
        // both cases of every letter finds any mix, Unicode included.
        return ['sql' => "$col GLOB ?", 'params' => [self::anyCase($value)]];
    }

    /**
     * The visits a query's filters pick, as conditions on `s`. A filter on the visit (source, country,
     * entry page) applies to it directly. A filter on a page, hostname, or event picks the visits that
     * had a matching row, or for "is not", that never had one. Every number then describes those whole
     * visits, and a visit belongs to the range it started in, as it does with no filter. Rows count up to
     * EVENT_TAIL_MS past the range, for a visit still going when it ends.
     *
     * @param list<array{dimension: string, op: string, value: string}> $filters
     * @return array{sql: string, params: list<mixed>}
     */
    public static function visitScope(array $filters, string $site, int $from, int $to, string $dialect): array
    {
        $parts = [];
        $params = [];
        foreach ($filters as $filter) {
            $c = self::condition($filter, $dialect, true);
            if (Query::isSessionDimension($filter['dimension'])) {
                $own = self::condition($filter, $dialect);
                $parts[] = $own['sql'];
                array_push($params, ...$own['params']);
            } else {
                // An event filter reads events only, which lets it use the index of event names.
                $kinds = $filter['dimension'] === 'event' ? "e.kind = 'event'" : self::VISIT_KINDS;
                $rows = "FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND $kinds AND {$c['sql']}";
                // Postgres plans NOT IN over a list too big for its memory as a scan of the list for every visit,
                // which runs for hours, so it gets NOT EXISTS, an anti join. SQLite reads NOT IN through a
                // temporary index, and runs NOT EXISTS once a visit.
                if ($filter['op'] === 'not' && $dialect === 'postgres') {
                    $parts[] = "NOT EXISTS (SELECT 1 $rows AND e.session = s.id)";
                } else {
                    $parts[] = 's.id ' . ($filter['op'] === 'not' ? 'NOT IN' : 'IN') . " (SELECT e.session $rows)";
                }
                array_push($params, $site, $from, $to + self::EVENT_TAIL_MS, ...$c['params']);
            }
        }
        return ['sql' => implode('', array_map(static fn (string $p): string => " AND $p", $parts)), 'params' => $params];
    }

    /**
     * Conditions on `e` from the filters on the given row dimensions that keep rows (is, contains). With
     * "page is /pricing", pageviews mean views of /pricing, as people expect, while the visits are whole.
     * A row counts when it matches any filter on each of its dimensions: two page filters count the views
     * of either page, and a hostname filter beside them keeps those on that host.
     *
     * @param list<array{dimension: string, op: string, value: string}> $filters
     * @param list<string> $dimensions
     * @return array{sql: string, params: list<mixed>}
     */
    public static function rowScope(array $filters, array $dimensions, string $dialect): array
    {
        $sql = '';
        $params = [];
        foreach ($dimensions as $dimension) {
            $kept = [];
            foreach ($filters as $f) {
                if ($f['dimension'] === $dimension && $f['op'] !== 'not') {
                    $kept[] = self::condition($f, $dialect);
                }
            }
            if (!$kept) {
                continue;
            }
            $sql .= ' AND (' . implode(' OR ', array_column($kept, 'sql')) . ')';
            foreach ($kept as $c) {
                array_push($params, ...$c['params']);
            }
        }
        return ['sql' => $sql, 'params' => $params];
    }

    /**
     * Pageviews for each visit a filter picks, as a table to LEFT JOIN on `pv.session = s.id`, when a page or
     * hostname filter narrows what counts as a pageview. Null when every pageview of a visit counts.
     *
     * @param list<array{dimension: string, op: string, value: string}> $filters
     * @return array{sql: string, params: list<mixed>}|null
     */
    public static function pageviewsOf(array $filters, string $site, int $from, int $to, string $dialect): ?array
    {
        $rows = self::rowScope($filters, ['page', 'hostname'], $dialect);
        if ($rows['sql'] === '') {
            return null;
        }
        return [
            'sql' => "(SELECT e.session AS session, COUNT(*) AS n FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'pageview'{$rows['sql']} GROUP BY e.session)",
            'params' => [$site, $from, $to + self::EVENT_TAIL_MS, ...$rows['params']],
        ];
    }

    /**
     * For reports that count rows (goals, event properties, funnels): the rows of the visits a query picks,
     * as a FROM list and conditions over `e` and `s`. These count visits the way every other report does,
     * with or without a filter: a visit belongs to the range it started in, and its rows count up to
     * EVENT_TAIL_MS past the range. Written as a CROSS JOIN so SQLite reads the events through their (site,
     * kind, ts) index and looks each visit up by its id, whatever its statistics say.
     *
     * @param list<array{dimension: string, op: string, value: string}> $filters
     * @return array{from: string, sql: string, params: list<mixed>}
     */
    public static function visitRows(array $filters, string $site, int $from, int $to, string $dialect): array
    {
        $scope = self::visitScope($filters, $site, $from, $to, $dialect);
        return [
            'from' => 'rl_events e CROSS JOIN rl_sessions s',
            'sql' => 'e.site = ? AND e.ts >= ? AND e.ts < ? AND s.id = e.session AND s.site = ? AND s.started_at >= ? AND s.started_at < ? AND ' . self::IS_VISIT . $scope['sql'],
            'params' => [$site, $from, $to + self::EVENT_TAIL_MS, $site, $from, $to, ...$scope['params']],
        ];
    }
}
