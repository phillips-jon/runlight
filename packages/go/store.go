package runlight

import (
	"context"
	"fmt"
	"math"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"

	"runlight.sh/go/internal/js"
)

// Store keeps Runlight's tables (all prefixed rl_) in a SQL database, so the
// database can be the app's own. It is the TypeScript SDK's SqlStore, and
// writes the same rows, so either can read the other's database.
type Store struct {
	db Db

	mu    sync.Mutex
	ready bool
}

// NewStore is a store over a Db: SQLite(db), Postgres(db), or MySQL(db).
func NewStore(db Db) *Store { return &Store{db: db} }

// DB is the database the store keeps its tables in.
func (s *Store) DB() Db { return s.db }

func (s *Store) dialect() string { return s.db.Dialect() }

func (s *Store) metered() bool {
	m, ok := s.db.(Metered)
	return ok && m.Metered()
}

// Migrate creates the tables on first use. Safe to call any number of times.
func (s *Store) Migrate(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ready {
		return nil
	}
	create := func(db Db) error {
		// On Postgres an index on a big table takes a while to build, so the build may run past the
		// statement timeout, and goes CONCURRENTLY, so another process still serving keeps writing meanwhile.
		postgres := db.Dialect() == "postgres"
		if postgres {
			if err := db.Run(ctx, "SET statement_timeout = 0"); err != nil {
				return err
			}
			defer db.Run(context.WithoutCancel(ctx), "RESET statement_timeout")
		}
		return s.upgrade(ctx, db, postgres)
	}
	var err error
	if ex, ok := s.db.(Exclusiver); ok {
		err = ex.Exclusive(ctx, create)
	} else {
		err = create(s.db)
	}
	if err == nil {
		s.ready = true
	}
	return err
}

var (
	createIndex        = regexp.MustCompile(`^CREATE (UNIQUE )?INDEX IF NOT EXISTS (\w+) ON (\w+)`)
	duplicateColumn    = regexp.MustCompile(`(?i)duplicate column|already exists`)
	createIndexIfNotEx = regexp.MustCompile(`^CREATE (UNIQUE )?INDEX IF NOT EXISTS`)
)

func (s *Store) upgrade(ctx context.Context, db Db, postgres bool) error {
	statements := schema(db.Dialect())
	if err := db.Run(ctx, statements[0]); err != nil {
		return err
	}
	found, err := db.All(ctx, `SELECT value FROM rl_meta WHERE "key" = 'schema'`)
	if err != nil {
		return err
	}
	from := float64(schemaVersion)
	if len(found) > 0 {
		from = js.Number(str(found[0]["value"]))
	}
	if postgres {
		// A concurrent build that was stopped leaves its index unusable; it goes, and is built again below.
		broken, err := db.All(ctx, `SELECT c.relname AS name FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
           WHERE NOT i.indisvalid AND c.relname LIKE 'rl\_%' AND c.relnamespace = current_schema()::regnamespace`)
		if err != nil {
			return err
		}
		for _, b := range broken {
			if err := db.Run(ctx, `DROP INDEX IF EXISTS "`+strings.ReplaceAll(str(b["name"]), `"`, "")+`"`); err != nil {
				return err
			}
		}
	}
	for _, statement := range statements {
		index := createIndex.FindStringSubmatch(statement)
		if index != nil && db.Dialect() == "mysql" {
			// MySQL has no CREATE INDEX IF NOT EXISTS, so it is looked for first.
			there, err := db.All(ctx, `SELECT 1 AS there FROM information_schema.statistics WHERE table_schema = DATABASE() AND table_name = ? AND index_name = ? LIMIT 1`, index[3], index[2])
			if err != nil {
				return err
			}
			if len(there) == 0 {
				if err := db.Run(ctx, createIndexIfNotEx.ReplaceAllString(statement, "CREATE ${1}INDEX")); err != nil {
					return err
				}
			}
			continue
		}
		if postgres {
			statement = createIndexIfNotEx.ReplaceAllString(statement, "CREATE ${1}INDEX CONCURRENTLY IF NOT EXISTS")
		}
		if err := db.Run(ctx, statement); err != nil {
			return err
		}
	}
	// A column added by an upgrade that stopped before it recorded the new version is already there.
	addColumn := func(sql string) error {
		if err := db.Run(ctx, sql); err != nil && !duplicateColumn.MatchString(err.Error()) {
			return err
		}
		return nil
	}
	// Version 2: settings changed in the dashboard, kept apart from the ones in code.
	if from < 2 {
		if err := addColumn(`ALTER TABLE rl_sites ADD COLUMN overrides TEXT NOT NULL DEFAULT '{}'`); err != nil {
			return err
		}
	}
	if from < 4 {
		if err := db.Run(ctx, `DROP INDEX IF EXISTS rl_links_slug`); err != nil {
			return err
		}
	}
	// Version 10: tokens that may change one site's settings, for a hub.
	if from >= 8 && from < 10 {
		if err := addColumn(`ALTER TABLE rl_tokens ADD COLUMN scope TEXT NOT NULL DEFAULT 'read'`); err != nil {
			return err
		}
	}
	// Written only when it changes, so a database opened read-only can still be read.
	if len(found) == 0 || str(found[0]["value"]) != strconv.Itoa(schemaVersion) {
		return db.Run(ctx, upsert(db.Dialect(), "rl_meta", []string{`"key"`, "value"}, []string{`"key"`}, []string{"value"}), "schema", strconv.Itoa(schemaVersion))
	}
	return nil
}

// Optimize keeps SQLite's planner statistics current, which it never
// gathers by itself. A sample of each index is enough, so this takes
// milliseconds even on a large database. Postgres gathers its own.
func (s *Store) Optimize(ctx context.Context, onlyWhenMissing bool) {
	if s.dialect() != "sqlite" {
		return
	}
	// Some hosted SQLite services refuse these, and gather statistics themselves.
	if onlyWhenMissing {
		rows, err := s.db.All(ctx, `SELECT name FROM sqlite_master WHERE name = 'sqlite_stat1'`)
		if err != nil || len(rows) > 0 {
			return
		}
	}
	if s.db.Run(ctx, "PRAGMA analysis_limit = 1000") != nil {
		return
	}
	_ = s.db.Run(ctx, "ANALYZE")
}

// Close closes the database, when it has a Close.
func (s *Store) Close() error {
	if c, ok := s.db.(interface{ Close() error }); ok {
		return c.Close()
	}
	return nil
}

// changed is how many rows an UPDATE or DELETE of rows with an id matched.
func (s *Store) changed(ctx context.Context, sql string, params ...any) (int64, error) {
	if a, ok := s.db.(Affecter); ok {
		return a.Affected(ctx, sql, params...)
	}
	rows, err := s.db.All(ctx, sql+" RETURNING id", params...)
	return int64(len(rows)), err
}

// Transaction runs fn with a store whose every query is in one transaction.
func (s *Store) Transaction(ctx context.Context, fn func(*Store) error) error {
	if t, ok := s.db.(Transactor); ok {
		return t.Transaction(ctx, func(db Db) error { return fn(&Store{db: db, ready: true}) })
	}
	if err := s.db.Run(ctx, "BEGIN"); err != nil {
		return err
	}
	if err := fn(s); err != nil {
		_ = s.db.Run(ctx, "ROLLBACK")
		return err
	}
	return s.db.Run(ctx, "COMMIT")
}

// Sites

// UpsertSite records a site set in code. Unchanged sites are left alone, so
// starting needs no write and a read-only database still opens.
func (s *Store) UpsertSite(ctx context.Context, site SiteRow, now int64) error {
	rows, err := s.db.All(ctx, `SELECT name, hostnames, timezone FROM rl_sites WHERE id = ?`, site.ID)
	if err != nil {
		return err
	}
	hostnames := js.Stringify(site.Hostnames)
	if len(rows) > 0 && str(rows[0]["name"]) == site.Name && str(rows[0]["hostnames"]) == hostnames && str(rows[0]["timezone"]) == site.Timezone {
		return nil
	}
	return s.db.Run(ctx, upsert(s.dialect(), "rl_sites", []string{"id", "name", "hostnames", "timezone", "created_at"}, []string{"id"}, []string{"name", "hostnames", "timezone"}),
		site.ID, site.Name, hostnames, site.Timezone, now)
}

// SiteOverrides are the settings changed in the dashboard, by site. They win
// over the ones in code.
func (s *Store) SiteOverrides(ctx context.Context) (map[string]*js.Object, []string, error) {
	rows, err := s.db.All(ctx, `SELECT id, overrides FROM rl_sites`)
	if err != nil {
		return nil, nil, err
	}
	out := map[string]*js.Object{}
	order := []string{}
	for _, row := range rows {
		id := str(row["id"])
		parsed, err := js.Parse(str(row["overrides"]))
		o, ok := parsed.(*js.Object)
		if err != nil || !ok {
			o = &js.Object{}
		}
		if _, seen := out[id]; !seen {
			order = append(order, id)
		}
		out[id] = o
	}
	return out, order, nil
}

// DeleteSite deletes a site and everything recorded for it. Its events and
// visits go a day at a time first, so a big site does not hold the database
// for minutes, and what is left goes in one transaction.
func (s *Store) DeleteSite(ctx context.Context, id string) error {
	piece := int64(pieceMs)
	if s.metered() {
		piece = 30 * pieceMs
	}
	for _, t := range [][2]string{{"rl_events", "ts"}, {"rl_sessions", "started_at"}} {
		// A piece at a time from the oldest row, skipping straight over stretches with none.
		from, err := s.oldest(ctx, t[0], t[1], id, nil)
		for ; err == nil && from != nil; from, err = s.oldest(ctx, t[0], t[1], id, i64(*from+piece)) {
			if err := s.db.Run(ctx, fmt.Sprintf(`DELETE FROM %s WHERE site = ? AND %s < ?`, t[0], t[1]), id, *from+piece); err != nil {
				return err
			}
			runtime.Gosched()
		}
		if err != nil {
			return err
		}
	}
	return s.Transaction(ctx, func(store *Store) error {
		for _, table := range []string{"rl_events", "rl_sessions", "rl_links", "rl_link_domains", "rl_shares", "rl_goals", "rl_funnels", "rl_reports", "rl_tokens", "rl_rollups", "rl_rollup_days", "rl_sites"} {
			col := "site"
			if table == "rl_sites" {
				col = "id"
			}
			if err := store.db.Run(ctx, fmt.Sprintf(`DELETE FROM %s WHERE %s = ?`, table, col), id); err != nil {
				return err
			}
		}
		return nil
	})
}

// oldest is when a site's oldest row at or after from is (nil from: any), or nil when there is none.
func (s *Store) oldest(ctx context.Context, table, col, site string, from *int64) (*int64, error) {
	var rows []Row
	var err error
	if from == nil {
		rows, err = s.db.All(ctx, fmt.Sprintf(`SELECT MIN(%s) AS t FROM %s WHERE site = ?`, col, table), site)
	} else {
		rows, err = s.db.All(ctx, fmt.Sprintf(`SELECT MIN(%s) AS t FROM %s WHERE site = ? AND %s >= ?`, col, table, col), site, *from)
	}
	if err != nil || len(rows) == 0 || rows[0]["t"] == nil {
		return nil, err
	}
	return i64(numInt(rows[0]["t"])), nil
}

// DropBefore deletes a site's visits and events from before a time, for its retention setting.
func (s *Store) DropBefore(ctx context.Context, site string, ts int64) error {
	// A day at a time from the oldest, each its own short transaction, so a long history goes without
	// holding the database for minutes. Stretches with nothing in them are skipped, so one stray old row
	// does not cost a piece for every day since.
	piece := int64(pieceMs)
	if s.metered() {
		piece = 30 * pieceMs
	}
	next := func(at *int64) (*int64, error) {
		a, err := s.oldest(ctx, "rl_sessions", "started_at", site, at)
		if err != nil {
			return nil, err
		}
		b, err := s.oldest(ctx, "rl_events", "ts", site, at)
		if err != nil {
			return nil, err
		}
		var found *int64
		for _, t := range []*int64{a, b} {
			if t != nil && (found == nil || *t < *found) {
				found = t
			}
		}
		if found == nil {
			return nil, nil
		}
		if at != nil && *at > *found {
			return at, nil
		}
		return found, nil
	}
	from, err := next(nil)
	for ; err == nil && from != nil && *from < ts; from, err = next(i64(min(*from+piece, ts))) {
		to := min(*from+piece, ts)
		f := *from
		err = s.Transaction(ctx, func(store *Store) error {
			// A visit's events go with it, even ones after the cutoff, so nothing is left without its visit.
			// They come after it starts and within EventTailMs, so the time bounds let the (site, ts) index find them.
			if err := store.db.Run(ctx, `DELETE FROM rl_events WHERE site = ? AND ts >= ? AND ts < ? AND session IN (SELECT id FROM rl_sessions WHERE site = ? AND started_at >= ? AND started_at < ?)`,
				site, f, to+EventTailMs, site, f, to); err != nil {
				return err
			}
			if err := store.db.Run(ctx, `DELETE FROM rl_events WHERE site = ? AND ts < ?`, site, to); err != nil {
				return err
			}
			return store.db.Run(ctx, `DELETE FROM rl_sessions WHERE site = ? AND started_at < ?`, site, to)
		})
		if err != nil {
			return err
		}
		runtime.Gosched()
	}
	if err != nil {
		return err
	}
	// A day that lost any of its visits is built again later, from what is left.
	return s.ClearRollups(ctx, site, RollupRange{Before: &ts})
}

