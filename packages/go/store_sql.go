package runlight

import (
	"fmt"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

// BounceMs: a session's bounce is one page, nothing clicked that was
// tracked, under ten seconds engaged.
const BounceMs = 10_000

var bounce = fmt.Sprintf("(s.pageviews = 1 AND s.events = 0 AND (s.engaged_ms IS NULL OR s.engaged_ms < %d))", BounceMs)

const visitKinds = "e.kind IN ('pageview', 'event')"

// Cloudflare D1 takes at most 100 bound parameters a statement, so lists
// that grow with the range (chart buckets, values) go in pieces, and built
// days are chosen by their dates.
const (
	bucketsPerQuery = 30
	valuesPerQuery  = 50
	// maxParams is the most values one statement binds: D1's 100, less a little.
	maxParams = 96
)

// builtDays is the built days inside a range, as a subquery taking (site, from, to).
const builtDays = "SELECT day FROM rl_rollup_days WHERE site = ? AND start_at >= ? AND end_at <= ?"

// JourneyVisits is the most visits journeys reads, newest first.
const JourneyVisits = 20_000

// EventTailMs is how long after a visit starts its events are looked for: far past any real visit.
const EventTailMs = 2 * 86_400_000

const pieceMs = 86_400_000

// liveViews are pageviews that can report engaged time: the tracker's,
// which carry a pageview id. Imported history has none, so time on page is
// the mean over these, counting a view that reported nothing (under a
// second) as none.
const liveViews = "SUM(CASE WHEN e.pageview <> '' THEN 1 ELSE 0 END)"

// isVisit is a session that is a visit: a short link click alone opens one that is not.
const isVisit = "(s.pageviews > 0 OR s.events > 0)"

// duration is engaged time, or for imported visits with none, first to last request.
const duration = "COALESCE(s.engaged_ms, s.last_at - s.started_at)"

const schemaVersion = 11

// MySQLCollation is MySQL's text collation: UTF-8 compared and sorted by
// code point, case and trailing spaces included, as SQLite and Postgres's
// "C" collation do. MariaDB has it too, from 11.4.
const MySQLCollation = "utf8mb4_0900_bin"

func schema(dialect string) []string {
	my := dialect == "mysql"
	id := "INTEGER PRIMARY KEY AUTOINCREMENT"
	if dialect == "postgres" {
		id = "BIGSERIAL PRIMARY KEY"
	} else if my {
		id = "BIGINT AUTO_INCREMENT PRIMARY KEY"
	}
	// MySQL keys and indexes TEXT only by a prefix, so there a column that is keyed, indexed, grouped, or
	// sorted is VARCHAR, sized past anything Runlight writes to it. Elsewhere text is text.
	strCol := func(n int) string {
		if my {
			return fmt.Sprintf("VARCHAR(%d)", n)
		}
		return "TEXT"
	}
	text := func(n int) string { return strCol(n) + " NOT NULL DEFAULT ''" }
	// Free text that is never keyed. MySQL takes a default for it only as an expression.
	long := func(fallback string) string {
		if my {
			return fmt.Sprintf("MEDIUMTEXT NOT NULL DEFAULT ('%s')", fallback)
		}
		return fmt.Sprintf("TEXT NOT NULL DEFAULT '%s'", fallback)
	}
	medium := "TEXT"
	table := ""
	real := "REAL"
	if my {
		medium = "MEDIUMTEXT"
		table = " DEFAULT CHARSET=utf8mb4 COLLATE=" + MySQLCollation
		real = "DOUBLE"
	}
	site := strCol(100)
	key := strCol(100)
	const path = 1000
	pick := func(cond bool, a, b string) string {
		if cond {
			return a
		}
		return b
	}
	return []string{
		fmt.Sprintf(`CREATE TABLE IF NOT EXISTS rl_meta ("key" %s PRIMARY KEY, value %s NOT NULL)%s`, strCol(100), medium, table),
		`CREATE TABLE IF NOT EXISTS rl_sites (
      id ` + site + ` PRIMARY KEY, name ` + text(200) + `, hostnames ` + long("[]") + `,
      timezone ` + strCol(64) + ` NOT NULL DEFAULT 'UTC', created_at BIGINT NOT NULL,
      overrides ` + long("{}") + `)` + table,
		`CREATE TABLE IF NOT EXISTS rl_salts (day ` + strCol(32) + ` PRIMARY KEY, salt ` + strCol(255) + ` NOT NULL)` + table,
		`CREATE TABLE IF NOT EXISTS rl_sessions (
      id ` + key + ` PRIMARY KEY, site ` + site + ` NOT NULL, visitor ` + key + ` NOT NULL,
      started_at BIGINT NOT NULL, last_at BIGINT NOT NULL,
      entry_path ` + text(path) + `, exit_path ` + text(path) + `,
      pageviews INTEGER NOT NULL DEFAULT 0, events INTEGER NOT NULL DEFAULT 0,
      engaged_ms BIGINT, imported INTEGER NOT NULL DEFAULT 0,
      hostname ` + text(255) + `, referrer_host ` + text(255) + `, referrer_path ` + text(500) + `,
      source ` + text(200) + `, channel ` + text(100) + `,
      utm_source ` + text(200) + `, utm_medium ` + text(200) + `, utm_campaign ` + text(200) + `, utm_term ` + text(200) + `, utm_content ` + text(200) + `,
      country ` + text(16) + `, region ` + text(100) + `, city ` + text(100) + `,
      browser ` + text(100) + `, browser_version ` + text(100) + `, os ` + text(100) + `, os_version ` + text(100) + `,
      device ` + text(50) + `, screen ` + text(50) + `, language ` + text(50) + `)` + table,
		`CREATE INDEX IF NOT EXISTS rl_sessions_site_started ON rl_sessions (site, started_at)`,
		// MySQL takes an index that leads with the site as a way to read all of a site's rows, even where a
		// range of time would read far fewer, so there an index for looking a value up leads with that value.
		`CREATE INDEX IF NOT EXISTS rl_sessions_visitor ON rl_sessions (` + pick(my, "visitor, site", "site, visitor") + `, last_at)`,
		`CREATE TABLE IF NOT EXISTS rl_events (
      id ` + id + `, site ` + site + ` NOT NULL, ts BIGINT NOT NULL, kind ` + strCol(20) + ` NOT NULL,
      visitor ` + text(100) + `, session ` + text(100) + `, pageview ` + text(100) + `,
      path ` + text(path) + `, hostname ` + text(255) + `, title ` + text(500) + `, name ` + text(255) + `, props ` + medium + `,
      engaged_ms BIGINT NOT NULL DEFAULT 0, scroll INTEGER, link ` + text(100) + `)` + table,
		`CREATE INDEX IF NOT EXISTS rl_events_site_ts ON rl_events (site, ts)`,
		// Goals and events read one kind of row in a range; created on start for older databases too.
		`CREATE INDEX IF NOT EXISTS rl_events_site_kind_ts ON rl_events (site, kind, ts)`,
		`CREATE INDEX IF NOT EXISTS rl_events_pageview ON rl_events (` + pick(my, "pageview, site", "site, pageview") + `)`,
		// Page and event filters find the visits they pick through these, rather than reading every row in the range.
		// MySQL indexes the first 255 characters of a path, which is enough to find it.
		`CREATE INDEX IF NOT EXISTS rl_events_site_path ON rl_events (` + pick(my, "path(255), site", "site, path") + `, ts)`,
		// MySQL has no partial index, so its index of event names holds the kind too.
		pick(my, `CREATE INDEX IF NOT EXISTS rl_events_site_name ON rl_events (name, site, kind, ts)`,
			`CREATE INDEX IF NOT EXISTS rl_events_site_name ON rl_events (site, name, ts) WHERE kind = 'event'`),
		// Version 3: short links; "" is the app's own domain. Version 4: a slug is unique
		// across every domain, so a link whose domain is removed can fall back to the
		// app's own link path without colliding with another. MySQL has no partial index,
		// so there a generated column holds the slug of a live link only, and is unique.
		`CREATE TABLE IF NOT EXISTS rl_links (
      id ` + key + ` PRIMARY KEY, site ` + site + ` NOT NULL, domain ` + text(255) + `, slug ` + strCol(255) + ` NOT NULL,
      name ` + text(255) + `, url ` + strCol(4000) + ` NOT NULL, created_at BIGINT NOT NULL, updated_at BIGINT NOT NULL,
      deleted_at BIGINT` + pick(my, ", live_slug VARCHAR(255) AS (CASE WHEN deleted_at IS NULL THEN slug END) VIRTUAL", "") + `)` + table,
		pick(my, `CREATE UNIQUE INDEX IF NOT EXISTS rl_links_slug_unique ON rl_links (live_slug)`,
			`CREATE UNIQUE INDEX IF NOT EXISTS rl_links_slug_unique ON rl_links (slug) WHERE deleted_at IS NULL`),
		`CREATE INDEX IF NOT EXISTS rl_events_link ON rl_events (link, ts)`,
		`CREATE TABLE IF NOT EXISTS rl_link_domains (domain ` + strCol(255) + ` PRIMARY KEY, site ` + site + ` NOT NULL, created_at BIGINT NOT NULL)` + table,
		// Version 5: share links.
		`CREATE TABLE IF NOT EXISTS rl_shares (id ` + key + ` PRIMARY KEY, site ` + site + ` NOT NULL, name ` + text(255) + `, created_at BIGINT NOT NULL)` + table,
		// Version 6: goals.
		`CREATE TABLE IF NOT EXISTS rl_goals (
      id ` + key + ` PRIMARY KEY, site ` + site + ` NOT NULL, name ` + strCol(255) + ` NOT NULL, kind ` + strCol(20) + ` NOT NULL, "match" ` + strCol(1000) + ` NOT NULL,
      click_by ` + text(20) + `, value_mode ` + strCol(20) + ` NOT NULL DEFAULT 'none', value ` + real + ` NOT NULL DEFAULT 0,
      value_prop ` + text(255) + `, currency ` + strCol(10) + ` NOT NULL DEFAULT 'USD', created_at BIGINT NOT NULL)` + table,
		// Version 7: install-wide settings (the mail service) and email report subscriptions.
		`CREATE TABLE IF NOT EXISTS rl_settings ("key" ` + strCol(255) + ` PRIMARY KEY, value ` + medium + ` NOT NULL)` + table,
		`CREATE TABLE IF NOT EXISTS rl_reports (
      id ` + key + ` PRIMARY KEY, site ` + site + ` NOT NULL, email ` + strCol(320) + ` NOT NULL, frequency ` + strCol(20) + ` NOT NULL,
      lang ` + strCol(20) + ` NOT NULL DEFAULT 'en', token ` + strCol(128) + ` NOT NULL, origin ` + text(500) + `,
      last_period ` + text(40) + `, last_sent_at BIGINT, created_at BIGINT NOT NULL)` + table,
		`CREATE UNIQUE INDEX IF NOT EXISTS rl_reports_token ON rl_reports (token)`,
		// Version 8: read-only API tokens, for scripts and AI assistants over MCP.
		`CREATE TABLE IF NOT EXISTS rl_tokens (
      id ` + key + ` PRIMARY KEY, name ` + strCol(255) + ` NOT NULL, site ` + text(100) + `, hash ` + strCol(128) + ` NOT NULL, hint ` + text(20) + `,
      created_at BIGINT NOT NULL, last_used_at BIGINT, scope ` + strCol(20) + ` NOT NULL DEFAULT 'read')` + table,
		`CREATE UNIQUE INDEX IF NOT EXISTS rl_tokens_hash ON rl_tokens (hash)`,
		// Version 9: funnels.
		`CREATE TABLE IF NOT EXISTS rl_funnels (id ` + key + ` PRIMARY KEY, site ` + site + ` NOT NULL, name ` + strCol(255) + ` NOT NULL, steps ` + medium + ` NOT NULL, created_at BIGINT NOT NULL)` + table,
		// Version 11: daily rollups. A day is the site's own local day; rl_rollup_days
		// says which days are built and where they begin and end.
		`CREATE TABLE IF NOT EXISTS rl_rollup_days (site ` + site + ` NOT NULL, day ` + strCol(32) + ` NOT NULL, start_at BIGINT NOT NULL, end_at BIGINT NOT NULL, PRIMARY KEY (site, day))` + table,
		`CREATE INDEX IF NOT EXISTS rl_rollup_days_range ON rl_rollup_days (site, start_at)`,
		// A value can be a whole path, longer than MySQL's keys allow, so there the rows of a day are
		// found by an index without it; a day's rows are only ever written all at once.
		`CREATE TABLE IF NOT EXISTS rl_rollups (
      site ` + site + ` NOT NULL, day ` + strCol(32) + ` NOT NULL, dim ` + strCol(32) + ` NOT NULL, value ` + text(path) + `,
      visitors BIGINT NOT NULL DEFAULT 0, visits BIGINT NOT NULL DEFAULT 0, pageviews BIGINT NOT NULL DEFAULT 0,
      bounced BIGINT NOT NULL DEFAULT 0, duration BIGINT NOT NULL DEFAULT 0,
      engaged BIGINT NOT NULL DEFAULT 0, views BIGINT NOT NULL DEFAULT 0, scroll_sum BIGINT NOT NULL DEFAULT 0, scroll_n BIGINT NOT NULL DEFAULT 0,
      events BIGINT NOT NULL DEFAULT 0,
      ` + pick(my, "KEY rl_rollups_day (site, dim, day)", "PRIMARY KEY (site, dim, day, value)") + `)` + table,
	}
}

// globPattern is a * pattern as SQLite GLOB, everything else taken literally ([ and ? are GLOB's own).
func globPattern(pattern string) string {
	parts := strings.Split(pattern, "*")
	for i, part := range parts {
		var b strings.Builder
		for _, c := range part {
			if c == '[' || c == '?' {
				b.WriteString("[" + string(c) + "]")
			} else {
				b.WriteRune(c)
			}
		}
		parts[i] = b.String()
	}
	return strings.Join(parts, "*")
}

// likePattern is a * pattern as SQL LIKE, everything else taken literally.
func likePattern(pattern string) string {
	parts := strings.Split(pattern, "*")
	for i, part := range parts {
		parts[i] = escapeLike(part)
	}
	return strings.Join(parts, "%")
}

var likeSpecial = strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)