// DropOrphans deletes a site's events from from on whose visit no longer exists, a day at a time.
func (s *Store) DropOrphans(ctx context.Context, site string, from, until int64) error {
	piece := int64(pieceMs)
	if s.metered() {
		piece = 30 * pieceMs
	}
	at, err := s.oldest(ctx, "rl_events", "ts", site, &from)
	for ; err == nil && at != nil && *at < until; at, err = s.oldest(ctx, "rl_events", "ts", site, i64(*at+piece)) {
		if err := s.db.Run(ctx, `DELETE FROM rl_events WHERE site = ? AND ts >= ? AND ts < ? AND session <> '' AND NOT EXISTS (SELECT 1 FROM rl_sessions s WHERE s.id = rl_events.session)`,
			site, *at, *at+piece); err != nil {
			return err
		}
		runtime.Gosched()
	}
	return err
}

// Daily rollups

// BuildRollupDay adds up one local day of a site: totals, each visit
// dimension, and pages. A visit belongs to the day it started. Visitor ids
// change every day, so the days of a range add up to exactly what counting
// the range would give.
func (s *Store) BuildRollupDay(ctx context.Context, site, day string, start, end int64) error {
	// A day with no visits still gets its row of zeros, so it counts as built.
	sums := "COUNT(DISTINCT s.visitor), COUNT(*), COALESCE(SUM(s.pageviews), 0), COALESCE(SUM(CASE WHEN " + bounce + " THEN 1 ELSE 0 END), 0), COALESCE(SUM(" + duration + "), 0)"
	cols := "(site, day, dim, value, visitors, visits, pageviews, bounced, duration)"
	// Each piece names its own site and day, as text, so Postgres knows their type inside a UNION.
	dialect := s.dialect()
	head := asText(dialect, "?") + ", " + asText(dialect, "?")
	quarter := div(dialect, "s.started_at", 900000)
	// The day's totals, each visit dimension, and the heatmap's quarter hours (counted as hourly() counts
	// them: every visit that started), in one statement over the day's visits.
	pieces := []string{"SELECT " + head + ", '', '', " + sums + " FROM v s"}
	for _, d := range sessionDimensions {
		pieces = append(pieces, fmt.Sprintf("SELECT %s, '%s', s.%s, %s FROM v s WHERE s.%s <> '' GROUP BY s.%s", head, d[0], d[1], sums, d[1], d[1]))
	}
	pieces = append(pieces, "SELECT "+head+", 'quarter', "+asText(dialect, quarter)+", COUNT(DISTINCT s.visitor), COUNT(*), COALESCE(SUM(s.pageviews), 0), COALESCE(SUM(CASE WHEN "+bounce+" THEN 1 ELSE 0 END), 0), 0 FROM v s GROUP BY "+asText(dialect, quarter))
	// Pages and events, from the rows of the day's visits. The time bounds let the (site, kind, ts) index
	// find them; a visit's last row comes at most EventTailMs after it starts.
	ofDay := func(kind string) string {
		return `FROM rl_events e JOIN rl_sessions s ON s.id = e.session
       WHERE e.site = ? AND e.kind = '` + kind + `' AND e.ts >= ? AND e.ts < ? AND s.started_at >= ? AND s.started_at < ? AND ` + isVisit
	}
	window := []any{site, start, end + EventTailMs, start, end}
	return s.Transaction(ctx, func(store *Store) error {
		db := store.db
		if err := db.Run(ctx, `DELETE FROM rl_rollups WHERE site = ? AND day = ?`, site, day); err != nil {
			return err
		}
		params := []any{site, start, end}
		for range pieces {
			params = append(params, site, day)
		}
		// The WITH goes after INSERT INTO, the one place every database takes it.
		if err := db.Run(ctx, `INSERT INTO rl_rollups `+cols+`
         WITH v AS (SELECT * FROM rl_sessions s WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND `+isVisit+`)
         `+strings.Join(pieces, " UNION ALL "), params...); err != nil {
			return err
		}
		// A page's engaged time and scroll come per pageview first (its time added up, its deepest scroll),
		// as the raw report counts them.
		if err := db.Run(ctx, `INSERT INTO rl_rollups (site, day, dim, value, visitors, visits, pageviews, views, engaged, scroll_sum, scroll_n)
         SELECT ?, ?, 'page', p.value, p.visitors, p.visits, p.pageviews, p.views, COALESCE(t.engaged, 0), COALESCE(t.scroll_sum, 0), COALESCE(t.scroll_n, 0)
         FROM (SELECT e.path AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(DISTINCT e.session) AS visits, COUNT(*) AS pageviews, `+liveViews+` AS views
               `+ofDay("pageview")+` GROUP BY e.path) p
         LEFT JOIN (SELECT value, SUM(total) AS engaged, SUM(deepest) AS scroll_sum, COUNT(deepest) AS scroll_n FROM (
               SELECT e.path AS value, SUM(e.engaged_ms) AS total, MAX(e.scroll) AS deepest `+ofDay("engagement")+` GROUP BY e.path, e.pageview) x
               GROUP BY value) t ON t.value = p.value`,
			append(append([]any{site, day}, window...), window...)...); err != nil {
			return err
		}
		if err := db.Run(ctx, `INSERT INTO rl_rollups (site, day, dim, value, visitors, events)
         SELECT ?, ?, 'event', e.name, COUNT(DISTINCT e.visitor), COUNT(*) `+ofDay("event")+` GROUP BY e.name`,
			append([]any{site, day}, window...)...); err != nil {
			return err
		}
		if err := db.Run(ctx, `DELETE FROM rl_rollup_days WHERE site = ? AND day = ?`, site, day); err != nil {
			return err
		}
		return db.Run(ctx, `INSERT INTO rl_rollup_days (site, day, start_at, end_at) VALUES (?, ?, ?, ?)`, site, day, start, end)
	})
}

// RollupDays are the days of a site already built.
func (s *Store) RollupDays(ctx context.Context, site string) (map[string]bool, error) {
	rows, err := s.db.All(ctx, `SELECT day FROM rl_rollup_days WHERE site = ?`, site)
	if err != nil {
		return nil, err
	}
	out := map[string]bool{}
	for _, r := range rows {
		out[str(r["day"])] = true
	}
	return out, nil
}

// RollupRange picks the built days to forget: before a time, or touching a
// stretch from From to To. Neither is every day.
type RollupRange struct {
	Before *int64
	From   *int64
	To     *int64
}

// ClearRollups forgets built days, all of a site's or those touching a
// stretch of time, so they are built again.
func (s *Store) ClearRollups(ctx context.Context, site string, r RollupRange) error {
	where := "site = ?"
	params := []any{site}
	if r.Before != nil {
		where += " AND start_at < ?"
		params = append(params, *r.Before)
	} else if r.From != nil && r.To != nil {
		where += " AND start_at < ? AND end_at > ?"
		params = append(params, *r.To, *r.From)
	}
	rows, err := s.db.All(ctx, `SELECT day FROM rl_rollup_days WHERE `+where, params...)
	if err != nil {
		return err
	}
	// The days stop counting as built first, so if this stops part way, no day is left marked built
	// without its rows. Another process may build a day between the two deletes, so its mark goes again
	// after its rows: the day is then simply built once more.
	if err := s.db.Run(ctx, `DELETE FROM rl_rollup_days WHERE `+where, params...); err != nil {
		return err
	}
	for _, r := range rows {
		day := str(r["day"])
		if err := s.db.Run(ctx, `DELETE FROM rl_rollups WHERE site = ? AND day = ?`, site, day); err != nil {
			return err
		}
		if err := s.db.Run(ctx, `DELETE FROM rl_rollup_days WHERE site = ? AND day = ?`, site, day); err != nil {
			return err
		}
	}
	return nil
}

type builtDay struct {
	day        string
	start, end int64
}

type rollupPlan struct {
	days []builtDay
	rest [][2]int64
}

// rollupPlan is how to answer a range from rollups: the built days that lie
// wholly inside it, and the stretches left over, which are read from the
// visits as usual. Nil when no built day helps.
func (s *Store) rollupPlan(ctx context.Context, site string, filters []Filter, from, to int64) (*rollupPlan, error) {
	if len(filters) > 0 {
		return nil, nil
	}
	rows, err := s.db.All(ctx, `SELECT day, start_at, end_at FROM rl_rollup_days WHERE site = ? AND start_at >= ? AND end_at <= ? ORDER BY start_at`, site, from, to)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	plan := &rollupPlan{}
	for _, r := range rows {
		plan.days = append(plan.days, builtDay{str(r["day"]), numInt(r["start_at"]), numInt(r["end_at"])})
	}
	at := from
	for _, d := range plan.days {
		if d.start > at {
			plan.rest = append(plan.rest, [2]int64{at, d.start})
		}
		at = max(at, d.end)
	}
	if at < to {
		plan.rest = append(plan.rest, [2]int64{at, to})
	}
	return plan, nil
}

// within is SQL for "a visit that started in one of these stretches".
func within(rest [][2]int64) sqlPart {
	if len(rest) == 0 {
		return sqlPart{"1 = 0", nil}
	}
	parts := make([]string, len(rest))
	params := []any{}
	for i, r := range rest {
		parts[i] = "(s.started_at >= ? AND s.started_at < ?)"
		params = append(params, r[0], r[1])
	}
	return sqlPart{"(" + strings.Join(parts, " OR ") + ")", params}
}

// jsRound is Math.round of a ratio, as a whole number.
func jsRound(x float64) int64 { return int64(js.Round(x)) }

// round2 is Math.round(x * 100) / 100.
func round2(x float64) float64 { return js.Round(x*100) / 100 }

type rollSums struct {
	visitors, visits, pageviews, bounced, duration, engaged, views, scrollSum, scrollN, events float64
}

func (r *rollSums) bump(row Row) {
	r.visitors += num(row["visitors"])
	r.visits += num(row["visits"])
	r.pageviews += num(row["pageviews"])
	r.bounced += num(row["bounced"])
	r.duration += num(row["duration"])
	r.engaged += num(row["engaged"])
	r.views += num(row["views"])
	r.scrollSum += num(row["scroll_sum"])
	r.scrollN += num(row["scroll_n"])
	r.events += num(row["events"])
}

// rolledBreakdown is a breakdown of a visit dimension or of pages from
// rollups and the visits left over, merged, then sorted and cut to the page
// asked for.
func (s *Store) rolledBreakdown(ctx context.Context, query Query, dimension string, limit, offset int) ([]BreakdownRow, bool, error) {
	page := dimension == "page"
	event := dimension == "event"
	if !page && !event && !IsSessionDimension(dimension) {
		return nil, false, nil
	}
	if len(query.Filters) > 0 {
		return nil, false, nil
	}
	// Pages and events always go this way without filters, so a range gives the same answer whether its days are built or not.
	plan, err := s.rollupPlan(ctx, query.Site, query.Filters, query.From, query.To)
	if err != nil {
		return nil, false, err
	}
	if plan == nil {
		if !page && !event {
			return nil, false, nil
		}
		plan = &rollupPlan{rest: [][2]int64{{query.From, query.To}}}
	}
	sums := map[string]*rollSums{}
	order := []string{}
	bump := func(row Row) {
		key := str(row["value"])
		into, ok := sums[key]
		if !ok {
			into = &rollSums{}
			sums[key] = into
			order = append(order, key)
		}
		into.bump(row)
	}
	if len(plan.days) > 0 {
		rolled, err := s.db.All(ctx, `SELECT value, SUM(visitors) AS visitors, SUM(visits) AS visits, SUM(pageviews) AS pageviews, SUM(bounced) AS bounced, SUM(duration) AS duration,
           SUM(engaged) AS engaged, SUM(views) AS views, SUM(scroll_sum) AS scroll_sum, SUM(scroll_n) AS scroll_n, SUM(events) AS events
         FROM rl_rollups WHERE site = ? AND dim = ? AND day IN (`+builtDays+`) GROUP BY value`,
			query.Site, dimension, query.Site, query.From, query.To)
		if err != nil {
			return nil, false, err
		}
		for _, row := range rolled {
			bump(row)
		}
	}
	w := within(plan.rest)
	switch {
	case (page || event) && len(plan.rest) > 0:
		// A visit's pageviews and events belong to the day it started, as in the rollups.
		// Bounded by time as well, so the events index finds them (see BuildRollupDay).
		lo, hi := plan.rest[0][0], plan.rest[0][1]
		for _, r := range plan.rest {
			lo, hi = min(lo, r[0]), max(hi, r[1])
		}
		hi += EventTailMs
		ofRest := func(kind string) string {
			return `FROM rl_events e JOIN rl_sessions s ON s.id = e.session WHERE e.site = ? AND e.kind = '` + kind + `' AND e.ts >= ? AND e.ts < ? AND ` + isVisit + ` AND ` + w.sql
		}
		at := append([]any{query.Site, lo, hi}, w.params...)
		if page {
			rows, err := s.db.All(ctx, `SELECT e.path AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(DISTINCT e.session) AS visits, COUNT(*) AS pageviews, `+liveViews+` AS views `+ofRest("pageview")+` GROUP BY e.path`, at...)
			if err != nil {
				return nil, false, err
			}
			for _, row := range rows {
				bump(row)
			}
			rows, err = s.db.All(ctx, `SELECT value, SUM(total) AS engaged, SUM(deepest) AS scroll_sum, COUNT(deepest) AS scroll_n FROM (
             SELECT e.path AS value, SUM(e.engaged_ms) AS total, MAX(e.scroll) AS deepest `+ofRest("engagement")+` GROUP BY e.path, e.pageview) t GROUP BY value`, at...)
			if err != nil {
				return nil, false, err
			}
			for _, row := range rows {
				bump(row)
			}
		} else {
			rows, err := s.db.All(ctx, `SELECT e.name AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(*) AS events `+ofRest("event")+` GROUP BY e.name`, at...)
			if err != nil {
				return nil, false, err
			}
			for _, row := range rows {
				bump(row)
			}
		}
	case page || event:
		// Every day of the range is built.
	default:
		col := "s." + sessionColumn(dimension)
		rows, err := s.db.All(ctx, `SELECT `+col+` AS value, COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits, SUM(s.pageviews) AS pageviews,
           SUM(CASE WHEN `+bounce+` THEN 1 ELSE 0 END) AS bounced, SUM(`+duration+`) AS duration
         FROM rl_sessions s WHERE s.site = ? AND `+isVisit+` AND `+w.sql+` AND `+col+` <> '' GROUP BY `+col,
			append([]any{query.Site}, w.params...)...)
		if err != nil {
			return nil, false, err
		}
		for _, row := range rows {
			bump(row)
		}
	}
	entryExit := dimension == "entry" || dimension == "exit"
	keys := []string{}
	for _, value := range order {
		x := sums[value]
		keep := x.visits > 0
		if page {
			keep = x.pageviews > 0
		} else if event {
			keep = x.events > 0
		}
		if (event || value != "") && keep {
			keys = append(keys, value)
		}
	}
	sort.SliceStable(keys, func(i, j int) bool {
		a, b := keys[i], keys[j]
		x, y := sums[a], sums[b]
		cmp := func(pairs ...float64) (bool, bool) {
			for k := 0; k+1 < len(pairs); k += 2 {
				if pairs[k] != pairs[k+1] {
					return pairs[k] > pairs[k+1], true
				}
			}
			return false, false
		}
		var less, decided bool
		switch {
		case entryExit:
			less, decided = cmp(x.visits, y.visits)
		case event:
			less, decided = cmp(x.visitors, y.visitors, x.events, y.events)
		case page:
			less, decided = cmp(x.visitors, y.visitors, x.pageviews, y.pageviews)
		default:
			less, decided = cmp(x.visitors, y.visitors, x.visits, y.visits)
		}
		if decided {
			return less
		}
		return codeOrder(a, b) < 0
	})
	end := min(len(keys), offset+limit)
	if offset > len(keys) {
		offset = len(keys)
	}
	out := []BreakdownRow{}
	for _, value := range keys[offset:end] {
		x := sums[value]
		switch {
		case event:
			out = append(out, BreakdownRow{Value: value, Visitors: int64(x.visitors), Events: i64(int64(x.events))})
		case page:
			// Over every pageview that could report its time, counting those that sent none (under a second) as none.
			row := BreakdownRow{Value: value, Visitors: int64(x.visitors), Pageviews: i64(int64(x.pageviews)), TimeOnPage: i64(0), ScrollDepth: i64(0)}
			if x.views > 0 {
				row.TimeOnPage = i64(jsRound(x.engaged / x.views))
			}
			if x.scrollN > 0 {
				row.ScrollDepth = i64(jsRound(x.scrollSum / x.scrollN))
			}
			out = append(out, row)
		default:
			row := BreakdownRow{Value: value, Visitors: int64(x.visitors), Visits: i64(int64(x.visits)), BounceRate: f64(0)}
			if x.visits > 0 {
				row.BounceRate = f64(x.bounced / x.visits)
			}
			if !entryExit {
				row.Pageviews = i64(int64(x.pageviews))
				row.VisitDuration = i64(0)
				if x.visits > 0 {
					row.VisitDuration = i64(jsRound(x.duration / x.visits))
				}
			}
			out = append(out, row)
		}
	}
	return out, true, nil
}

func (s *Store) rolledStats(ctx context.Context, query Query) (*Stats, error) {
	plan, err := s.rollupPlan(ctx, query.Site, query.Filters, query.From, query.To)
	if err != nil || plan == nil {
		return nil, err
	}
	rolled, err := s.db.All(ctx, `SELECT SUM(visitors) AS visitors, SUM(visits) AS visits, SUM(pageviews) AS pageviews, SUM(bounced) AS bounced, SUM(duration) AS duration
       FROM rl_rollups WHERE site = ? AND dim = '' AND day IN (`+builtDays+`)`, query.Site, query.Site, query.From, query.To)
	if err != nil {
		return nil, err
	}
	w := within(plan.rest)
	raw, err := s.db.All(ctx, `SELECT COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits, SUM(s.pageviews) AS pageviews,
         SUM(CASE WHEN `+bounce+` THEN 1 ELSE 0 END) AS bounced, SUM(`+duration+`) AS duration
       FROM rl_sessions s WHERE s.site = ? AND `+isVisit+` AND `+w.sql, append([]any{query.Site}, w.params...)...)
	if err != nil {
		return nil, err
	}
	add := func(k string) float64 {
		n := 0.0
		if len(rolled) > 0 {
			n += num(rolled[0][k])
		}
		if len(raw) > 0 {
			n += num(raw[0][k])
		}
		return n
	}
	return statsOf(add("visitors"), add("visits"), add("pageviews"), add("bounced"), add("duration")), nil
}

func statsOf(visitors, visits, pageviews, bounced, dur float64) *Stats {
	out := &Stats{Visitors: int64(visitors), Visits: int64(visits), Pageviews: int64(pageviews)}
	if visits > 0 {
		out.ViewsPerVisit = round2(pageviews / visits)
		out.BounceRate = bounced / visits
		out.VisitDuration = jsRound(dur / visits)
	}
	return out
}

// SetSiteOverrides records the settings changed in the dashboard for a site.
func (s *Store) SetSiteOverrides(ctx context.Context, id string, overrides *js.Object) error {
	return s.db.Run(ctx, `UPDATE rl_sites SET overrides = ? WHERE id = ?`, js.Stringify(overrides), id)
}

func nullableTime(rows []Row) *int64 {
	if len(rows) == 0 || rows[0]["t"] == nil {
		return nil
	}
	return i64(numInt(rows[0]["t"]))
}

// LastSeen is when the site last recorded a visit, or nil if it never has.
func (s *Store) LastSeen(ctx context.Context, site string) (*int64, error) {
	rows, err := s.db.All(ctx, `SELECT MAX(ts) AS t FROM rl_events WHERE site = ? AND kind IN ('pageview', 'event')`, site)
	return nullableTime(rows), err
}

// Sites are every site the store holds, by name then id.
func (s *Store) Sites(ctx context.Context) ([]SiteRow, error) {
	rows, err := s.db.All(ctx, `SELECT id, name, hostnames, timezone FROM rl_sites ORDER BY name, id`)
	if err != nil {
		return nil, err
	}
	out := []SiteRow{}
	for _, row := range rows {
		hostnames := []string{}
		if parsed, err := js.Parse(str(row["hostnames"])); err == nil {
			for _, h := range js.Arr(parsed) {
				hostnames = append(hostnames, js.String(h))
			}
		} else {
			return nil, err
		}
		out = append(out, SiteRow{ID: str(row["id"]), Name: str(row["name"]), Hostnames: hostnames, Timezone: str(row["timezone"])})
	}
	return out, nil
}

// Salts

// Salt is the salt for a day, made on first ask. Two racing callers agree on one.
func (s *Store) Salt(ctx context.Context, day, fresh string) (string, error) {
	if err := s.db.Run(ctx, upsert(s.dialect(), "rl_salts", []string{"day", "salt"}, []string{"day"}, nil), day, fresh); err != nil {
		return "", err
	}
	rows, err := s.db.All(ctx, `SELECT salt FROM rl_salts WHERE day = ?`, day)
	if err != nil {
		return "", err
	}
	if len(rows) == 0 || rows[0]["salt"] == nil {
		return fresh, nil
	}
	return str(rows[0]["salt"]), nil
}

// SaltIfExists is the salt for a day, or "" and false when there is none.
func (s *Store) SaltIfExists(ctx context.Context, day string) (string, bool, error) {
	rows, err := s.db.All(ctx, `SELECT salt FROM rl_salts WHERE day = ?`, day)
	if err != nil || len(rows) == 0 || rows[0]["salt"] == nil {
		return "", false, err
	}
	return str(rows[0]["salt"]), true, nil
}

// DropSaltsBefore deletes every salt older than day, so old hashes can never be recomputed.
func (s *Store) DropSaltsBefore(ctx context.Context, day string) error {
	return s.db.Run(ctx, `DELETE FROM rl_salts WHERE day < ?`, day)
}

// Ingest

// OpenSession is the visitor's open session: any of their hashes, active since since.
func (s *Store) OpenSession(ctx context.Context, site string, visitors []string, since int64) (*OpenSession, error) {
	if len(visitors) == 0 {
		return nil, nil
	}
	params := []any{site}
	for _, v := range visitors {
		params = append(params, v)
	}
	params = append(params, since)
	rows, err := s.db.All(ctx, `SELECT id, visitor FROM rl_sessions WHERE site = ? AND visitor IN (`+placeholders(len(visitors))+`) AND last_at >= ?
       ORDER BY last_at DESC, id LIMIT 1`, params...)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	return &OpenSession{ID: str(rows[0]["id"]), Visitor: str(rows[0]["visitor"])}, nil
}

// InsertSession records a visit as it starts.
func (s *Store) InsertSession(ctx context.Context, row SessionRow) error {
	return s.db.Run(ctx, `INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, engaged_ms, hostname, referrer_host, referrer_path,
        source, channel, utm_source, utm_medium, utm_campaign, utm_term, utm_content, country, region, city,
        browser, browser_version, os, os_version, device, screen, language)
       VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		row.ID, row.Site, row.Visitor, row.StartedAt, row.StartedAt, row.Hostname, row.ReferrerHost, row.ReferrerPath,
		row.Source, row.Channel, row.UtmSource, row.UtmMedium, row.UtmCampaign, row.UtmTerm, row.UtmContent,
		row.Country, row.Region, row.City, row.Browser, row.BrowserVersion, row.OS, row.OSVersion, row.Device,
		row.Screen, row.Language)
}

// TouchSession counts a row into its session. An event with reopen false,
// one that joins a visit already ended, counts without moving the session's
// last activity.
func (s *Store) TouchSession(ctx context.Context, id string, ts int64, kind, path string, reopen bool) error {
	switch {
	case kind == "click":
		return s.db.Run(ctx, `UPDATE rl_sessions SET last_at = ? WHERE id = ?`, ts, id)
	case kind == "pageview":
		return s.db.Run(ctx, `UPDATE rl_sessions SET pageviews = pageviews + 1, last_at = ?, exit_path = ?,
           entry_path = CASE WHEN entry_path = '' THEN ? ELSE entry_path END WHERE id = ?`, ts, path, path, id)
	case reopen:
		return s.db.Run(ctx, `UPDATE rl_sessions SET events = events + 1, last_at = ? WHERE id = ?`, ts, id)
	}
	return s.db.Run(ctx, `UPDATE rl_sessions SET events = events + 1 WHERE id = ?`, id)
}

// AddEngagement adds engaged time to a session.
func (s *Store) AddEngagement(ctx context.Context, id string, ms int64) error {
	return s.db.Run(ctx, `UPDATE rl_sessions SET engaged_ms = COALESCE(engaged_ms, 0) + ? WHERE id = ?`, ms, id)
}

// Pageview is the pageview an engagement ping or event belongs to, with when
// its visit started and was last active.
func (s *Store) Pageview(ctx context.Context, site, pageview string) (*PageviewRef, error) {
	rows, err := s.db.All(ctx, `SELECT e.session AS session, e.visitor AS visitor, e.path AS path, e.hostname AS hostname, e.ts AS ts, s.started_at AS started_at, s.last_at AS last_at
       FROM rl_events e JOIN rl_sessions s ON s.id = e.session WHERE e.site = ? AND e.pageview = ? AND e.kind = 'pageview' LIMIT 1`, site, pageview)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	r := rows[0]
	return &PageviewRef{Session: str(r["session"]), Visitor: str(r["visitor"]), Path: str(r["path"]), Hostname: str(r["hostname"]),
		Ts: numInt(r["ts"]), StartedAt: numInt(r["started_at"]), LastAt: numInt(r["last_at"])}, nil
}

// TouchedOldVisit forgets the day an old visit started, after a late event
// or engagement ping joins it (a tab left open overnight), so the next check
// builds it again.
func (s *Store) TouchedOldVisit(ctx context.Context, site string, started, before int64) error {
	if started < before {
		return s.ClearRollups(ctx, site, RollupRange{From: &started, To: i64(started + 1)})
	}
	return nil
}

// InsertEvent records one row.
func (s *Store) InsertEvent(ctx context.Context, row EventRow) error {
	var props any
	if row.Props != nil {
		props = js.Stringify(row.Props)
	}
	var scroll any
	if row.Scroll != nil {
		scroll = int64(*row.Scroll)
	}
	return s.db.Run(ctx, `INSERT INTO rl_events (site, ts, kind, visitor, session, pageview, path, hostname, title, name, props, engaged_ms, scroll, link)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		row.Site, row.Ts, row.Kind, row.Visitor, row.Session, row.Pageview, row.Path, row.Hostname, row.Title,
		row.Name, props, row.EngagedMs, scroll, row.Link)
}