func escapeLike(value string) string { return likeSpecial.Replace(value) }

// upsert is an INSERT that updates the row already there with the same key,
// or with update empty leaves it be. MySQL says it its own way.
func upsert(dialect, table string, columns, key, update []string) string {
	marks := make([]string, len(columns))
	for i := range marks {
		marks[i] = "?"
	}
	insert := fmt.Sprintf("INSERT INTO %s (%s) VALUES (%s)", table, strings.Join(columns, ", "), strings.Join(marks, ", "))
	if dialect == "mysql" {
		sets := []string{}
		if len(update) > 0 {
			for _, c := range update {
				sets = append(sets, fmt.Sprintf("%s = VALUES(%s)", c, c))
			}
		} else {
			sets = append(sets, fmt.Sprintf("%s = %s", key[0], key[0]))
		}
		return insert + " ON DUPLICATE KEY UPDATE " + strings.Join(sets, ", ")
	}
	if len(update) == 0 {
		return insert + " ON CONFLICT (" + strings.Join(key, ", ") + ") DO NOTHING"
	}
	sets := []string{}
	for _, c := range update {
		sets = append(sets, fmt.Sprintf("%s = excluded.%s", c, c))
	}
	return insert + " ON CONFLICT (" + strings.Join(key, ", ") + ") DO UPDATE SET " + strings.Join(sets, ", ")
}