// Links

func linkRow(row Row) LinkRow {
	return LinkRow{ID: str(row["id"]), Site: str(row["site"]), Domain: strOr(row["domain"], ""), Slug: str(row["slug"]), Name: strOr(row["name"], ""),
		URL: str(row["url"]), CreatedAt: numInt(row["created_at"]), UpdatedAt: numInt(row["updated_at"])}
}

// LinkBySlug is the live link with a slug. Slugs are unique across every domain.
func (s *Store) LinkBySlug(ctx context.Context, slug string) (*LinkRow, error) {
	rows, err := s.db.All(ctx, `SELECT * FROM rl_links WHERE slug = ? AND deleted_at IS NULL LIMIT 1`, slug)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	l := linkRow(rows[0])
	return &l, nil
}

// LinkByID is the live link with an id.
func (s *Store) LinkByID(ctx context.Context, id string) (*LinkRow, error) {
	rows, err := s.db.All(ctx, `SELECT * FROM rl_links WHERE id = ? AND deleted_at IS NULL LIMIT 1`, id)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	l := linkRow(rows[0])
	return &l, nil
}

// InsertLink records a new link.
func (s *Store) InsertLink(ctx context.Context, l LinkRow) error {
	return s.db.Run(ctx, `INSERT INTO rl_links (id, site, domain, slug, name, url, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		l.ID, l.Site, l.Domain, l.Slug, l.Name, l.URL, l.CreatedAt, l.UpdatedAt)
}

// UpdateLink changes a link.
func (s *Store) UpdateLink(ctx context.Context, l LinkRow) error {
	return s.db.Run(ctx, `UPDATE rl_links SET domain = ?, slug = ?, name = ?, url = ?, updated_at = ? WHERE id = ?`, l.Domain, l.Slug, l.Name, l.URL, l.UpdatedAt, l.ID)
}

// DeleteLink hides a link and frees its slug; its clicks stay in the history.
func (s *Store) DeleteLink(ctx context.Context, id string, now int64) error {
	return s.db.Run(ctx, `UPDATE rl_links SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL`, now, id)
}

// Shares

func shareRow(r Row) ShareRow {
	return ShareRow{ID: str(r["id"]), Site: str(r["site"]), Name: strOr(r["name"], ""), CreatedAt: numInt(r["created_at"])}
}

// Shares are a site's share links, newest first.
func (s *Store) Shares(ctx context.Context, site string) ([]ShareRow, error) {
	rows, err := s.db.All(ctx, `SELECT id, site, name, created_at FROM rl_shares WHERE site = ? ORDER BY created_at DESC, id`, site)
	if err != nil {
		return nil, err
	}
	out := []ShareRow{}
	for _, r := range rows {
		out = append(out, shareRow(r))
	}
	return out, nil
}

// ShareByID is a share link by its id.
func (s *Store) ShareByID(ctx context.Context, id string) (*ShareRow, error) {
	rows, err := s.db.All(ctx, `SELECT id, site, name, created_at FROM rl_shares WHERE id = ?`, id)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	r := shareRow(rows[0])
	return &r, nil
}

// InsertShare records a share link.
func (s *Store) InsertShare(ctx context.Context, share ShareRow) error {
	return s.db.Run(ctx, `INSERT INTO rl_shares (id, site, name, created_at) VALUES (?, ?, ?, ?)`, share.ID, share.Site, share.Name, share.CreatedAt)
}

// RenameShare renames a share link.
func (s *Store) RenameShare(ctx context.Context, id, name string) error {
	return s.db.Run(ctx, `UPDATE rl_shares SET name = ? WHERE id = ?`, name, id)
}

// DeleteShare is how a share is revoked: the link stops working at once.
func (s *Store) DeleteShare(ctx context.Context, id string) error {
	return s.db.Run(ctx, `DELETE FROM rl_shares WHERE id = ?`, id)
}

// Funnels

// Funnels are a site's funnels, oldest first.
func (s *Store) Funnels(ctx context.Context, site string) ([]FunnelRow, error) {
	rows, err := s.db.All(ctx, `SELECT * FROM rl_funnels WHERE site = ? ORDER BY created_at, id`, site)
	if err != nil {
		return nil, err
	}
	out := []FunnelRow{}
	for _, r := range rows {
		parsed, err := js.Parse(str(r["steps"]))
		if err != nil {
			return nil, err
		}
		steps := []FunnelStep{}
		for _, step := range js.Arr(parsed) {
			steps = append(steps, FunnelStep{Kind: js.String(js.Dig(step, "kind")), Match: js.String(js.Dig(step, "match"))})
		}
		out = append(out, FunnelRow{ID: str(r["id"]), Site: str(r["site"]), Name: str(r["name"]), Steps: steps, CreatedAt: numInt(r["created_at"])})
	}
	return out, nil
}

// SaveFunnel records a funnel, new or changed.
func (s *Store) SaveFunnel(ctx context.Context, f FunnelRow) error {
	return s.db.Run(ctx, upsert(s.dialect(), "rl_funnels", []string{"id", "site", "name", "steps", "created_at"}, []string{"id"}, []string{"name", "steps"}),
		f.ID, f.Site, f.Name, js.Stringify(f.Steps), f.CreatedAt)
}

// DeleteFunnel deletes a funnel.
func (s *Store) DeleteFunnel(ctx context.Context, id string) error {
	return s.db.Run(ctx, `DELETE FROM rl_funnels WHERE id = ?`, id)
}

// FunnelCounts is how many visits reached each step, in order, within the
// same visit. Step one is the first matching row in the range; each later
// step must come after the step before it. Filters choose which visits
// enter the funnel.
func (s *Store) FunnelCounts(ctx context.Context, query Query, funnel FunnelRow) ([]int64, error) {
	// The rows of the picked visits that match any step, in order, read once and walked here: a join from
	// each step to the next is planned badly by Postgres, which cannot guess how many visits go on.
	v := visitRows(query.Filters, query.Site, query.From, query.To, s.dialect())
	scopes := make([]sqlPart, len(funnel.Steps))
	cases := make([]string, len(funnel.Steps))
	anys := make([]string, len(funnel.Steps))
	params := []any{}
	anyParams := []any{}
	for i, step := range funnel.Steps {
		scopes[i] = s.goalScope(GoalRow{Kind: step.Kind, Match: step.Match, Name: step.Match})
		cases[i] = fmt.Sprintf("CASE WHEN %s THEN 1 ELSE 0 END AS m%d", scopes[i].sql, i)
		anys[i] = "(" + scopes[i].sql + ")"
		params = append(params, scopes[i].params...)
		anyParams = append(anyParams, scopes[i].params...)
	}
	params = append(append(params, v.params...), anyParams...)
	rows, err := s.db.All(ctx, `SELECT e.session AS session, `+strings.Join(cases, ", ")+`
       FROM `+v.from+` WHERE `+v.sql+` AND (`+strings.Join(anys, " OR ")+`)
       ORDER BY e.session, e.ts, e.id`, params...)
	if err != nil {
		return nil, err
	}
	counts := make([]int64, len(funnel.Steps))
	session := ""
	started := false
	reached := 0
	closeVisit := func() {
		for i := 0; i < reached; i++ {
			counts[i]++
		}
	}
	for _, row := range rows {
		if !started || str(row["session"]) != session {
			closeVisit()
			session = str(row["session"])
			started = true
			reached = 0
		}
		// Each step is the first matching row after the step before, so two steps in the same millisecond
		// both count, and one row never counts as two steps.
		if reached < len(counts) && num(row[fmt.Sprintf("m%d", reached)]) == 1 {
			reached++
		}
	}
	closeVisit()
	return counts, nil
}

// JourneyPages are each visit's pageviews in order, at most perVisit of
// them, for journeys, and whether the visits were sampled. A window
// function keeps the first ones of each visit, so a long visit cannot crowd
// the rest out. Visits belong to the range they started in.
func (s *Store) JourneyPages(ctx context.Context, query Query, perVisit int) ([]JourneyRow, bool, error) {
	scope := visitScope(query.Filters, query.Site, query.From, query.To, s.dialect())
	// The newest visits the filters pick, JourneyVisits at most, so a long range stays quick and small in memory.
	newest := func(columns string, limit int) string {
		return `SELECT ` + columns + ` FROM rl_sessions s WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND ` + isVisit + scope.sql + `
         ORDER BY s.started_at DESC, s.id LIMIT ` + strconv.Itoa(limit)
	}
	visitParams := append([]any{query.Site, query.From, query.To}, scope.params...)
	// How many there are, one past the cap telling whether it was reached, and when the oldest of them began,
	// so the rows are read from there on rather than from the start of a long range.
	first, err := s.db.All(ctx, `SELECT COUNT(*) AS n, MIN(started_at) AS t FROM (`+newest("s.started_at AS started_at", JourneyVisits+1)+`) x`, visitParams...)
	if err != nil {
		return nil, false, err
	}
	if len(first) == 0 || num(first[0]["n"]) == 0 {
		return []JourneyRow{}, false, nil
	}
	from := max(query.From, numInt(first[0]["t"]))
	// MySQL takes no LIMIT in an IN list, but does in a table inside one.
	visits := newest("s.id", JourneyVisits)
	if s.dialect() == "mysql" {
		visits = `SELECT id FROM (` + newest("s.id AS id", JourneyVisits) + `) x`
	}
	params := append([]any{query.Site, from, query.To + EventTailMs}, visitParams...)
	params = append(params, int64(perVisit))
	// The visits are read as an IN list, which every database probes from the events side, so the
	// plan does not depend on the planner's statistics. Refreshes (the same page twice in a row) are
	// dropped before counting, so they never use up the steps.
	rows, err := s.db.All(ctx, `WITH raw AS (
         SELECT e.session AS session, e.path AS path, e.ts AS ts, e.id AS id,
           LAG(e.path) OVER (PARTITION BY e.session ORDER BY e.ts, e.id) AS prev
         FROM rl_events e
         WHERE e.site = ? AND e.kind = 'pageview' AND e.ts >= ? AND e.ts < ? AND e.session IN (`+visits+`)),
       v AS (
         SELECT session, path, ROW_NUMBER() OVER (PARTITION BY session ORDER BY ts, id) AS n
         FROM raw WHERE prev IS NULL OR prev <> path)
       SELECT session, path FROM v WHERE n <= ? ORDER BY session, n`, params...)
	if err != nil {
		return nil, false, err
	}
	out := make([]JourneyRow, len(rows))
	for i, r := range rows {
		out[i] = JourneyRow{Session: str(r["session"]), Path: str(r["path"])}
	}
	return out, num(first[0]["n"]) > JourneyVisits, nil
}

// API tokens

func tokenRow(r Row) TokenRow {
	scope := "read"
	if str(r["scope"]) == "manage" {
		scope = "manage"
	}
	return TokenRow{ID: str(r["id"]), Name: str(r["name"]), Site: strOr(r["site"], ""), Scope: scope, Hash: str(r["hash"]), Hint: strOr(r["hint"], ""),
		CreatedAt: numInt(r["created_at"]), LastUsedAt: nullableInt(r["last_used_at"])}
}

// Tokens are every API token, newest first.
func (s *Store) Tokens(ctx context.Context) ([]TokenRow, error) {
	rows, err := s.db.All(ctx, `SELECT * FROM rl_tokens ORDER BY created_at DESC, id`)
	if err != nil {
		return nil, err
	}
	out := []TokenRow{}
	for _, r := range rows {
		out = append(out, tokenRow(r))
	}
	return out, nil
}

// TokenByHash is the token with a hash.
func (s *Store) TokenByHash(ctx context.Context, hash string) (*TokenRow, error) {
	rows, err := s.db.All(ctx, `SELECT * FROM rl_tokens WHERE hash = ?`, hash)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	t := tokenRow(rows[0])
	return &t, nil
}

// InsertToken records a token.
func (s *Store) InsertToken(ctx context.Context, t TokenRow) error {
	return s.db.Run(ctx, `INSERT INTO rl_tokens (id, name, site, scope, hash, hint, created_at, last_used_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		t.ID, t.Name, t.Site, t.Scope, t.Hash, t.Hint, t.CreatedAt, t.LastUsedAt)
}

// TouchToken records when a token was last used.
func (s *Store) TouchToken(ctx context.Context, id string, now int64) error {
	return s.db.Run(ctx, `UPDATE rl_tokens SET last_used_at = ? WHERE id = ?`, now, id)
}

// DeleteToken is how a token is revoked: it stops working at once.
func (s *Store) DeleteToken(ctx context.Context, id string) (bool, error) {
	n, err := s.changed(ctx, `DELETE FROM rl_tokens WHERE id = ?`, id)
	return n == 1, err
}

// Settings

// Setting is an install-wide setting, and whether there is one.
func (s *Store) Setting(ctx context.Context, key string) (string, bool, error) {
	rows, err := s.db.All(ctx, `SELECT value FROM rl_settings WHERE "key" = ?`, key)
	if err != nil || len(rows) == 0 {
		return "", false, err
	}
	return str(rows[0]["value"]), true, nil
}

// SettingsStartingWith are every setting whose key starts with a prefix,
// such as each connected install's.
func (s *Store) SettingsStartingWith(ctx context.Context, prefix string) ([]Setting, error) {
	rows, err := s.db.All(ctx, `SELECT "key", value FROM rl_settings WHERE "key" LIKE ? ESCAPE '\'`, escapeLike(prefix)+"%")
	if err != nil {
		return nil, err
	}
	out := []Setting{}
	for _, r := range rows {
		out = append(out, Setting{Key: str(r["key"]), Value: str(r["value"])})
	}
	return out, nil
}

// SetSetting changes an install-wide setting; nil deletes it.
func (s *Store) SetSetting(ctx context.Context, key string, value *string) error {
	if value == nil {
		return s.db.Run(ctx, `DELETE FROM rl_settings WHERE "key" = ?`, key)
	}
	return s.db.Run(ctx, upsert(s.dialect(), "rl_settings", []string{`"key"`, "value"}, []string{`"key"`}, []string{"value"}), key, *value)
}

// Email reports

func reportRow(r Row) ReportRow {
	return ReportRow{ID: str(r["id"]), Site: str(r["site"]), Email: str(r["email"]), Frequency: str(r["frequency"]), Lang: strOr(r["lang"], "en"),
		Token: str(r["token"]), Origin: strOr(r["origin"], ""), LastPeriod: strOr(r["last_period"], ""), LastSentAt: nullableInt(r["last_sent_at"]),
		CreatedAt: numInt(r["created_at"])}
}

// Reports are the email report subscriptions, of one site or ("") all.
func (s *Store) Reports(ctx context.Context, site string) ([]ReportRow, error) {
	var rows []Row
	var err error
	if site != "" {
		rows, err = s.db.All(ctx, `SELECT * FROM rl_reports WHERE site = ? ORDER BY created_at, id`, site)
	} else {
		rows, err = s.db.All(ctx, `SELECT * FROM rl_reports ORDER BY created_at, id`)
	}
	if err != nil {
		return nil, err
	}
	out := []ReportRow{}
	for _, r := range rows {
		out = append(out, reportRow(r))
	}
	return out, nil
}

// ReportBy is the subscription with an id or (field "token") an unsubscribe key.
func (s *Store) ReportBy(ctx context.Context, field, value string) (*ReportRow, error) {
	col := "id"
	if field == "token" {
		col = "token"
	}
	rows, err := s.db.All(ctx, `SELECT * FROM rl_reports WHERE `+col+` = ?`, value)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	r := reportRow(rows[0])
	return &r, nil
}

// InsertReport records a subscription.
func (s *Store) InsertReport(ctx context.Context, r ReportRow) error {
	return s.db.Run(ctx, `INSERT INTO rl_reports (id, site, email, frequency, lang, token, origin, last_period, last_sent_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		r.ID, r.Site, r.Email, r.Frequency, r.Lang, r.Token, r.Origin, r.LastPeriod, r.LastSentAt, r.CreatedAt)
}

// ClaimReport records a period as sent. Only one caller wins, so two cron
// runs at once cannot both send it.
func (s *Store) ClaimReport(ctx context.Context, id, period string, now int64) (bool, error) {
	// One statement, so of two cron runs at once only one gets the row back.
	n, err := s.changed(ctx, `UPDATE rl_reports SET last_period = ?, last_sent_at = ? WHERE id = ? AND last_period <> ?`, period, now, id, period)
	return n == 1, err
}

// ReleaseReport puts a period back when its email failed, so the next run tries again.
func (s *Store) ReleaseReport(ctx context.Context, id, period, previous string) error {
	return s.db.Run(ctx, `UPDATE rl_reports SET last_period = ? WHERE id = ? AND last_period = ?`, previous, id, period)
}

// DeleteReport deletes a subscription.
func (s *Store) DeleteReport(ctx context.Context, id string) error {
	return s.db.Run(ctx, `DELETE FROM rl_reports WHERE id = ?`, id)
}

// Goals

func goalRow(r Row) GoalRow {
	return GoalRow{ID: str(r["id"]), Site: str(r["site"]), Name: str(r["name"]), Kind: str(r["kind"]), Match: str(r["match"]), ClickBy: strOr(r["click_by"], ""),
		ValueMode: str(r["value_mode"]), Value: num(r["value"]), ValueProp: strOr(r["value_prop"], ""), Currency: strOr(r["currency"], "USD"), CreatedAt: numInt(r["created_at"])}
}

// Goals are the goals of one site or ("") all, oldest first.
func (s *Store) Goals(ctx context.Context, site string) ([]GoalRow, error) {
	var rows []Row
	var err error
	if site != "" {
		rows, err = s.db.All(ctx, `SELECT * FROM rl_goals WHERE site = ? ORDER BY created_at, id`, site)
	} else {
		rows, err = s.db.All(ctx, `SELECT * FROM rl_goals ORDER BY created_at, id`)
	}
	if err != nil {
		return nil, err
	}
	out := []GoalRow{}
	for _, r := range rows {
		out = append(out, goalRow(r))
	}
	return out, nil
}

// GoalByID is a goal by its id.
func (s *Store) GoalByID(ctx context.Context, id string) (*GoalRow, error) {
	rows, err := s.db.All(ctx, `SELECT * FROM rl_goals WHERE id = ?`, id)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	g := goalRow(rows[0])
	return &g, nil
}

// SaveGoal records a goal, new or changed (before is what it was).
func (s *Store) SaveGoal(ctx context.Context, g GoalRow, before *GoalRow) error {
	// A click goal is counted by its name, which the tracker sends as the event
	// name. Renaming one renames its past clicks too, so its history stays.
	if before != nil && before.Kind == "click" && g.Kind == "click" && before.Name != g.Name {
		if err := s.db.Run(ctx, `UPDATE rl_events SET name = ? WHERE site = ? AND kind = 'event' AND name = ?`, g.Name, g.Site, before.Name); err != nil {
			return err
		}
	}
	return s.db.Run(ctx, upsert(s.dialect(), "rl_goals",
		[]string{"id", "site", "name", "kind", `"match"`, "click_by", "value_mode", "value", "value_prop", "currency", "created_at"},
		[]string{"id"},
		[]string{"name", "kind", `"match"`, "click_by", "value_mode", "value", "value_prop", "currency"}),
		g.ID, g.Site, g.Name, g.Kind, g.Match, g.ClickBy, g.ValueMode, g.Value, g.ValueProp, g.Currency, g.CreatedAt)
}

// DeleteGoal deletes a goal.
func (s *Store) DeleteGoal(ctx context.Context, id string) error {
	return s.db.Run(ctx, `DELETE FROM rl_goals WHERE id = ?`, id)
}

// goalScope is the events a goal counts, as a WHERE fragment over rl_events e.
func (s *Store) goalScope(goal GoalRow) sqlPart {
	if goal.Kind == "page" {
		if !strings.Contains(goal.Match, "*") {
			return sqlPart{"e.kind = 'pageview' AND e.path = ?", []any{goal.Match}}
		}
		if s.dialect() != "sqlite" {
			// Postgres's LIKE heeds case, and so does MySQL's under Runlight's binary collation.
			return sqlPart{`e.kind = 'pageview' AND e.path LIKE ? ESCAPE '\'`, []any{likePattern(goal.Match)}}
		}
		// SQLite's LIKE ignores case; GLOB does not, so every database agrees with the others and with exact matches.
		return sqlPart{"e.kind = 'pageview' AND e.path GLOB ?", []any{globPattern(goal.Match)}}
	}
	// Event goals count the named event; click goals count the event the tracker sends for them.
	name := goal.Match
	if goal.Kind == "click" {
		name = goal.Name
	}
	return sqlPart{"e.kind = 'event' AND e.name = ?", []any{name}}
}

// propValue is a numeric event property for one row, as SQL (0 when it is
// not a number). Property names are checked before they get here.
func (s *Store) propValue(prop string) sqlPart {
	if s.dialect() == "postgres" {
		return sqlPart{`(CASE WHEN (e.props::jsonb ->> ?) ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (e.props::jsonb ->> ?)::numeric ELSE 0 END)`, []any{prop, prop}}
	}
	path := `$."` + prop + `"`
	repeat := func(n int) []any {
		out := make([]any, n)
		for i := range out {
			out[i] = path
		}
		return out
	}
	if s.dialect() == "mysql" {
		// As SQLite: a JSON number as it is, or text of digits with an optional sign and one decimal point.
		value := "JSON_EXTRACT(e.props, ?)"
		return sqlPart{`(CASE
          WHEN JSON_TYPE(` + value + `) IN ('INTEGER', 'UNSIGNED INTEGER', 'DOUBLE', 'DECIMAL') THEN CAST(` + value + ` AS DOUBLE)
          WHEN JSON_TYPE(` + value + `) = 'STRING' AND JSON_UNQUOTE(` + value + `) REGEXP '^-?[0-9]+([.][0-9]+)?$' THEN CAST(JSON_UNQUOTE(` + value + `) AS DOUBLE)
          ELSE 0 END)`, repeat(5)}
	}
	// As Postgres's pattern: a JSON number, or text of digits with an optional sign and one decimal point.
	text := "CAST(json_extract(e.props, ?) AS TEXT)"
	return sqlPart{`(CASE
        WHEN json_type(e.props, ?) IN ('integer', 'real') THEN json_extract(e.props, ?)
        WHEN json_type(e.props, ?) = 'text' AND ` + text + ` GLOB '[0-9]*' AND ` + text + ` NOT GLOB '*[^0-9.]*' AND ` + text + ` NOT GLOB '*.*.*' AND ` + text + ` NOT GLOB '*.' THEN CAST(` + text + ` AS REAL)
        WHEN json_type(e.props, ?) = 'text' AND ` + text + ` GLOB '-[0-9]*' AND substr(` + text + `, 2) NOT GLOB '*[^0-9.]*' AND ` + text + ` NOT GLOB '*.*.*' AND ` + text + ` NOT GLOB '*.' THEN CAST(` + text + ` AS REAL)
        ELSE 0 END)`, repeat(14)}
}

// textOrder breaks ties by the value in code point order, the order the
// rolled-up path sorts in, so a report reads the same before and after its
// days are built.
func (s *Store) textOrder() string {
	switch s.dialect() {
	case "postgres":
		return ` COLLATE "C"`
	case "mysql":
		return " COLLATE " + MySQLCollation
	}
	return ""
}