// div is whole-number division, which MySQL's / is not.
func div(dialect, a string, b int) string {
	if dialect == "mysql" {
		return fmt.Sprintf("(%s DIV %d)", a, b)
	}
	return fmt.Sprintf("(%s / %d)", a, b)
}

// asText is a value as text: MySQL casts to CHAR, and has no TEXT type to cast to.
func asText(dialect, value string) string {
	if dialect == "mysql" {
		return "CAST(" + value + " AS CHAR)"
	}
	return "CAST(" + value + " AS TEXT)"
}

// bucketTable is a table of buckets (i, bs, be) for a WITH clause. Postgres
// is told the first row's types; MySQL and MariaDB write a table of values
// differently from each other, so they get a UNION of rows.
func bucketTable(dialect string, buckets []Bucket) string {
	parts := make([]string, len(buckets))
	if dialect == "mysql" {
		for i := range buckets {
			if i == 0 {
				parts[i] = "SELECT ? AS i, ? AS bs, ? AS be"
			} else {
				parts[i] = "SELECT ?, ?, ?"
			}
		}
		return strings.Join(parts, " UNION ALL ")
	}
	for i := range buckets {
		if dialect == "postgres" && i == 0 {
			parts[i] = "(CAST(? AS INTEGER), CAST(? AS BIGINT), CAST(? AS BIGINT))"
		} else {
			parts[i] = "(?, ?, ?)"
		}
	}
	return "VALUES " + strings.Join(parts, ", ")
}