// EventPropKeys are the property names sent with an event in a query's range, most used first.
func (s *Store) EventPropKeys(ctx context.Context, query Query, event string) ([]PropKey, error) {
	v := visitRows(query.Filters, query.Site, query.From, query.To, s.dialect())
	where := v.sql + " AND e.kind = 'event' AND e.name = ? AND e.props IS NOT NULL"
	params := append(append([]any{}, v.params...), event)
	var sql string
	switch s.dialect() {
	case "mysql":
		// Each key as a row of its own, compared and sorted by code point like every other value.
		sql = `SELECT j.k AS "key", COUNT(*) AS events FROM ` + v.from + `
             CROSS JOIN JSON_TABLE(JSON_KEYS(CASE WHEN JSON_TYPE(e.props) = 'OBJECT' THEN e.props ELSE '{}' END), '$[*]' COLUMNS (k VARCHAR(255) COLLATE ` + MySQLCollation + ` PATH '$')) j
             WHERE ` + where + ` GROUP BY j.k ORDER BY events DESC, j.k LIMIT 30`
	case "postgres":
		sql = `SELECT k AS "key", COUNT(*) AS events FROM ` + v.from + ` CROSS JOIN LATERAL jsonb_object_keys(CASE WHEN jsonb_typeof(e.props::jsonb) = 'object' THEN e.props::jsonb ELSE '{}'::jsonb END) AS k
             WHERE ` + where + ` GROUP BY k ORDER BY events DESC, k` + s.textOrder() + ` LIMIT 30`
	default:
		sql = `SELECT j.key AS "key", COUNT(*) AS events FROM ` + v.from + `, json_each(e.props) j
             WHERE ` + where + ` AND json_type(e.props) = 'object' GROUP BY j.key ORDER BY events DESC, key` + s.textOrder() + ` LIMIT 30`
	}
	rows, err := s.db.All(ctx, sql, params...)
	if err != nil {
		return nil, err
	}
	out := []PropKey{}
	for _, r := range rows {
		out = append(out, PropKey{Key: str(r["key"]), Events: numInt(r["events"])})
	}
	return out, nil
}

// EventPropValues are the values one property of an event took, with how
// often and by how many visitors.
func (s *Store) EventPropValues(ctx context.Context, query Query, event, key string, limit int) ([]PropValue, error) {
	v := visitRows(query.Filters, query.Site, query.From, query.To, s.dialect())
	value := "CAST(json_extract(e.props, ?) AS TEXT)"
	path := `$."` + key + `"`
	switch s.dialect() {
	case "postgres":
		value = "(e.props::jsonb ->> ?)"
		path = key
	case "mysql":
		value = "(JSON_UNQUOTE(JSON_EXTRACT(e.props, ?)) COLLATE " + MySQLCollation + ")"
	}
	params := append([]any{path}, v.params...)
	params = append(params, event, path, int64(limit))
	rows, err := s.db.All(ctx, `SELECT * FROM (SELECT `+value+` AS value, COUNT(*) AS events, COUNT(DISTINCT e.visitor) AS visitors FROM `+v.from+`
         WHERE `+v.sql+` AND e.kind = 'event' AND e.name = ? AND `+value+` IS NOT NULL GROUP BY 1) t
       ORDER BY events DESC, value`+s.textOrder()+` LIMIT ?`, params...)
	if err != nil {
		return nil, err
	}
	out := []PropValue{}
	for _, r := range rows {
		out = append(out, PropValue{Value: str(r["value"]), Events: numInt(r["events"]), Visitors: numInt(r["visitors"])})
	}
	return out, nil
}

// double is the floating point type to cast to, which MySQL names in one word.
func (s *Store) double() string {
	if s.dialect() == "mysql" {
		return "DOUBLE"
	}
	return "DOUBLE PRECISION"
}

// revenueValue is a goal's worth for one converting row, as SQL.
func (s *Store) revenueValue(goal GoalRow) sqlPart {
	if goal.ValueMode == "prop" && goal.ValueProp != "" {
		return s.propValue(goal.ValueProp)
	}
	if goal.ValueMode == "fixed" {
		return sqlPart{"CAST(? AS " + s.double() + ")", []any{goal.Value}}
	}
	return sqlPart{"0", nil}
}

// GoalTotalsAll is every goal's totals in one pass over the range's events,
// instead of a query per goal: each goal adds a conditional count, distinct
// count, and sum.
func (s *Store) GoalTotalsAll(ctx context.Context, query Query, goals []GoalRow) (map[string]GoalTotals, error) {
	out := map[string]GoalTotals{}
	v := visitRows(query.Filters, query.Site, query.From, query.To, s.dialect())
	// As many goals per query as keep it under D1's parameter limit.
	chunks := [][]GoalRow{{}}
	count := len(v.params)
	for _, goal := range goals {
		cost := len(s.goalScope(goal).params)*4 + len(s.revenueValue(goal).params)
		if len(chunks[len(chunks)-1]) > 0 && count+cost > maxParams {
			chunks = append(chunks, []GoalRow{})
			count = len(v.params)
		}
		chunks[len(chunks)-1] = append(chunks[len(chunks)-1], goal)
		count += cost
	}
	for _, chunk := range chunks {
		if len(chunk) == 0 {
			continue
		}
		columns := []string{}
		params := []any{}
		// Only rows some goal of the chunk counts are read.
		anys := []string{}
		anyParams := []any{}
		for i, goal := range chunk {
			scope := s.goalScope(goal)
			value := s.revenueValue(goal)
			columns = append(columns,
				fmt.Sprintf("SUM(CASE WHEN %s THEN 1 ELSE 0 END) AS c%d", scope.sql, i),
				fmt.Sprintf("COUNT(DISTINCT CASE WHEN %s THEN e.visitor END) AS v%d", scope.sql, i),
				fmt.Sprintf("SUM(CASE WHEN %s THEN %s ELSE 0 END) AS r%d", scope.sql, value.sql, i))
			params = append(params, scope.params...)
			params = append(params, scope.params...)
			params = append(params, scope.params...)
			params = append(params, value.params...)
			anys = append(anys, "("+scope.sql+")")
			anyParams = append(anyParams, scope.params...)
		}
		params = append(append(params, v.params...), anyParams...)
		rows, err := s.db.All(ctx, `SELECT `+strings.Join(columns, ", ")+` FROM `+v.from+`
         WHERE `+v.sql+` AND e.kind IN ('pageview', 'event') AND (`+strings.Join(anys, " OR ")+`)`, params...)
		if err != nil {
			return nil, err
		}
		row := Row{}
		if len(rows) > 0 {
			row = rows[0]
		}
		for i, goal := range chunk {
			out[goal.ID] = GoalTotals{Conversions: numInt(row[fmt.Sprintf("c%d", i)]), Visitors: numInt(row[fmt.Sprintf("v%d", i)]), Revenue: round2(num(row[fmt.Sprintf("r%d", i)]))}
		}
	}
	return out, nil
}

func (s *Store) revenueSQL(goal GoalRow) sqlPart {
	if goal.ValueMode == "prop" && goal.ValueProp != "" {
		value := s.propValue(goal.ValueProp)
		return sqlPart{"SUM(" + value.sql + ")", value.params}
	}
	// Cast, so Postgres does not read the bound value as a bigint and refuse 9.99.
	if goal.ValueMode == "fixed" {
		return sqlPart{"COUNT(*) * CAST(? AS " + s.double() + ")", []any{goal.Value}}
	}
	return sqlPart{"0", nil}
}

// GoalTotals is one goal's conversions, converting visitors, and revenue for a query's range and filters.
func (s *Store) GoalTotals(ctx context.Context, query Query, goal GoalRow) (GoalTotals, error) {
	v := visitRows(query.Filters, query.Site, query.From, query.To, s.dialect())
	scope := s.goalScope(goal)
	revenue := s.revenueSQL(goal)
	params := append(append(append([]any{}, revenue.params...), v.params...), scope.params...)
	rows, err := s.db.All(ctx, `SELECT COUNT(*) AS conversions, COUNT(DISTINCT e.visitor) AS visitors, `+revenue.sql+` AS revenue
       FROM `+v.from+` WHERE `+v.sql+` AND `+scope.sql, params...)
	if err != nil {
		return GoalTotals{}, err
	}
	row := Row{}
	if len(rows) > 0 {
		row = rows[0]
	}
	return GoalTotals{Conversions: numInt(row["conversions"]), Visitors: numInt(row["visitors"]), Revenue: round2(num(row["revenue"]))}, nil
}

// GoalBreakdown is a goal's conversions split by where the visit came from
// (source, channel), or by the page it happened on (path).
func (s *Store) GoalBreakdown(ctx context.Context, query Query, goal GoalRow, by string, limit int) ([]GoalBreakdownRow, error) {
	v := visitRows(query.Filters, query.Site, query.From, query.To, s.dialect())
	col := "s." + by
	if by == "path" {
		col = "e.path"
	}
	scope := s.goalScope(goal)
	revenue := s.revenueSQL(goal)
	params := append(append(append([]any{}, revenue.params...), v.params...), scope.params...)
	params = append(params, int64(limit))
	rows, err := s.db.All(ctx, `SELECT `+col+` AS value, COUNT(*) AS conversions, COUNT(DISTINCT e.visitor) AS visitors, `+revenue.sql+` AS revenue
       FROM `+v.from+` WHERE `+v.sql+` AND `+scope.sql+`
       GROUP BY `+col+` ORDER BY conversions DESC, `+col+s.textOrder()+` LIMIT ?`, params...)
	if err != nil {
		return nil, err
	}
	out := []GoalBreakdownRow{}
	for _, r := range rows {
		out = append(out, GoalBreakdownRow{Value: strOr(r["value"], ""), GoalTotals: GoalTotals{Conversions: numInt(r["conversions"]), Visitors: numInt(r["visitors"]), Revenue: round2(num(r["revenue"]))}})
	}
	return out, nil
}

// GoalSeries is a goal's conversions and revenue in each bucket, by when each visit started.
func (s *Store) GoalSeries(ctx context.Context, site string, filters []Filter, goal GoalRow, buckets []Bucket) ([]GoalSeriesPoint, error) {
	if len(buckets) == 0 {
		return []GoalSeriesPoint{}, nil
	}
	scope := s.goalScope(goal)
	revenue := s.revenueSQL(goal)
	// Each bucket binds three values; the rest are fixed. As many buckets a statement as keep it under D1's 100.
	fixed := len(revenue.params) + len(scope.params) + len(visitRows(filters, site, 0, 0, s.dialect()).params)
	size := max(1, min(bucketsPerQuery, (maxParams-fixed)/3))
	if len(buckets) > size {
		out := []GoalSeriesPoint{}
		for i := 0; i < len(buckets); i += size {
			piece, err := s.GoalSeries(ctx, site, filters, goal, buckets[i:min(i+size, len(buckets))])
			if err != nil {
				return nil, err
			}
			out = append(out, piece...)
		}
		return out, nil
	}
	v := visitRows(filters, site, buckets[0].Start, buckets[len(buckets)-1].End, s.dialect())
	params := append(bucketParams(buckets), revenue.params...)
	params = append(append(params, v.params...), scope.params...)
	rows, err := s.db.All(ctx, `WITH b (i, bs, be) AS (`+bucketTable(s.dialect(), buckets)+`)
       SELECT b.i AS i, COUNT(*) AS conversions, `+revenue.sql+` AS revenue
       FROM `+v.from+` CROSS JOIN b
       WHERE `+v.sql+` AND s.started_at >= b.bs AND s.started_at < b.be AND `+scope.sql+`
       GROUP BY b.i`, params...)
	if err != nil {
		return nil, err
	}
	found := map[int64]Row{}
	for _, r := range rows {
		found[numInt(r["i"])] = r
	}
	out := make([]GoalSeriesPoint, len(buckets))
	for i, b := range buckets {
		r := found[int64(i)]
		out[i] = GoalSeriesPoint{Start: b.Start, Conversions: numInt(r["conversions"]), Revenue: round2(num(r["revenue"]))}
	}
	return out, nil
}

// LinkDomains are the custom link domains, by name.
func (s *Store) LinkDomains(ctx context.Context) ([]LinkDomain, error) {
	rows, err := s.db.All(ctx, `SELECT domain, site FROM rl_link_domains ORDER BY domain`)
	if err != nil {
		return nil, err
	}
	out := []LinkDomain{}
	for _, r := range rows {
		out = append(out, LinkDomain{Domain: str(r["domain"]), Site: str(r["site"])})
	}
	return out, nil
}

// AddLinkDomain records a link domain for a site.
func (s *Store) AddLinkDomain(ctx context.Context, domain, site string, now int64) error {
	return s.db.Run(ctx, upsert(s.dialect(), "rl_link_domains", []string{"domain", "site", "created_at"}, []string{"domain"}, nil), domain, site, now)
}

// RemoveLinkDomain removes a domain. Its links keep it as their home and
// fall back to the app's own link path until the domain is added again.
func (s *Store) RemoveLinkDomain(ctx context.Context, domain string) error {
	return s.db.Run(ctx, `DELETE FROM rl_link_domains WHERE domain = ?`, domain)
}

// Links are a site's links, newest first, with their clicks in a range.
// Clicks imported as daily counts have no visitor, so they add to clicks only.
func (s *Store) Links(ctx context.Context, site string, from, to int64) ([]LinkWithStats, error) {
	rows, err := s.db.All(ctx, `SELECT l.*, COALESCE(c.clicks, 0) AS clicks, COALESCE(c.visitors, 0) AS visitors
       FROM rl_links l LEFT JOIN (
         SELECT link, COUNT(*) AS clicks, COUNT(DISTINCT NULLIF(visitor, '')) AS visitors FROM rl_events
         WHERE site = ? AND kind = 'click' AND ts >= ? AND ts < ? GROUP BY link
       ) c ON c.link = l.id
       WHERE l.site = ? AND l.deleted_at IS NULL
       ORDER BY l.created_at DESC, l.id`, site, from, to, site)
	if err != nil {
		return nil, err
	}
	out := []LinkWithStats{}
	for _, r := range rows {
		out = append(out, LinkWithStats{LinkRow: linkRow(r), Clicks: numInt(r["clicks"]), Visitors: numInt(r["visitors"])})
	}
	return out, nil
}

// LinkSeries is one link's clicks per bucket.
func (s *Store) LinkSeries(ctx context.Context, site, link string, buckets []Bucket) ([]LinkSeriesPoint, error) {
	if len(buckets) == 0 {
		return []LinkSeriesPoint{}, nil
	}
	if len(buckets) > bucketsPerQuery {
		out := []LinkSeriesPoint{}
		for i := 0; i < len(buckets); i += bucketsPerQuery {
			piece, err := s.LinkSeries(ctx, site, link, buckets[i:min(i+bucketsPerQuery, len(buckets))])
			if err != nil {
				return nil, err
			}
			out = append(out, piece...)
		}
		return out, nil
	}
	params := append(bucketParams(buckets), link, site)
	rows, err := s.db.All(ctx, `WITH b (i, bs, be) AS (`+bucketTable(s.dialect(), buckets)+`)
       SELECT b.i AS i, COUNT(*) AS clicks, COUNT(DISTINCT NULLIF(e.visitor, '')) AS visitors
       FROM b JOIN rl_events e ON e.link = ? AND e.ts >= b.bs AND e.ts < b.be
       WHERE e.site = ? AND e.kind = 'click' GROUP BY b.i`, params...)
	if err != nil {
		return nil, err
	}
	found := map[int64]Row{}
	for _, r := range rows {
		found[numInt(r["i"])] = r
	}
	out := make([]LinkSeriesPoint, len(buckets))
	for i, b := range buckets {
		r := found[int64(i)]
		out[i] = LinkSeriesPoint{Start: b.Start, Clicks: numInt(r["clicks"]), Visitors: numInt(r["visitors"])}
	}
	return out, nil
}

// LinkBreakdown is one link's clicks by a visit dimension: where they came
// from, where they were, what they used.
func (s *Store) LinkBreakdown(ctx context.Context, site, link string, from, to int64, dimension string, limit int) ([]BreakdownRow, error) {
	col := "s." + sessionColumn(dimension)
	rows, err := s.db.All(ctx, `SELECT `+col+` AS value, COUNT(*) AS clicks, COUNT(DISTINCT e.visitor) AS visitors
       FROM rl_events e JOIN rl_sessions s ON s.id = e.session
       WHERE e.site = ? AND e.link = ? AND e.kind = 'click' AND e.ts >= ? AND e.ts < ? AND `+col+` <> ''
       GROUP BY `+col+` ORDER BY clicks DESC, `+col+s.textOrder()+` LIMIT ?`, site, link, from, to, int64(limit))
	if err != nil {
		return nil, err
	}
	out := []BreakdownRow{}
	for _, r := range rows {
		out = append(out, BreakdownRow{Value: str(r["value"]), Visitors: numInt(r["visitors"]), Events: i64(numInt(r["clicks"]))})
	}
	return out, nil
}

// Reports

// FirstOwnVisit is when Runlight itself first counted a visit, leaving out imported history.
func (s *Store) FirstOwnVisit(ctx context.Context, site string) (*int64, error) {
	// A session opened only by a short link click is not a visit, so it does not count as the first.
	rows, err := s.db.All(ctx, `SELECT MIN(started_at) AS t FROM rl_sessions s WHERE s.site = ? AND s.imported = 0 AND `+isVisit, site)
	return nullableTime(rows), err
}

// FirstSeen is when the site's first visit was recorded, or nil with no data yet.
func (s *Store) FirstSeen(ctx context.Context, site string) (*int64, error) {
	rows, err := s.db.All(ctx, `SELECT MIN(started_at) AS t FROM rl_sessions WHERE site = ?`, site)
	return nullableTime(rows), err
}

// Visitors is just the visitor count from Stats, in one query, for conversion rates.
func (s *Store) Visitors(ctx context.Context, query Query) (int64, error) {
	scope := visitScope(query.Filters, query.Site, query.From, query.To, s.dialect())
	rows, err := s.db.All(ctx, `SELECT COUNT(DISTINCT s.visitor) AS visitors FROM rl_sessions s WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND `+isVisit+scope.sql,
		append([]any{query.Site, query.From, query.To}, scope.params...)...)
	if err != nil || len(rows) == 0 {
		return 0, err
	}
	return numInt(rows[0]["visitors"]), nil
}

func pvColumn(pv *sqlPart) string {
	if pv != nil {
		return "COALESCE(pv.n, 0)"
	}
	return "s.pageviews"
}

func pvJoin(pv *sqlPart) string {
	if pv != nil {
		return "LEFT JOIN " + pv.sql + " pv ON pv.session = s.id"
	}
	return ""
}

func pvParams(pv *sqlPart) []any {
	if pv != nil {
		return pv.params
	}
	return nil
}

// Stats are a range's headline numbers.
func (s *Store) Stats(ctx context.Context, query Query) (Stats, error) {
	rolled, err := s.rolledStats(ctx, query)
	if err != nil {
		return Stats{}, err
	}
	if rolled != nil {
		return *rolled, nil
	}
	// Filtered or not, the numbers describe visits that started in the range (see visitScope).
	scope := visitScope(query.Filters, query.Site, query.From, query.To, s.dialect())
	pv := pageviewsOf(query.Filters, query.Site, query.From, query.To, s.dialect())
	params := append(append([]any{}, pvParams(pv)...), query.Site, query.From, query.To)
	params = append(params, scope.params...)
	rows, err := s.db.All(ctx, `SELECT COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits, SUM(`+pvColumn(pv)+`) AS pageviews,
         SUM(CASE WHEN `+bounce+` THEN 1 ELSE 0 END) AS bounced, SUM(`+duration+`) AS duration
       FROM rl_sessions s `+pvJoin(pv)+`
       WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND `+isVisit+scope.sql, params...)
	if err != nil {
		return Stats{}, err
	}
	row := Row{}
	if len(rows) > 0 {
		row = rows[0]
	}
	return *statsOf(num(row["visitors"]), num(row["visits"]), num(row["pageviews"]), num(row["bounced"]), num(row["duration"])), nil
}

// Series is the chart: each bucket's numbers.
func (s *Store) Series(ctx context.Context, site string, filters []Filter, buckets []Bucket) ([]SeriesPoint, error) {
	if len(buckets) == 0 {
		return []SeriesPoint{}, nil
	}
	if len(buckets) > bucketsPerQuery {
		out := []SeriesPoint{}
		for i := 0; i < len(buckets); i += bucketsPerQuery {
			piece, err := s.Series(ctx, site, filters, buckets[i:min(i+bucketsPerQuery, len(buckets))])
			if err != nil {
				return nil, err
			}
			out = append(out, piece...)
		}
		return out, nil
	}
	first, last := buckets[0].Start, buckets[len(buckets)-1].End
	params := bucketParams(buckets)
	// Filtered or not, each bucket counts the visits that started in it (see visitScope).
	scope := visitScope(filters, site, first, last, s.dialect())
	pv := pageviewsOf(filters, site, first, last, s.dialect())
	// Built days that fit inside one bucket come from rollups; the rest from the visits.
	plan, err := s.rollupPlan(ctx, site, filters, first, last)
	if err != nil {
		return nil, err
	}
	inBucket := func(d builtDay) int {
		for i, b := range buckets {
			if b.Start <= d.start && d.end <= b.End {
				return i
			}
		}
		return -1
	}
	used := []builtDay{}
	if plan != nil {
		for _, d := range plan.days {
			if inBucket(d) >= 0 {
				used = append(used, d)
			}
		}
	}
	var rest [][2]int64
	if len(used) > 0 {
		rest = [][2]int64{}
		from := first
		for _, d := range used {
			if d.start > from {
				rest = append(rest, [2]int64{from, d.start})
			}
			from = max(from, d.end)
		}
		if from < last {
			rest = append(rest, [2]int64{from, last})
		}
	}
	// MySQL joins the buckets to every visit of the site unless told the whole range as well.
	w := sqlPart{"1 = 1", nil}
	if rest != nil {
		w = within(rest)
	} else if s.dialect() == "mysql" {
		w = within([][2]int64{{first, last}})
	}
	// Filters and scattered unbuilt days add values of their own; when they would pass D1's 100, the
	// buckets go in halves.
	if len(params)+1+len(w.params)+len(scope.params)+len(pvParams(pv)) > maxParams && len(buckets) > 1 {
		half := (len(buckets) + 1) / 2
		a, err := s.Series(ctx, site, filters, buckets[:half])
		if err != nil {
			return nil, err
		}
		b, err := s.Series(ctx, site, filters, buckets[half:])
		if err != nil {
			return nil, err
		}
		return append(a, b...), nil
	}
	type sum struct{ visitors, n, views, bounced, duration float64 }
	sums := map[int]*sum{}
	bump := func(i int, row Row) {
		into, ok := sums[i]
		if !ok {
			into = &sum{}
			sums[i] = into
		}
		into.visitors += num(row["visitors"])
		into.n += num(row["n"])
		into.views += num(row["views"])
		into.bounced += num(row["bounced"])
		into.duration += num(row["duration"])
	}
	if len(used) > 0 {
		rolled, err := s.db.All(ctx, `SELECT day, visitors, visits AS n, pageviews AS views, bounced, duration FROM rl_rollups WHERE site = ? AND dim = '' AND day IN (`+builtDays+`)`,
			site, site, first, last)
		if err != nil {
			return nil, err
		}
		at := map[string]int{}
		for _, d := range used {
			at[d.day] = inBucket(d)
		}
		for _, row := range rolled {
			if i, ok := at[str(row["day"])]; ok {
				bump(i, row)
			}
		}
	}
	params = append(params, site)
	params = append(params, pvParams(pv)...)
	params = append(params, scope.params...)
	params = append(params, w.params...)
	rows, err := s.db.All(ctx, `WITH b (i, bs, be) AS (`+bucketTable(s.dialect(), buckets)+`)
       SELECT b.i AS i, COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS n, SUM(`+pvColumn(pv)+`) AS views,
         SUM(CASE WHEN `+bounce+` THEN 1 ELSE 0 END) AS bounced, SUM(`+duration+`) AS duration
       FROM b JOIN rl_sessions s ON s.site = ? AND s.started_at >= b.bs AND s.started_at < b.be
       `+pvJoin(pv)+`
       WHERE `+isVisit+scope.sql+` AND `+w.sql+`
       GROUP BY b.i`, params...)
	if err != nil {
		return nil, err
	}
	for _, row := range rows {
		bump(int(numInt(row["i"])), row)
	}
	out := make([]SeriesPoint, len(buckets))
	for i, b := range buckets {
		row := sums[i]
		if row == nil {
			row = &sum{}
		}
		p := SeriesPoint{Start: b.Start, Visitors: int64(row.visitors), Visits: int64(row.n), Pageviews: int64(row.views)}
		if row.n > 0 {
			p.ViewsPerVisit = round2(row.views / row.n)
			p.BounceRate = row.bounced / row.n
			p.VisitDuration = jsRound(row.duration / row.n)
		}
		out[i] = p
	}
	return out, nil
}