func bucketParams(buckets []Bucket) []any {
	out := make([]any, 0, 3*len(buckets))
	for i, b := range buckets {
		out = append(out, int64(i), b.Start, b.End)
	}
	return out
}

func column(dimension string) string {
	if c, ok := lookupDimension(sessionDimensions, dimension); ok {
		return "s." + c
	}
	c, _ := lookupDimension(eventDimensions, dimension)
	return "e." + c
}

func sessionColumn(dimension string) string {
	c, _ := lookupDimension(sessionDimensions, dimension)
	return c
}

var pathDimensions = map[string]bool{"page": true, "entry": true, "exit": true}

// asRecorded is text in the form a recorded path holds it, percent-encoded,
// as part of a path or as a whole one.
func asRecorded(value string, whole bool) string {
	input := value
	if !whole && !strings.HasPrefix(value, "/") {
		input = "/" + value
	}
	path, ok := RecordedPath(input)
	if !ok {
		return value
	}
	if whole || strings.HasPrefix(value, "/") {
		return path
	}
	return path[1:]
}

// anyCase is a GLOB pattern for text containing value in any mix of upper
// and lower case, letter by letter.
func anyCase(value string) string {
	var b strings.Builder
	b.WriteByte('*')
	for _, ch := range value {
		c := string(ch)
		l, u := lower(c), upper(c)
		if l != u && utf8.RuneCountInString(l) == 1 && utf8.RuneCountInString(u) == 1 {
			b.WriteString("[" + l + u + "]")
		} else if ch == '*' || ch == '?' || ch == '[' {
			b.WriteString("[" + c + "]")
		} else {
			b.WriteString(c)
		}
	}
	b.WriteByte('*')
	return b.String()
}