// Breakdown is a dimension's values for a range, most visited first.
func (s *Store) Breakdown(ctx context.Context, query Query, dimension string, limit, offset int) ([]BreakdownRow, error) {
	page := []any{int64(limit), int64(offset)}
	if dimension == "ai_agent" || dimension == "ai_page" {
		col := "e.path"
		if dimension == "ai_agent" {
			col = "e.name"
		}
		rows, err := s.db.All(ctx, `SELECT `+col+` AS value, COUNT(*) AS fetches FROM rl_events e
         WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'fetch'
         GROUP BY `+col+` ORDER BY fetches DESC, `+col+s.textOrder()+` LIMIT ? OFFSET ?`, append([]any{query.Site, query.From, query.To}, page...)...)
		if err != nil {
			return nil, err
		}
		out := []BreakdownRow{}
		for _, r := range rows {
			out = append(out, BreakdownRow{Value: str(r["value"]), Visitors: 0, Fetches: i64(numInt(r["fetches"]))})
		}
		return out, nil
	}

	rolled, ok, err := s.rolledBreakdown(ctx, query, dimension, limit, offset)
	if err != nil {
		return nil, err
	}
	if ok {
		return rolled, nil
	}

	// Filtered or not, the visits are those that started in the range (see visitScope).
	scope := visitScope(query.Filters, query.Site, query.From, query.To, s.dialect())
	if IsSessionDimension(dimension) {
		pv := pageviewsOf(query.Filters, query.Site, query.From, query.To, s.dialect())
		col := "s." + sessionColumn(dimension)
		entryExit := dimension == "entry" || dimension == "exit"
		order := "visitors DESC, visits DESC"
		if entryExit {
			order = "visits DESC"
		}
		params := append(append([]any{}, pvParams(pv)...), query.Site, query.From, query.To)
		params = append(append(params, scope.params...), page...)
		rows, err := s.db.All(ctx, `SELECT `+col+` AS value, COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits, SUM(`+pvColumn(pv)+`) AS pageviews,
           SUM(CASE WHEN `+bounce+` THEN 1 ELSE 0 END) AS bounced, SUM(`+duration+`) AS duration
         FROM rl_sessions s `+pvJoin(pv)+`
         WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND `+isVisit+scope.sql+` AND `+col+` <> ''
         GROUP BY `+col+` ORDER BY `+order+`, `+col+s.textOrder()+` LIMIT ? OFFSET ?`, params...)
		if err != nil {
			return nil, err
		}
		out := []BreakdownRow{}
		for _, r := range rows {
			visits := num(r["visits"])
			row := BreakdownRow{Value: str(r["value"]), Visitors: numInt(r["visitors"]), Visits: i64(int64(visits)), BounceRate: f64(0)}
			if visits > 0 {
				row.BounceRate = f64(num(r["bounced"]) / visits)
			}
			if !entryExit {
				row.Pageviews = i64(numInt(r["pageviews"]))
				row.VisitDuration = i64(0)
				if visits > 0 {
					row.VisitDuration = i64(jsRound(num(r["duration"]) / visits))
				}
			}
			out = append(out, row)
		}
		return out, nil
	}

	// Rows from the visits that started in the range and that the filters pick, narrowed by any filter on
	// the same kind of row ("page is /pricing" on pages), as the rollups count them.
	withinVisits := func(dimensions []string) (sqlPart, int64) {
		rows := rowScope(query.Filters, dimensions, s.dialect())
		params := append([]any{query.Site, query.From, query.To}, scope.params...)
		return sqlPart{
			" AND e.session IN (SELECT s.id FROM rl_sessions s WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND " + isVisit + scope.sql + ")" + rows.sql,
			append(params, rows.params...),
		}, query.To + EventTailMs
	}

	if dimension == "page" || dimension == "hostname" {
		c, _ := lookupDimension(eventDimensions, dimension)
		col := "e." + c
		w, to := withinVisits([]string{"page", "hostname"})
		params := append([]any{query.Site, query.From, to}, w.params...)
		rows, err := s.db.All(ctx, `SELECT `+col+` AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(*) AS pageviews, `+liveViews+` AS views
         FROM rl_events e
         WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'pageview'`+w.sql+`
         GROUP BY `+col+` ORDER BY visitors DESC, pageviews DESC, `+col+s.textOrder()+` LIMIT ? OFFSET ?`, append(params, page...)...)
		if err != nil {
			return nil, err
		}
		out := []BreakdownRow{}
		live := map[string]float64{}
		for _, r := range rows {
			out = append(out, BreakdownRow{Value: str(r["value"]), Visitors: numInt(r["visitors"]), Pageviews: i64(numInt(r["pageviews"]))})
			live[str(r["value"])] = num(r["views"])
		}
		if dimension == "page" && len(out) > 0 {
			// Each pageview's engaged time added up and its deepest scroll, then the mean over pageviews. Filters add
			// values of their own, so fewer paths go in each statement, keeping it within D1's 100.
			size := max(1, min(valuesPerQuery, maxParams-3-len(w.params)))
			byPath := map[string]Row{}
			for i := 0; i < len(out); i += size {
				piece := out[i:min(i+size, len(out))]
				values := make([]any, len(piece))
				for k, row := range piece {
					values[k] = row.Value
				}
				p := append(append([]any{query.Site, query.From, to}, w.params...), values...)
				times, err := s.db.All(ctx, `SELECT value, SUM(total) AS total, COUNT(*) AS views, AVG(deepest) AS scroll FROM (
               SELECT e.path AS value, SUM(e.engaged_ms) AS total, MAX(e.scroll) AS deepest
               FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'engagement'`+w.sql+`
               AND e.path IN (`+placeholders(len(piece))+`) GROUP BY e.path, e.pageview) t GROUP BY value`, p...)
				if err != nil {
					return nil, err
				}
				for _, t := range times {
					byPath[str(t["value"])] = t
				}
			}
			for i := range out {
				time, ok := byPath[out[i].Value]
				views := live[out[i].Value]
				out[i].TimeOnPage = i64(0)
				if ok && views != 0 {
					out[i].TimeOnPage = i64(jsRound(num(time["total"]) / views))
				}
				out[i].ScrollDepth = i64(0)
				if ok && time["scroll"] != nil {
					out[i].ScrollDepth = i64(jsRound(num(time["scroll"])))
				}
			}
		}
		return out, nil
	}

	if dimension == "event" {
		w, to := withinVisits([]string{"event"})
		params := append([]any{query.Site, query.From, to}, w.params...)
		rows, err := s.db.All(ctx, `SELECT e.name AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(*) AS events
         FROM rl_events e
         WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'event'`+w.sql+`
         GROUP BY e.name ORDER BY visitors DESC, events DESC, e.name`+s.textOrder()+` LIMIT ? OFFSET ?`, append(params, page...)...)
		if err != nil {
			return nil, err
		}
		out := []BreakdownRow{}
		for _, r := range rows {
			out = append(out, BreakdownRow{Value: str(r["value"]), Visitors: numInt(r["visitors"]), Events: i64(numInt(r["events"]))})
		}
		return out, nil
	}
	return []BreakdownRow{}, nil
}

// Hourly is visits by quarter hour since the epoch, which the caller folds
// into local weekdays and hours, keeping time zones (DST included) out of
// SQL. Quarters, not hours, so a site in a half-hour or 45-minute timezone
// (India, Nepal) folds each into the right local hour.
func (s *Store) Hourly(ctx context.Context, query Query) ([]HourlyRow, error) {
	plan, err := s.rollupPlan(ctx, query.Site, query.Filters, query.From, query.To)
	if err != nil {
		return nil, err
	}
	if plan != nil {
		sums := map[int64]*HourlyRow{}
		order := []int64{}
		bump := func(quarter int64, row Row) {
			into, ok := sums[quarter]
			if !ok {
				into = &HourlyRow{Quarter: quarter}
				sums[quarter] = into
				order = append(order, quarter)
			}
			into.Visits += numInt(row["visits"])
			into.Visitors += numInt(row["visitors"])
			into.Pageviews += numInt(row["pageviews"])
			into.Bounced += numInt(row["bounced"])
		}
		rolled, err := s.db.All(ctx, `SELECT value, visits, visitors, pageviews, bounced FROM rl_rollups WHERE site = ? AND dim = 'quarter' AND day IN (`+builtDays+`)`,
			query.Site, query.Site, query.From, query.To)
		if err != nil {
			return nil, err
		}
		for _, row := range rolled {
			bump(int64(js.Number(str(row["value"]))), row)
		}
		w := within(plan.rest)
		raw, err := s.db.All(ctx, `SELECT `+div(s.dialect(), "s.started_at", 900000)+` AS quarter, COUNT(*) AS visits, COUNT(DISTINCT s.visitor) AS visitors,
           SUM(s.pageviews) AS pageviews, SUM(CASE WHEN `+bounce+` THEN 1 ELSE 0 END) AS bounced
         FROM rl_sessions s WHERE s.site = ? AND `+w.sql+` AND `+isVisit+` GROUP BY 1`, append([]any{query.Site}, w.params...)...)
		if err != nil {
			return nil, err
		}
		for _, row := range raw {
			bump(int64(math.Floor(num(row["quarter"]))), row)
		}
		out := make([]HourlyRow, len(order))
		for i, q := range order {
			out[i] = *sums[q]
		}
		return out, nil
	}
	matching := visitScope(query.Filters, query.Site, query.From, query.To, s.dialect())
	// A page filter counts that page's views as pageviews here too, as the cards do.
	pv := pageviewsOf(query.Filters, query.Site, query.From, query.To, s.dialect())
	params := append(append([]any{}, pvParams(pv)...), query.Site, query.From, query.To)
	params = append(params, matching.params...)
	rows, err := s.db.All(ctx, `SELECT `+div(s.dialect(), "s.started_at", 900000)+` AS quarter, COUNT(*) AS visits, COUNT(DISTINCT s.visitor) AS visitors,
         SUM(`+pvColumn(pv)+`) AS pageviews, SUM(CASE WHEN `+bounce+` THEN 1 ELSE 0 END) AS bounced
       FROM rl_sessions s `+pvJoin(pv)+`
       WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND `+isVisit+matching.sql+`
       GROUP BY 1`, params...)
	if err != nil {
		return nil, err
	}
	out := []HourlyRow{}
	for _, r := range rows {
		out = append(out, HourlyRow{Quarter: int64(math.Floor(num(r["quarter"]))), Visits: numInt(r["visits"]), Visitors: numInt(r["visitors"]),
			Pageviews: numInt(r["pageviews"]), Bounced: numInt(r["bounced"])})
	}
	return out, nil
}

// Realtime is what is happening now: the last five minutes, and the last
// half hour minute by minute.
func (s *Store) Realtime(ctx context.Context, site string, now int64) (Realtime, error) {
	since := now - 5*60_000
	pairs := func(rows []Row) []ValueCount {
		out := []ValueCount{}
		for _, r := range rows {
			out = append(out, ValueCount{Value: str(r["value"]), Visitors: numInt(r["visitors"])})
		}
		return out
	}
	active, err := s.db.All(ctx, `SELECT COUNT(DISTINCT visitor) AS n FROM rl_events WHERE site = ? AND ts >= ? AND kind IN ('pageview', 'event', 'engagement')`, site, since)
	if err != nil {
		return Realtime{}, err
	}
	pages, err := s.db.All(ctx, `SELECT path AS value, COUNT(DISTINCT visitor) AS visitors FROM rl_events
       WHERE site = ? AND ts >= ? AND kind = 'pageview' GROUP BY path ORDER BY visitors DESC, path`+s.textOrder()+` LIMIT 10`, site, since)
	if err != nil {
		return Realtime{}, err
	}
	sources, err := s.db.All(ctx, `SELECT s.source AS value, COUNT(DISTINCT e.visitor) AS visitors FROM rl_events e JOIN rl_sessions s ON s.id = e.session
       WHERE e.site = ? AND e.ts >= ? AND e.kind IN ('pageview', 'event') AND s.source <> ''
       GROUP BY s.source ORDER BY visitors DESC, s.source`+s.textOrder()+` LIMIT 10`, site, since)
	if err != nil {
		return Realtime{}, err
	}
	start := floorDiv(now, 60_000)*60_000 - 29*60_000
	perMinute, err := s.db.All(ctx, `SELECT `+div(s.dialect(), "(ts - ?)", 60000)+` AS m, COUNT(*) AS n FROM rl_events
       WHERE site = ? AND ts >= ? AND kind = 'pageview' GROUP BY 1`, start, site, start)
	if err != nil {
		return Realtime{}, err
	}
	minutes := make([]int64, 30)
	for _, row := range perMinute {
		index := int64(math.Floor(num(row["m"])))
		if index >= 0 && index < 30 {
			minutes[index] += numInt(row["n"])
		}
	}
	countries, err := s.db.All(ctx, `SELECT s.country AS value, COUNT(DISTINCT e.visitor) AS visitors FROM rl_events e JOIN rl_sessions s ON s.id = e.session
       WHERE e.site = ? AND e.ts >= ? AND e.kind IN ('pageview', 'event') AND s.country <> ''
       GROUP BY s.country ORDER BY visitors DESC, s.country`+s.textOrder()+` LIMIT 10`, site, since)
	if err != nil {
		return Realtime{}, err
	}
	recent, err := s.db.All(ctx, `SELECT e.ts, e.kind, e.path, e.name, s.country, s.city, s.source, s.device FROM rl_events e JOIN rl_sessions s ON s.id = e.session
       WHERE e.site = ? AND e.ts >= ? AND e.kind IN ('pageview', 'event') ORDER BY e.ts DESC, e.id DESC LIMIT 20`, site, start)
	if err != nil {
		return Realtime{}, err
	}
	out := Realtime{Pages: pairs(pages), Sources: pairs(sources), Countries: pairs(countries), Minutes: minutes, Recent: []RecentRow{}}
	if len(active) > 0 {
		out.Visitors = numInt(active[0]["n"])
	}
	for _, r := range recent {
		out.Recent = append(out.Recent, RecentRow{Ts: numInt(r["ts"]), Kind: str(r["kind"]), Path: strOr(r["path"], ""), Name: strOr(r["name"], ""),
			Country: strOr(r["country"], ""), City: strOr(r["city"], ""), Source: strOr(r["source"], ""), Device: strOr(r["device"], "")})
	}
	return out, nil
}