type sqlPart struct {
	sql    string
	params []any
}

var titleWord = regexp.MustCompile(`(^|[\t\n\v\f\r \x{a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}\x{feff}\-/_.])(\pL)`)

// titleCase is lower-cased text with every word's first letter upper-cased.
func titleCase(value string) string {
	return titleWord.ReplaceAllStringFunc(lower(value), func(m string) string {
		r, size := utf8.DecodeLastRuneInString(m)
		if !unicode.IsLetter(r) {
			return m
		}
		return m[:len(m)-size] + upper(string(r))
	})
}

// condition is one filter as a condition on its own column, with "is not"
// flipped to "is" when positive asks.
func condition(filter Filter, dialect string, positive bool) sqlPart {
	col := column(filter.Dimension)
	op := filter.Op
	if positive && op == "not" {
		op = "is"
	}
	// Paths are recorded percent-encoded, as the browser's URL parser writes them, so "/café" is matched as
	// "/caf%C3%A9", just as a goal for it is.
	path := pathDimensions[filter.Dimension]
	if op == "is" || op == "not" {
		cmp := "="
		if op == "not" {
			cmp = "<>"
		}
		value := filter.Value
		if path {
			value = asRecorded(filter.Value, true)
		}
		return sqlPart{col + " " + cmp + " ?", []any{value}}
	}
	if path {
		// An encoded letter's case is in its bytes (%C3%9C is Ü, %C3%BC is ü), which no database folds, so a
		// path is also tried in lower, upper, and title case, encoded each way.
		forms := []string{}
		seen := map[string]bool{}
		for _, f := range []string{filter.Value, lower(filter.Value), upper(filter.Value), titleCase(filter.Value)} {
			r := asRecorded(f, false)
			if !seen[r] {
				seen[r] = true
				forms = append(forms, r)
			}
		}
		lowered := dialect != "sqlite"
		one := col + ` LIKE ? ESCAPE '\'`
		if lowered {
			one = "LOWER(" + col + `) LIKE ? ESCAPE '\'`
		}
		sqls := make([]string, len(forms))
		params := make([]any, len(forms))
		for i, f := range forms {
			sqls[i] = one
			if lowered {
				f = lower(f)
			}
			params[i] = "%" + escapeLike(f) + "%"
		}
		return sqlPart{"(" + strings.Join(sqls, " OR ") + ")", params}
	}
	// Postgres and MySQL lower case any letter, so both sides lowered find any mix. Their LIKE then
	// compares exactly: Postgres's always, MySQL's under Runlight's binary collation.
	if dialect != "sqlite" {
		return sqlPart{"LOWER(" + col + `) LIKE ? ESCAPE '\'`, []any{"%" + escapeLike(lower(filter.Value)) + "%"}}
	}
	// SQLite's LIKE and LOWER ignore case for ASCII letters only, so "über" would never find "Über". GLOB with
	// both cases of every letter finds any mix, Unicode included.
	return sqlPart{col + " GLOB ?", []any{anyCase(filter.Value)}}
}

// visitScope is the visits a query's filters pick, as conditions on s. A
// filter on the visit (source, country, entry page) applies to it directly.
// A filter on a page, hostname, or event picks the visits that had a
// matching row, or for "is not", that never had one. Every number then
// describes those whole visits, and a visit belongs to the range it started
// in, as it does with no filter. Rows count up to EventTailMs past the
// range, for a visit still going when it ends.
func visitScope(filters []Filter, site string, from, to int64, dialect string) sqlPart {
	var sql strings.Builder
	params := []any{}
	for _, filter := range filters {
		c := condition(filter, dialect, true)
		if IsSessionDimension(filter.Dimension) {
			own := condition(filter, dialect, false)
			sql.WriteString(" AND " + own.sql)
			params = append(params, own.params...)
			continue
		}
		// An event filter reads events only, which lets it use the index of event names.
		kinds := visitKinds
		if filter.Dimension == "event" {
			kinds = "e.kind = 'event'"
		}
		rows := "FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND " + kinds + " AND " + c.sql
		// Postgres plans NOT IN over a list too big for its memory as a scan of the list for every visit,
		// which runs for hours, so it gets NOT EXISTS, an anti join. SQLite reads NOT IN through a
		// temporary index, and runs NOT EXISTS once a visit.
		if filter.Op == "not" && dialect == "postgres" {
			sql.WriteString(" AND NOT EXISTS (SELECT 1 " + rows + " AND e.session = s.id)")
		} else {
			in := "IN"
			if filter.Op == "not" {
				in = "NOT IN"
			}
			sql.WriteString(" AND s.id " + in + " (SELECT e.session " + rows + ")")
		}
		params = append(params, site, from, to+EventTailMs)
		params = append(params, c.params...)
	}
	return sqlPart{sql.String(), params}
}

// rowScope is conditions on e from the filters on the given row dimensions
// that keep rows (is, contains). A row counts when it matches any filter on
// each of its dimensions.
func rowScope(filters []Filter, dimensions []string, dialect string) sqlPart {
	var sql strings.Builder
	params := []any{}
	for _, dimension := range dimensions {
		kept := []sqlPart{}
		for _, f := range filters {
			if f.Dimension == dimension && f.Op != "not" {
				kept = append(kept, condition(f, dialect, false))
			}
		}
		if len(kept) == 0 {
			continue
		}
		sqls := make([]string, len(kept))
		for i, c := range kept {
			sqls[i] = c.sql
			params = append(params, c.params...)
		}
		sql.WriteString(" AND (" + strings.Join(sqls, " OR ") + ")")
	}
	return sqlPart{sql.String(), params}
}

// pageviewsOf is the pageviews of each visit a filter picks, as a table to
// LEFT JOIN on pv.session = s.id, when a page or hostname filter narrows
// what counts as a pageview. Nil when every pageview of a visit counts.
func pageviewsOf(filters []Filter, site string, from, to int64, dialect string) *sqlPart {
	rows := rowScope(filters, []string{"page", "hostname"}, dialect)
	if rows.sql == "" {
		return nil
	}
	return &sqlPart{
		"(SELECT e.session AS session, COUNT(*) AS n FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'pageview'" + rows.sql + " GROUP BY e.session)",
		append([]any{site, from, to + EventTailMs}, rows.params...),
	}
}

type visitRowsPart struct {
	from   string
	sql    string
	params []any
}

// visitRows is, for reports that count rows (goals, event properties,
// funnels), the rows of the visits a query picks, as a FROM list and
// conditions over e and s. Written as a CROSS JOIN so SQLite reads the
// events through their (site, kind, ts) index and looks each visit up by
// its id, whatever its statistics say.
func visitRows(filters []Filter, site string, from, to int64, dialect string) visitRowsPart {
	scope := visitScope(filters, site, from, to, dialect)
	return visitRowsPart{
		"rl_events e CROSS JOIN rl_sessions s",
		"e.site = ? AND e.ts >= ? AND e.ts < ? AND s.id = e.session AND s.site = ? AND s.started_at >= ? AND s.started_at < ? AND " + isVisit + scope.sql,
		append([]any{site, from, to + EventTailMs, site, from, to}, scope.params...),
	}
}

func placeholders(n int) string {
	marks := make([]string, n)
	for i := range marks {
		marks[i] = "?"
	}
	return strings.Join(marks, ", ")
}
