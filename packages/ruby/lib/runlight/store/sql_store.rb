# frozen_string_literal: true

module Runlight
  module Store
    # Runlight's tables, read and written with the same SQL as store.ts's SqlStore for each dialect, so a
    # database made by any implementation opens in the others. Rows are the TypeScript interfaces as Hashes
    # with the same camelCase String keys:
    #
    # - SiteRow: {id, name, hostnames: Array<String>, timezone}
    # - GoalRow: {id, site, name, kind: "event"|"page"|"click", match, clickBy: "selector"|"link"|"", valueMode:
    #   "none"|"fixed"|"prop", value: Numeric, valueProp, currency, createdAt: Integer}
    # - ReportRow: {id, site, email, frequency: "weekly"|"monthly", lang, token, origin, lastPeriod, lastSentAt, createdAt}
    # - ShareRow: {id, site, name, createdAt}
    # - FunnelRow: {id, site, name, steps: Array<{kind: "page"|"event", match}>, createdAt}
    # - TokenRow: {id, name, site, scope: "read"|"manage", hash, hint, createdAt, lastUsedAt}
    # - LinkRow: {id, site, domain, slug, name, url, createdAt, updatedAt}
    # - SessionRow: {id, site, visitor, startedAt, hostname, referrerHost, referrerPath, source, channel, utmSource,
    #   utmMedium, utmCampaign, utmTerm, utmContent, country, region, city, browser, browserVersion, os, osVersion, device, screen, language}
    # - EventRow: {site, ts, kind: "pageview"|"event"|"engagement"|"click"|"fetch", visitor, session, pageview, path,
    #   hostname, title, name, props: Hash or nil, engagedMs, scroll, link}
    # - Query: {site, from, to, filters: Array<{dimension, op, value}>}
    # - Bucket: {start, end}
    #
    # Numbers come back as Integer when whole and Float otherwise, as JavaScript's one number type writes them.
    class SqlStore
      BOUNCE_MS = Sql::BOUNCE_MS
      JOURNEY_VISITS = Sql::JOURNEY_VISITS
      EVENT_TAIL_MS = Sql::EVENT_TAIL_MS
      MYSQL_COLLATION = Sql::MYSQL_COLLATION

      attr_reader :db

      def initialize(db)
        @db = db
        @ready = false
        @checked_all = false
      end

      # Creates the tables on first use. Safe to call any number of times.
      #
      # When the database already records the current schema version, that is taken as done, so a store opened
      # for each request costs no more than one read; `full` goes over everything anyway, as the scheduled
      # check and `runlight migrate` do, which adds an index a database of this version may still lack.
      def migrate(full = false)
        return if @checked_all || (@ready && !full)

        if !full && !@ready
          begin
            found = @db.all("SELECT value FROM rl_meta WHERE \"key\" = 'schema'")[0]&.fetch("value", nil)
            if !found.nil? && found.to_s == Sql::SCHEMA_VERSION.to_s
              @ready = true
              return
            end
          rescue StandardError
            # No rl_meta yet: a new database, made below.
          end
        end
        @db.exclusive do |db|
          # On Postgres an index on a big table takes a while to build, so the build may run past the
          # statement timeout, and goes CONCURRENTLY, so another process still serving keeps writing meanwhile.
          postgres = db.dialect == "postgres"
          db.run("SET statement_timeout = 0") if postgres
          begin
            upgrade(db, postgres)
          ensure
            if postgres
              begin
                db.run("RESET statement_timeout")
              rescue StandardError
                nil
              end
            end
          end
        end
        @ready = true
        @checked_all = true
      end

      # Keeps SQLite's planner statistics current, which it never gathers by itself. Without them it can
      # choose a plan that reads a table once for every row of another. A sample of each index is enough,
      # so this takes milliseconds even on a large database. Postgres gathers its own.
      def optimize(only_when_missing = false)
        return if @db.dialect != "sqlite"

        begin
          return if only_when_missing && !@db.all("SELECT name FROM sqlite_master WHERE name = 'sqlite_stat1'").empty?

          @db.run("PRAGMA analysis_limit = 1000")
          @db.run("ANALYZE")
        rescue StandardError
          # Some hosted SQLite services refuse these, and gather statistics themselves.
        end
      end

      def close
        @db.close
      end

      # Runs the block with a store whose every query is in one transaction.
      def transaction
        @db.transaction { |db| yield SqlStore.new(db) }
      end

      # Sites

      def upsert_site(site, now)
        # Unchanged sites are left alone, so starting needs no write and a read-only database still opens.
        hostnames = Json.encode(site["hostnames"].to_a)
        row = @db.all("SELECT name, hostnames, timezone FROM rl_sites WHERE id = ?", [site["id"]])[0]
        if row && Sql.string(row["name"]) == site["name"] && Sql.string(row["hostnames"]) == hostnames && Sql.string(row["timezone"]) == site["timezone"]
          return
        end

        @db.run(
          Sql.upsert(@db.dialect, "rl_sites", %w[id name hostnames timezone created_at], ["id"], %w[name hostnames timezone]),
          [site["id"], site["name"], hostnames, site["timezone"], now],
        )
      end

      # Settings changed in the dashboard, by site. They win over the ones in code.
      def site_overrides
        out = {}
        @db.all("SELECT id, overrides FROM rl_sites").each do |row|
          value = Json.try_decode(Sql.string(row["overrides"]))
          out[Sql.string(row["id"])] = value.is_a?(Hash) ? value : {}
        end
        out
      end

      # Deletes a site and everything recorded for it. Used by the standalone server's "Delete site". Its
      # events and visits go a day at a time first, so a big site does not hold the database for minutes,
      # and what is left goes in one transaction.
      def delete_site(id)
        piece = metered? ? 30 * Sql::PIECE_MS : Sql::PIECE_MS
        [%w[rl_events ts], %w[rl_sessions started_at]].each do |table, col|
          # A piece at a time from the oldest row, skipping straight over stretches with none.
          from = oldest(table, col, id, nil)
          until from.nil?
            @db.run("DELETE FROM #{table} WHERE site = ? AND #{col} < ?", [id, from + piece])
            from = oldest(table, col, id, from + piece)
          end
        end
        transaction do |store|
          %w[rl_events rl_sessions rl_links rl_link_domains rl_shares rl_goals rl_funnels rl_reports rl_tokens rl_rollups rl_rollup_days rl_sites].each do |table|
            store.db.run("DELETE FROM #{table} WHERE #{table == "rl_sites" ? "id" : "site"} = ?", [id])
          end
        end
      end

      # Deletes a site's visits and events from before a time, for its retention setting.
      def drop_before(site, ts)
        # A day at a time from the oldest, each its own short transaction, so a long history goes without
        # holding the database for minutes. Stretches with nothing in them are skipped, so one stray old row
        # does not cost a piece for every day since.
        piece = metered? ? 30 * Sql::PIECE_MS : Sql::PIECE_MS
        next_at = lambda do |at|
          found = [oldest("rl_sessions", "started_at", site, at), oldest("rl_events", "ts", site, at)].compact
          next nil if found.empty?

          at.nil? ? found.min : [at, found.min].max
        end
        from = next_at.call(nil)
        while !from.nil? && from < ts
          to = [from + piece, ts].min
          transaction do |store|
            # A visit's events go with it, even ones after the cutoff, so nothing is left without its visit.
            # They come after it starts and within EVENT_TAIL_MS, so the time bounds let the (site, ts) index find them.
            store.db.run(
              "DELETE FROM rl_events WHERE site = ? AND ts >= ? AND ts < ? AND session IN (SELECT id FROM rl_sessions WHERE site = ? AND started_at >= ? AND started_at < ?)",
              [site, from, to + Sql::EVENT_TAIL_MS, site, from, to],
            )
            store.db.run("DELETE FROM rl_events WHERE site = ? AND ts < ?", [site, to])
            store.db.run("DELETE FROM rl_sessions WHERE site = ? AND started_at < ?", [site, to])
          end
          from = next_at.call([from + piece, ts].min)
        end
        # A day that lost any of its visits is built again later, from what is left.
        clear_rollups(site, { "before" => ts })
      end

      # Deletes a site's events from `from` on whose visit no longer exists, a day at a time.
      def drop_orphans(site, from, until_at)
        piece = metered? ? 30 * Sql::PIECE_MS : Sql::PIECE_MS
        at = oldest("rl_events", "ts", site, from)
        while !at.nil? && at < until_at
          @db.run(
            "DELETE FROM rl_events WHERE site = ? AND ts >= ? AND ts < ? AND session <> '' AND NOT EXISTS (SELECT 1 FROM rl_sessions s WHERE s.id = rl_events.session)",
            [site, at, at + piece],
          )
          at = oldest("rl_events", "ts", site, at + piece)
        end
      end

      # Daily rollups

      # Adds up one local day of a site: totals, each visit dimension, and pages.
      # A visit belongs to the day it started. Visitor ids change every day, so
      # the days of a range add up to exactly what counting the range would give.
      def build_rollup_day(site, day, start, finish)
        # A day with no visits still gets its row of zeros, so it counts as built.
        bounce = Sql::BOUNCE
        sums = "COUNT(DISTINCT s.visitor), COUNT(*), COALESCE(SUM(s.pageviews), 0), COALESCE(SUM(CASE WHEN #{bounce} THEN 1 ELSE 0 END), 0), COALESCE(SUM(#{Sql::DURATION}), 0)"
        cols = "(site, day, dim, value, visitors, visits, pageviews, bounced, duration)"
        # Each piece names its own site and day, as text, so Postgres knows their type inside a UNION.
        dialect = @db.dialect
        head = "#{Sql.as_text(dialect, "?")}, #{Sql.as_text(dialect, "?")}"
        quarter = Sql.div(dialect, "s.started_at", 900_000)
        # The day's totals, each visit dimension, and the heatmap's quarter hours (counted as hourly() counts
        # them: every visit that started), in one statement over the day's visits, since a Cloudflare D1
        # check may only send so many.
        pieces = ["SELECT #{head}, '', '', #{sums} FROM v s"]
        Query::SESSION_DIMENSIONS.each do |dim, col|
          pieces << "SELECT #{head}, '#{dim}', s.#{col}, #{sums} FROM v s WHERE s.#{col} <> '' GROUP BY s.#{col}"
        end
        pieces << "SELECT #{head}, 'quarter', #{Sql.as_text(dialect, quarter)}, COUNT(DISTINCT s.visitor), COUNT(*), COALESCE(SUM(s.pageviews), 0), COALESCE(SUM(CASE WHEN #{bounce} THEN 1 ELSE 0 END), 0), 0 FROM v s GROUP BY #{Sql.as_text(dialect, quarter)}"
        # Pages and events, from the rows of the day's visits. The time bounds let the (site, kind, ts) index
        # find them; a visit's last row comes at most EVENT_TAIL_MS after it starts.
        of_day = lambda do |kind|
          "FROM rl_events e JOIN rl_sessions s ON s.id = e.session
       WHERE e.site = ? AND e.kind = '#{kind}' AND e.ts >= ? AND e.ts < ? AND s.started_at >= ? AND s.started_at < ? AND #{Sql::IS_VISIT}"
        end
        window = [site, start, finish + Sql::EVENT_TAIL_MS, start, finish]
        transaction do |store|
          db = store.db
          db.run("DELETE FROM rl_rollups WHERE site = ? AND day = ?", [site, day])
          # The WITH goes after INSERT INTO, the one place every database takes it.
          params = [site, start, finish]
          pieces.each { params.push(site, day) }
          db.run(
            "INSERT INTO rl_rollups #{cols}
         WITH v AS (SELECT * FROM rl_sessions s WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND #{Sql::IS_VISIT})
         #{pieces.join(" UNION ALL ")}",
            params,
          )
          # A page's engaged time and scroll come per pageview first (its time added up, its deepest scroll),
          # as the raw report counts them.
          db.run(
            "INSERT INTO rl_rollups (site, day, dim, value, visitors, visits, pageviews, views, engaged, scroll_sum, scroll_n)
         SELECT ?, ?, 'page', p.value, p.visitors, p.visits, p.pageviews, p.views, COALESCE(t.engaged, 0), COALESCE(t.scroll_sum, 0), COALESCE(t.scroll_n, 0)
         FROM (SELECT e.path AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(DISTINCT e.session) AS visits, COUNT(*) AS pageviews, #{Sql::LIVE_VIEWS} AS views
               #{of_day.call("pageview")} GROUP BY e.path) p
         LEFT JOIN (SELECT value, SUM(total) AS engaged, SUM(deepest) AS scroll_sum, COUNT(deepest) AS scroll_n FROM (
               SELECT e.path AS value, SUM(e.engaged_ms) AS total, MAX(e.scroll) AS deepest #{of_day.call("engagement")} GROUP BY e.path, e.pageview) x
               GROUP BY value) t ON t.value = p.value",
            [site, day, *window, *window],
          )
          db.run(
            "INSERT INTO rl_rollups (site, day, dim, value, visitors, events)
         SELECT ?, ?, 'event', e.name, COUNT(DISTINCT e.visitor), COUNT(*) #{of_day.call("event")} GROUP BY e.name",
            [site, day, *window],
          )
          db.run("DELETE FROM rl_rollup_days WHERE site = ? AND day = ?", [site, day])
          db.run("INSERT INTO rl_rollup_days (site, day, start_at, end_at) VALUES (?, ?, ?, ?)", [site, day, start, finish])
        end
      end

      # The days of a site already built.
      def rollup_days(site)
        @db.all("SELECT day FROM rl_rollup_days WHERE site = ?", [site]).map { |r| Sql.string(r["day"]) }.uniq
      end

      # Forgets built days, all of a site's or those touching a stretch of time, so they are built again.
      # range: {"before" => ms} or {"from" => ms, "to" => ms}.
      def clear_rollups(site, range = {})
        where = +"site = ?"
        params = [site]
        if !range["before"].nil?
          where << " AND start_at < ?"
          params << range["before"]
        elsif !range["from"].nil? && !range["to"].nil?
          where << " AND start_at < ? AND end_at > ?"
          params.push(range["to"], range["from"])
        end
        days = @db.all("SELECT day FROM rl_rollup_days WHERE #{where}", params).map { |r| Sql.string(r["day"]) }
        # The days stop counting as built first, so if this stops part way, no day is left marked built
        # without its rows. Rows of a day not built are never read, and building it replaces them. Another
        # process may build a day between the two deletes, so its mark goes again after its rows: the day
        # is then simply built once more.
        @db.run("DELETE FROM rl_rollup_days WHERE #{where}", params)
        days.each do |day|
          @db.run("DELETE FROM rl_rollups WHERE site = ? AND day = ?", [site, day])
          @db.run("DELETE FROM rl_rollup_days WHERE site = ? AND day = ?", [site, day])
        end
      end

      def set_site_overrides(id, overrides)
        @db.run("UPDATE rl_sites SET overrides = ? WHERE id = ?", [Json.encode(overrides.to_h), id])
      end

      # When the site last recorded a visit, or nil if it never has.
      def last_seen(site)
        row = @db.all("SELECT MAX(ts) AS t FROM rl_events WHERE site = ? AND kind IN ('pageview', 'event')", [site])[0]
        row.nil? || row["t"].nil? ? nil : Sql.num(row["t"])
      end

      def sites
        @db.all("SELECT id, name, hostnames, timezone FROM rl_sites ORDER BY name, id").map do |row|
          {
            "id" => Sql.string(row["id"]),
            "name" => Sql.string(row["name"]),
            "hostnames" => Json.decode(Sql.string(row["hostnames"])),
            "timezone" => Sql.string(row["timezone"]),
          }
        end
      end

      # Salts

      # The salt for a day, made on first ask. Two racing callers agree on one.
      def salt(day, fresh)
        @db.run(Sql.upsert(@db.dialect, "rl_salts", %w[day salt], ["day"], []), [day, fresh])
        rows = @db.all("SELECT salt FROM rl_salts WHERE day = ?", [day])
        rows[0].nil? || rows[0]["salt"].nil? ? fresh : Sql.string(rows[0]["salt"])
      end

      def salt_if_exists(day)
        rows = @db.all("SELECT salt FROM rl_salts WHERE day = ?", [day])
        rows[0].nil? || rows[0]["salt"].nil? ? nil : Sql.string(rows[0]["salt"])
      end

      # Deletes every salt older than `day`, so old hashes can never be recomputed.
      def drop_salts_before(day)
        @db.run("DELETE FROM rl_salts WHERE day < ?", [day])
      end

      # Ingest

      # The visitor's open session: any of their hashes, active since `since`. {"id", "visitor"} or nil.
      def open_session(site, visitors, since)
        return nil if visitors.empty?

        rows = @db.all(
          "SELECT id, visitor FROM rl_sessions WHERE site = ? AND visitor IN (#{(["?"] * visitors.length).join(", ")}) AND last_at >= ?
       ORDER BY last_at DESC, id LIMIT 1",
          [site, *visitors, since],
        )
        rows[0].nil? ? nil : { "id" => Sql.string(rows[0]["id"]), "visitor" => Sql.string(rows[0]["visitor"]) }
      end

      def insert_session(row)
        @db.run(
          "INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, engaged_ms, hostname, referrer_host, referrer_path,
        source, channel, utm_source, utm_medium, utm_campaign, utm_term, utm_content, country, region, city,
        browser, browser_version, os, os_version, device, screen, language)
       VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
          [
            row["id"], row["site"], row["visitor"], row["startedAt"], row["startedAt"], row["hostname"], row["referrerHost"], row["referrerPath"],
            row["source"], row["channel"], row["utmSource"], row["utmMedium"], row["utmCampaign"], row["utmTerm"], row["utmContent"],
            row["country"], row["region"], row["city"], row["browser"], row["browserVersion"], row["os"], row["osVersion"], row["device"],
            row["screen"], row["language"],
          ],
        )
      end

      # Counts a row into its session. An event with `reopen` false, one that joins a visit already ended,
      # counts without moving the session's last activity.
      def touch_session(id, ts, kind, path, reopen = true)
        if kind == "click"
          @db.run("UPDATE rl_sessions SET last_at = ? WHERE id = ?", [ts, id])
        elsif kind == "pageview"
          @db.run(
            "UPDATE rl_sessions SET pageviews = pageviews + 1, last_at = ?, exit_path = ?,
           entry_path = CASE WHEN entry_path = '' THEN ? ELSE entry_path END WHERE id = ?",
            [ts, path, path, id],
          )
        elsif reopen
          @db.run("UPDATE rl_sessions SET events = events + 1, last_at = ? WHERE id = ?", [ts, id])
        else
          @db.run("UPDATE rl_sessions SET events = events + 1 WHERE id = ?", [id])
        end
      end

      def add_engagement(id, ms)
        @db.run("UPDATE rl_sessions SET engaged_ms = COALESCE(engaged_ms, 0) + ? WHERE id = ?", [ms, id])
      end

      # The pageview an engagement ping or event belongs to, with when its visit started and was last active.
      def pageview(site, pageview)
        row = @db.all(
          "SELECT e.session AS session, e.visitor AS visitor, e.path AS path, e.hostname AS hostname, e.ts AS ts, s.started_at AS started_at, s.last_at AS last_at
       FROM rl_events e JOIN rl_sessions s ON s.id = e.session WHERE e.site = ? AND e.pageview = ? AND e.kind = 'pageview' LIMIT 1",
          [site, pageview],
        )[0]
        return nil if row.nil?

        {
          "session" => Sql.string(row["session"]),
          "visitor" => Sql.string(row["visitor"]),
          "path" => Sql.string(row["path"]),
          "hostname" => Sql.string(row["hostname"]),
          "ts" => Sql.num(row["ts"]),
          "startedAt" => Sql.num(row["started_at"]),
          "lastAt" => Sql.num(row["last_at"]),
        }
      end

      # After a late event or engagement ping joins an old visit (a tab left open overnight), the day
      # that visit started may already be added up. Forget that day so the next check builds it again.
      def touched_old_visit(site, started, before)
        clear_rollups(site, { "from" => started, "to" => started + 1 }) if started < before
      end

      def insert_event(row)
        props = row["props"]
        @db.run(
          "INSERT INTO rl_events (site, ts, kind, visitor, session, pageview, path, hostname, title, name, props, engaged_ms, scroll, link)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
          [
            row["site"], row["ts"], row["kind"], row["visitor"], row["session"], row["pageview"], row["path"], row["hostname"], row["title"],
            row["name"], props.nil? ? nil : Json.encode(props), row["engagedMs"], row["scroll"], row["link"],
          ],
        )
      end

      # Links

      # The live link with a slug. Slugs are unique across every domain.
      def link_by_slug(slug)
        rows = @db.all("SELECT * FROM rl_links WHERE slug = ? AND deleted_at IS NULL LIMIT 1", [slug])
        rows[0].nil? ? nil : Sql.link_row(rows[0])
      end

      def link_by_id(id)
        rows = @db.all("SELECT * FROM rl_links WHERE id = ? AND deleted_at IS NULL LIMIT 1", [id])
        rows[0].nil? ? nil : Sql.link_row(rows[0])
      end

      def insert_link(link)
        @db.run(
          "INSERT INTO rl_links (id, site, domain, slug, name, url, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
          [link["id"], link["site"], link["domain"], link["slug"], link["name"], link["url"], link["createdAt"], link["updatedAt"]],
        )
      end

      def update_link(link)
        @db.run("UPDATE rl_links SET domain = ?, slug = ?, name = ?, url = ?, updated_at = ? WHERE id = ?", [
          link["domain"], link["slug"], link["name"], link["url"], link["updatedAt"], link["id"],
        ])
      end

      # Hides a link and frees its slug; its clicks stay in the history.
      def delete_link(id, now)
        @db.run("UPDATE rl_links SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL", [now, id])
      end

      # Shares

      def shares(site)
        @db.all("SELECT id, site, name, created_at FROM rl_shares WHERE site = ? ORDER BY created_at DESC, id", [site]).map { |r| share_row(r) }
      end

      def share_by_id(id)
        r = @db.all("SELECT id, site, name, created_at FROM rl_shares WHERE id = ?", [id])[0]
        r.nil? ? nil : share_row(r)
      end

      def insert_share(share)
        @db.run("INSERT INTO rl_shares (id, site, name, created_at) VALUES (?, ?, ?, ?)", [share["id"], share["site"], share["name"], share["createdAt"]])
      end

      def rename_share(id, name)
        @db.run("UPDATE rl_shares SET name = ? WHERE id = ?", [name, id])
      end

      # Deleting a share is how it is revoked: the link stops working at once.
      def delete_share(id)
        @db.run("DELETE FROM rl_shares WHERE id = ?", [id])
      end

      # Funnels

      def funnels(site)
        @db.all("SELECT * FROM rl_funnels WHERE site = ? ORDER BY created_at, id", [site]).map do |r|
          {
            "id" => Sql.string(r["id"]),
            "site" => Sql.string(r["site"]),
            "name" => Sql.string(r["name"]),
            "steps" => Json.decode(Sql.string(r["steps"])),
            "createdAt" => Sql.number(r["created_at"]),
          }
        end
      end

      def save_funnel(f)
        @db.run(
          Sql.upsert(@db.dialect, "rl_funnels", %w[id site name steps created_at], ["id"], %w[name steps]),
          [f["id"], f["site"], f["name"], Json.encode(f["steps"].to_a), f["createdAt"]],
        )
      end

      def delete_funnel(id)
        @db.run("DELETE FROM rl_funnels WHERE id = ?", [id])
      end

      # How many visits reached each step, in order, within the same visit. Step
      # one is the first matching row in the range; each later step must come
      # after the step before it. Filters choose which visits enter the funnel.
      def funnel_counts(query, funnel)
        # The rows of the picked visits that match any step, in order, read once and walked here: a join from
        # each step to the next is planned badly by Postgres, which cannot guess how many visits go on.
        v = Sql.visit_rows(query["filters"], query["site"], query["from"], query["to"], @db.dialect)
        scopes = funnel["steps"].map { |step| goal_scope({ "kind" => step["kind"], "match" => step["match"], "name" => step["match"] }) }
        cases = []
        any = []
        scope_params = []
        scopes.each_with_index do |scope, i|
          cases << "CASE WHEN #{scope["sql"]} THEN 1 ELSE 0 END AS m#{i}"
          any << "(#{scope["sql"]})"
          scope_params.concat(scope["params"])
        end
        rows = @db.all(
          "SELECT e.session AS session, #{cases.join(", ")}
       FROM #{v["from"]} WHERE #{v["sql"]} AND (#{any.join(" OR ")})
       ORDER BY e.session, e.ts, e.id",
          [*scope_params, *v["params"], *scope_params],
        )
        counts = Array.new(funnel["steps"].length, 0)
        session = nil
        started = false
        reached = 0
        close = -> { reached.times { |i| counts[i] += 1 } }
        rows.each do |row|
          if !started || row["session"] != session
            close.call
            session = row["session"]
            started = true
            reached = 0
          end
          # Each step is the first matching row after the step before, so two steps in the same millisecond
          # both count, and one row never counts as two steps.
          reached += 1 if reached < counts.length && Sql.num(row["m#{reached}"]) == 1
        end
        close.call
        counts
      end

      # Each visit's pageviews in order, at most `per_visit` of them, for journeys.
      # A window function keeps the first ones of each visit, so a long visit
      # cannot crowd the rest out. Visits belong to the range they started in.
      # {"rows" => [{"session", "path"}], "sampled" => bool}
      def journey_pages(query, per_visit)
        scope = Sql.visit_scope(query["filters"], query["site"], query["from"], query["to"], @db.dialect)
        # The newest visits the filters pick, JOURNEY_VISITS at most, so a long range stays quick and small in memory.
        newest = lambda do |columns, limit|
          "SELECT #{columns} FROM rl_sessions s WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND #{Sql::IS_VISIT}#{scope["sql"]}
         ORDER BY s.started_at DESC, s.id LIMIT #{limit}"
        end
        visit_params = [query["site"], query["from"], query["to"], *scope["params"]]
        # How many there are, one past the cap telling whether it was reached, and when the oldest of them began,
        # so the rows are read from there on rather than from the start of a long range.
        first = @db.all("SELECT COUNT(*) AS n, MIN(started_at) AS t FROM (#{newest.call("s.started_at AS started_at", Sql::JOURNEY_VISITS + 1)}) x", visit_params)[0] || {}
        return { "rows" => [], "sampled" => false } if Sql.num(first["n"]).zero?

        from = [query["from"], Sql.num(first["t"])].max
        # MySQL takes no LIMIT in an IN list, but does in a table inside one.
        visits = @db.dialect == "mysql" ? "SELECT id FROM (#{newest.call("s.id AS id", Sql::JOURNEY_VISITS)}) x" : newest.call("s.id", Sql::JOURNEY_VISITS)
        rows = @db.all(
          # The visits are read as an IN list, which every database probes from the events side, so the
          # plan does not depend on the planner's statistics. Refreshes (the same page twice in a row) are
          # dropped before counting, so they never use up the steps.
          "WITH raw AS (
         SELECT e.session AS session, e.path AS path, e.ts AS ts, e.id AS id,
           LAG(e.path) OVER (PARTITION BY e.session ORDER BY e.ts, e.id) AS prev
         FROM rl_events e
         WHERE e.site = ? AND e.kind = 'pageview' AND e.ts >= ? AND e.ts < ? AND e.session IN (#{visits})),
       v AS (
         SELECT session, path, ROW_NUMBER() OVER (PARTITION BY session ORDER BY ts, id) AS n
         FROM raw WHERE prev IS NULL OR prev <> path)
       SELECT session, path FROM v WHERE n <= ? ORDER BY session, n",
          [query["site"], from, query["to"] + Sql::EVENT_TAIL_MS, *visit_params, per_visit],
        )
        {
          "rows" => rows.map { |r| { "session" => Sql.string(r["session"]), "path" => Sql.string(r["path"]) } },
          "sampled" => Sql.num(first["n"]) > Sql::JOURNEY_VISITS,
        }
      end

      # API tokens

      def tokens
        @db.all("SELECT * FROM rl_tokens ORDER BY created_at DESC, id").map { |r| token_row(r) }
      end

      def token_by_hash(hash)
        row = @db.all("SELECT * FROM rl_tokens WHERE hash = ?", [hash])[0]
        row.nil? ? nil : token_row(row)
      end

      def insert_token(t)
        @db.run("INSERT INTO rl_tokens (id, name, site, scope, hash, hint, created_at, last_used_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", [
          t["id"], t["name"], t["site"], t["scope"], t["hash"], t["hint"], t["createdAt"], t["lastUsedAt"],
        ])
      end

      def touch_token(id, now)
        @db.run("UPDATE rl_tokens SET last_used_at = ? WHERE id = ?", [now, id])
      end

      # Deleting a token is how it is revoked: it stops working at once.
      def delete_token(id)
        changed("DELETE FROM rl_tokens WHERE id = ?", [id]) == 1
      end

      # Settings

      def setting(key)
        row = @db.all("SELECT value FROM rl_settings WHERE \"key\" = ?", [key])[0]
        row.nil? ? nil : Sql.string(row["value"])
      end

      # Every setting whose key starts with a prefix, such as each connected install's: [{"key", "value"}].
      def settings_starting_with(prefix)
        rows = @db.all("SELECT \"key\", value FROM rl_settings WHERE \"key\" LIKE ? ESCAPE '\\'", ["#{Sql.escape_like(prefix)}%"])
        rows.map { |r| { "key" => Sql.string(r["key"]), "value" => Sql.string(r["value"]) } }
      end

      def set_setting(key, value)
        if value.nil?
          @db.run("DELETE FROM rl_settings WHERE \"key\" = ?", [key])
        else
          @db.run(Sql.upsert(@db.dialect, "rl_settings", ['"key"', "value"], ['"key"'], ["value"]), [key, value])
        end
      end

      # Email reports

      def reports(site = nil)
        rows = if !site.nil? && site != ""
                 @db.all("SELECT * FROM rl_reports WHERE site = ? ORDER BY created_at, id", [site])
               else
                 @db.all("SELECT * FROM rl_reports ORDER BY created_at, id")
               end
        rows.map { |r| report_row(r) }
      end

      # field: "id" or "token".
      def report_by(field, value)
        row = @db.all("SELECT * FROM rl_reports WHERE #{field == "id" ? "id" : "token"} = ?", [value])[0]
        row.nil? ? nil : report_row(row)
      end

      def insert_report(r)
        @db.run(
          "INSERT INTO rl_reports (id, site, email, frequency, lang, token, origin, last_period, last_sent_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
          [r["id"], r["site"], r["email"], r["frequency"], r["lang"], r["token"], r["origin"], r["lastPeriod"], r["lastSentAt"], r["createdAt"]],
        )
      end

      # Records a period as sent. Only one caller wins, so two cron runs at once cannot both send it.
      def claim_report(id, period, now)
        # One statement, so of two cron runs at once only one gets the row back.
        changed("UPDATE rl_reports SET last_period = ?, last_sent_at = ? WHERE id = ? AND last_period <> ?", [period, now, id, period]) == 1
      end

      # Puts a period back when its email failed, so the next run tries again.
      def release_report(id, period, previous)
        @db.run("UPDATE rl_reports SET last_period = ? WHERE id = ? AND last_period = ?", [previous, id, period])
      end

      def delete_report(id)
        @db.run("DELETE FROM rl_reports WHERE id = ?", [id])
      end

      # Goals

      def goals(site = nil)
        rows = if !site.nil? && site != ""
                 @db.all("SELECT * FROM rl_goals WHERE site = ? ORDER BY created_at, id", [site])
               else
                 @db.all("SELECT * FROM rl_goals ORDER BY created_at, id")
               end
        rows.map { |r| Sql.goal_row(r) }
      end

      def goal_by_id(id)
        row = @db.all("SELECT * FROM rl_goals WHERE id = ?", [id])[0]
        row.nil? ? nil : Sql.goal_row(row)
      end

      def save_goal(g, before = nil)
        # A click goal is counted by its name, which the tracker sends as the event
        # name. Renaming one renames its past clicks too, so its history stays.
        if !before.nil? && before["kind"] == "click" && g["kind"] == "click" && before["name"] != g["name"]
          @db.run("UPDATE rl_events SET name = ? WHERE site = ? AND kind = 'event' AND name = ?", [g["name"], g["site"], before["name"]])
        end
        @db.run(
          Sql.upsert(
            @db.dialect,
            "rl_goals",
            ["id", "site", "name", "kind", '"match"', "click_by", "value_mode", "value", "value_prop", "currency", "created_at"],
            ["id"],
            ["name", "kind", '"match"', "click_by", "value_mode", "value", "value_prop", "currency"],
          ),
          [g["id"], g["site"], g["name"], g["kind"], g["match"], g["clickBy"], g["valueMode"], g["value"], g["valueProp"], g["currency"], g["createdAt"]],
        )
      end

      def delete_goal(id)
        @db.run("DELETE FROM rl_goals WHERE id = ?", [id])
      end

      # The property names sent with an event in a query's range, most used first: [{"key", "events"}].
      def event_prop_keys(query, event)
        v = Sql.visit_rows(query["filters"], query["site"], query["from"], query["to"], @db.dialect)
        where = "#{v["sql"]} AND e.kind = 'event' AND e.name = ? AND e.props IS NOT NULL"
        params = [*v["params"], event]
        rows = case @db.dialect
               when "mysql"
                 # Each key as a row of its own, compared and sorted by code point like every other value.
                 @db.all(
                   "SELECT j.k AS \"key\", COUNT(*) AS events FROM #{v["from"]}
             CROSS JOIN JSON_TABLE(JSON_KEYS(CASE WHEN JSON_TYPE(e.props) = 'OBJECT' THEN e.props ELSE '{}' END), '$[*]' COLUMNS (k VARCHAR(255) COLLATE #{Sql::MYSQL_COLLATION} PATH '$')) j
             WHERE #{where} GROUP BY j.k ORDER BY events DESC, j.k LIMIT 30",
                   params,
                 )
               when "postgres"
                 @db.all(
                   "SELECT k AS \"key\", COUNT(*) AS events FROM #{v["from"]} CROSS JOIN LATERAL jsonb_object_keys(CASE WHEN jsonb_typeof(e.props::jsonb) = 'object' THEN e.props::jsonb ELSE '{}'::jsonb END) AS k
             WHERE #{where} GROUP BY k ORDER BY events DESC, k#{text_order} LIMIT 30",
                   params,
                 )
               else
                 @db.all(
                   "SELECT j.key AS \"key\", COUNT(*) AS events FROM #{v["from"]}, json_each(e.props) j
             WHERE #{where} AND json_type(e.props) = 'object' GROUP BY j.key ORDER BY events DESC, key#{text_order} LIMIT 30",
                   params,
                 )
               end
        rows.map { |r| { "key" => Sql.string(r["key"]), "events" => Sql.num(r["events"]) } }
      end

      # The values one property of an event took, with how often and by how many visitors:
      # [{"value", "events", "visitors"}].
      def event_prop_values(query, event, key, limit)
        v = Sql.visit_rows(query["filters"], query["site"], query["from"], query["to"], @db.dialect)
        value = case @db.dialect
                when "postgres" then "(e.props::jsonb ->> ?)"
                when "mysql" then "(JSON_UNQUOTE(JSON_EXTRACT(e.props, ?)) COLLATE #{Sql::MYSQL_COLLATION})"
                else "CAST(json_extract(e.props, ?) AS TEXT)"
                end
        path = @db.dialect == "postgres" ? key : "$.\"#{key}\""
        rows = @db.all(
          "SELECT * FROM (SELECT #{value} AS value, COUNT(*) AS events, COUNT(DISTINCT e.visitor) AS visitors FROM #{v["from"]}
         WHERE #{v["sql"]} AND e.kind = 'event' AND e.name = ? AND #{value} IS NOT NULL GROUP BY 1) t
       ORDER BY events DESC, value#{text_order} LIMIT ?",
          [path, *v["params"], event, path, limit],
        )
        rows.map { |r| { "value" => Sql.string(r["value"]), "events" => Sql.num(r["events"]), "visitors" => Sql.num(r["visitors"]) } }
      end

      # Every goal's totals in one pass over the range's events, instead of a query
      # per goal: each goal adds a conditional count, distinct count, and sum.
      # Keyed by goal id: {"conversions", "visitors", "revenue"}.
      def goal_totals_all(query, goals)
        out = {}
        v = Sql.visit_rows(query["filters"], query["site"], query["from"], query["to"], @db.dialect)
        # As many goals per query as keep it under D1's parameter limit.
        chunks = [[]]
        count = v["params"].length
        goals.each do |goal|
          cost = goal_scope(goal)["params"].length * 4 + revenue_value(goal)["params"].length
          if !chunks.last.empty? && count + cost > Sql::MAX_PARAMS
            chunks << []
            count = v["params"].length
          end
          chunks.last << goal
          count += cost
        end
        chunks.each do |chunk|
          next if chunk.empty?

          columns = []
          params = []
          # Only rows some goal of the chunk counts are read.
          any = []
          any_params = []
          chunk.each_with_index do |goal, i|
            scope = goal_scope(goal)
            value = revenue_value(goal)
            columns.push(
              "SUM(CASE WHEN #{scope["sql"]} THEN 1 ELSE 0 END) AS c#{i}",
              "COUNT(DISTINCT CASE WHEN #{scope["sql"]} THEN e.visitor END) AS v#{i}",
              "SUM(CASE WHEN #{scope["sql"]} THEN #{value["sql"]} ELSE 0 END) AS r#{i}",
            )
            params.push(*scope["params"], *scope["params"], *scope["params"], *value["params"])
            any << "(#{scope["sql"]})"
            any_params.concat(scope["params"])
          end
          row = @db.all(
            "SELECT #{columns.join(", ")} FROM #{v["from"]}
         WHERE #{v["sql"]} AND e.kind IN ('pageview', 'event') AND (#{any.join(" OR ")})",
            [*params, *v["params"], *any_params],
          )[0] || {}
          chunk.each_with_index do |goal, i|
            out[goal["id"]] = { "conversions" => Sql.num(row["c#{i}"]), "visitors" => Sql.num(row["v#{i}"]), "revenue" => cents(Sql.num(row["r#{i}"])) }
          end
        end
        out
      end

      # One goal's conversions, converting visitors, and revenue for a query's range and filters.
      def goal_totals(query, goal)
        v = Sql.visit_rows(query["filters"], query["site"], query["from"], query["to"], @db.dialect)
        scope = goal_scope(goal)
        revenue = revenue_sql(goal)
        row = @db.all(
          "SELECT COUNT(*) AS conversions, COUNT(DISTINCT e.visitor) AS visitors, #{revenue["sql"]} AS revenue
       FROM #{v["from"]} WHERE #{v["sql"]} AND #{scope["sql"]}",
          [*revenue["params"], *v["params"], *scope["params"]],
        )[0] || {}
        { "conversions" => Sql.num(row["conversions"]), "visitors" => Sql.num(row["visitors"]), "revenue" => cents(Sql.num(row["revenue"])) }
      end

      # A goal's conversions split by where the visit came from, or by the page it happened on.
      # by: "source", "channel", or "path".
      def goal_breakdown(query, goal, by, limit = 10)
        v = Sql.visit_rows(query["filters"], query["site"], query["from"], query["to"], @db.dialect)
        col = by == "path" ? "e.path" : "s.#{by}"
        scope = goal_scope(goal)
        revenue = revenue_sql(goal)
        rows = @db.all(
          "SELECT #{col} AS value, COUNT(*) AS conversions, COUNT(DISTINCT e.visitor) AS visitors, #{revenue["sql"]} AS revenue
       FROM #{v["from"]} WHERE #{v["sql"]} AND #{scope["sql"]}
       GROUP BY #{col} ORDER BY conversions DESC, #{col}#{text_order} LIMIT ?",
          [*revenue["params"], *v["params"], *scope["params"], limit],
        )
        rows.map do |r|
          {
            "value" => Sql.string(r["value"]),
            "conversions" => Sql.num(r["conversions"]),
            "visitors" => Sql.num(r["visitors"]),
            "revenue" => cents(Sql.num(r["revenue"])),
          }
        end
      end

      # A goal's conversions and revenue in each bucket, by when each visit started:
      # [{"start", "conversions", "revenue"}].
      def goal_series(query, goal, buckets)
        return [] if buckets.empty?

        scope = goal_scope(goal)
        revenue = revenue_sql(goal)
        # Each bucket binds three values; the rest are fixed. As many buckets a statement as keep it under D1's 100.
        fixed = revenue["params"].length + scope["params"].length + Sql.visit_rows(query["filters"], query["site"], 0, 0, @db.dialect)["params"].length
        size = [1, [Sql::BUCKETS_PER_QUERY, (Sql::MAX_PARAMS - fixed).fdiv(3).floor].min].max
        return Sql.in_pieces(buckets, size) { |piece| goal_series(query, goal, piece) } if buckets.length > size

        last = buckets[-1]
        v = Sql.visit_rows(query["filters"], query["site"], buckets[0]["start"], last["end"], @db.dialect)
        rows = @db.all(
          "WITH b (i, bs, be) AS (#{Sql.bucket_table(@db.dialect, buckets)})
       SELECT b.i AS i, COUNT(*) AS conversions, #{revenue["sql"]} AS revenue
       FROM #{v["from"]} CROSS JOIN b
       WHERE #{v["sql"]} AND s.started_at >= b.bs AND s.started_at < b.be AND #{scope["sql"]}
       GROUP BY b.i",
          [*bucket_params(buckets), *revenue["params"], *v["params"], *scope["params"]],
        )
        found = {}
        rows.each { |r| found[Sql.num(r["i"]).to_i] = r }
        buckets.each_with_index.map do |b, i|
          r = found[i] || {}
          { "start" => b["start"], "conversions" => Sql.num(r["conversions"]), "revenue" => cents(Sql.num(r["revenue"])) }
        end
      end

      # [{"domain", "site"}].
      def link_domains
        @db.all("SELECT domain, site FROM rl_link_domains ORDER BY domain").map { |r| { "domain" => Sql.string(r["domain"]), "site" => Sql.string(r["site"]) } }
      end

      def add_link_domain(domain, site, now)
        @db.run(Sql.upsert(@db.dialect, "rl_link_domains", %w[domain site created_at], ["domain"], []), [domain, site, now])
      end

      # Removes a domain. Its links keep it as their home and fall back to the
      # app's own link path until the domain is added again.
      def remove_link_domain(domain)
        @db.run("DELETE FROM rl_link_domains WHERE domain = ?", [domain])
      end

      # A site's links, newest first, with their clicks in a range. Clicks
      # imported as daily counts have no visitor, so they add to clicks only.
      def links(site, from, to)
        rows = @db.all(
          "SELECT l.*, COALESCE(c.clicks, 0) AS clicks, COALESCE(c.visitors, 0) AS visitors
       FROM rl_links l LEFT JOIN (
         SELECT link, COUNT(*) AS clicks, COUNT(DISTINCT NULLIF(visitor, '')) AS visitors FROM rl_events
         WHERE site = ? AND kind = 'click' AND ts >= ? AND ts < ? GROUP BY link
       ) c ON c.link = l.id
       WHERE l.site = ? AND l.deleted_at IS NULL
       ORDER BY l.created_at DESC, l.id",
          [site, from, to, site],
        )
        rows.map { |row| Sql.link_row(row).merge("clicks" => Sql.num(row["clicks"]), "visitors" => Sql.num(row["visitors"])) }
      end

      # One link's clicks per bucket: [{"start", "clicks", "visitors"}].
      def link_series(site, link, buckets)
        return [] if buckets.empty?
        return Sql.in_pieces(buckets, Sql::BUCKETS_PER_QUERY) { |piece| link_series(site, link, piece) } if buckets.length > Sql::BUCKETS_PER_QUERY

        rows = @db.all(
          "WITH b (i, bs, be) AS (#{Sql.bucket_table(@db.dialect, buckets)})
       SELECT b.i AS i, COUNT(*) AS clicks, COUNT(DISTINCT NULLIF(e.visitor, '')) AS visitors
       FROM b JOIN rl_events e ON e.link = ? AND e.ts >= b.bs AND e.ts < b.be
       WHERE e.site = ? AND e.kind = 'click' GROUP BY b.i",
          [*bucket_params(buckets), link, site],
        )
        found = {}
        rows.each { |r| found[Sql.num(r["i"]).to_i] = r }
        buckets.each_with_index.map do |bucket, i|
          r = found[i] || {}
          { "start" => bucket["start"], "clicks" => Sql.num(r["clicks"]), "visitors" => Sql.num(r["visitors"]) }
        end
      end

      # One link's clicks by a visit dimension: where they came from, where they were, what they used.
      # [{"value", "visitors", "events"}].
      def link_breakdown(site, link, from, to, dimension, limit)
        col = "s.#{Query::SESSION_DIMENSIONS[dimension]}"
        rows = @db.all(
          "SELECT #{col} AS value, COUNT(*) AS clicks, COUNT(DISTINCT e.visitor) AS visitors
       FROM rl_events e JOIN rl_sessions s ON s.id = e.session
       WHERE e.site = ? AND e.link = ? AND e.kind = 'click' AND e.ts >= ? AND e.ts < ? AND #{col} <> ''
       GROUP BY #{col} ORDER BY clicks DESC, #{col}#{text_order} LIMIT ?",
          [site, link, from, to, limit],
        )
        rows.map { |row| { "value" => Sql.string(row["value"]), "visitors" => Sql.num(row["visitors"]), "events" => Sql.num(row["clicks"]) } }
      end

      # Reports

      # When Runlight itself first counted a visit, leaving out imported history.
      def first_own_visit(site)
        # A session opened only by a short link click is not a visit, so it does not count as the first.
        row = @db.all("SELECT MIN(started_at) AS t FROM rl_sessions s WHERE s.site = ? AND s.imported = 0 AND #{Sql::IS_VISIT}", [site])[0]
        row.nil? || row["t"].nil? ? nil : Sql.num(row["t"])
      end

      # When the site's first visit was recorded, or nil with no data yet.
      def first_seen(site)
        row = @db.all("SELECT MIN(started_at) AS t FROM rl_sessions WHERE site = ?", [site])[0]
        row.nil? || row["t"].nil? ? nil : Sql.num(row["t"])
      end

      # Just the visitor count from stats(), in one query, for conversion rates.
      def visitors(query)
        scope = Sql.visit_scope(query["filters"], query["site"], query["from"], query["to"], @db.dialect)
        row = @db.all(
          "SELECT COUNT(DISTINCT s.visitor) AS visitors FROM rl_sessions s WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND #{Sql::IS_VISIT}#{scope["sql"]}",
          [query["site"], query["from"], query["to"], *scope["params"]],
        )[0] || {}
        Sql.num(row["visitors"])
      end

      # {"visitors", "visits", "pageviews", "viewsPerVisit", "bounceRate", "visitDuration"}.
      def stats(query)
        rolled = rolled_stats(query)
        return rolled unless rolled.nil?

        # Filtered or not, the numbers describe visits that started in the range (see visit_scope).
        scope = Sql.visit_scope(query["filters"], query["site"], query["from"], query["to"], @db.dialect)
        pv = Sql.pageviews_of(query["filters"], query["site"], query["from"], query["to"], @db.dialect)
        row = @db.all(
          "SELECT COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits, SUM(#{pv ? "COALESCE(pv.n, 0)" : "s.pageviews"}) AS pageviews,
         SUM(CASE WHEN #{Sql::BOUNCE} THEN 1 ELSE 0 END) AS bounced, SUM(#{Sql::DURATION}) AS duration
       FROM rl_sessions s #{pv ? "LEFT JOIN #{pv["sql"]} pv ON pv.session = s.id" : ""}
       WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND #{Sql::IS_VISIT}#{scope["sql"]}",
          [*(pv ? pv["params"] : []), query["site"], query["from"], query["to"], *scope["params"]],
        )[0] || {}
        stats_of(Sql.num(row["visitors"]), Sql.num(row["visits"]), Sql.num(row["pageviews"]), Sql.num(row["bounced"]), Sql.num(row["duration"]))
      end

      # query: {"site", "filters"}. [{"start", "visitors", "visits", "pageviews", "viewsPerVisit", "bounceRate", "visitDuration"}].
      def series(query, buckets)
        buckets = buckets.to_a
        return [] if buckets.empty?
        return Sql.in_pieces(buckets, Sql::BUCKETS_PER_QUERY) { |piece| series(query, piece) } if buckets.length > Sql::BUCKETS_PER_QUERY

        params = bucket_params(buckets)
        first = buckets[0]["start"]
        last = buckets[-1]["end"]
        dialect = @db.dialect
        # Filtered or not, each bucket counts the visits that started in it (see visit_scope).
        scope = Sql.visit_scope(query["filters"], query["site"], first, last, dialect)
        pv = Sql.pageviews_of(query["filters"], query["site"], first, last, dialect)
        # Built days that fit inside one bucket come from rollups; the rest from the visits.
        plan = rollup_plan(query, first, last)
        in_bucket = lambda do |d|
          buckets.each_with_index { |b, i| return i if b["start"] <= d["start"] && d["end"] <= b["end"] }
          -1
        end
        used = plan ? plan["days"].select { |d| in_bucket.call(d) >= 0 } : []
        rest = nil
        unless used.empty?
          rest = []
          from = first
          used.each do |d|
            rest << [from, d["start"]] if d["start"] > from
            from = [from, d["end"]].max
          end
          rest << [from, last] if from < last
        end
        # MySQL joins the buckets to every visit of the site unless told the whole range as well.
        w = if rest then within(rest)
            elsif dialect == "mysql" then within([[first, last]])
            else { "sql" => "1 = 1", "params" => [] }
            end
        # Filters and scattered unbuilt days add values of their own; when they would pass D1's 100, the
        # buckets go in halves.
        if params.length + 1 + w["params"].length + scope["params"].length + (pv ? pv["params"].length : 0) > Sql::MAX_PARAMS && buckets.length > 1
          half = (buckets.length / 2.0).ceil
          return series(query, buckets[0, half]) + series(query, buckets[half..])
        end
        sums = {}
        bump = lambda do |i, row|
          into = sums[i] || { "visitors" => 0, "n" => 0, "views" => 0, "bounced" => 0, "duration" => 0 }
          sums[i] = into.to_h { |k, n| [k, n + Sql.num(row[k])] }
        end
        unless used.empty?
          rolled = @db.all(
            "SELECT day, visitors, visits AS n, pageviews AS views, bounced, duration FROM rl_rollups WHERE site = ? AND dim = '' AND day IN (#{Sql::BUILT_DAYS})",
            [query["site"], query["site"], first, last],
          )
          at = {}
          used.each { |d| at[d["day"]] = in_bucket.call(d) }
          rolled.each do |row|
            day = Sql.string(row["day"])
            bump.call(at[day], row) if at.key?(day)
          end
        end
        rows = @db.all(
          "WITH b (i, bs, be) AS (#{Sql.bucket_table(dialect, buckets)})
       SELECT b.i AS i, COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS n, SUM(#{pv ? "COALESCE(pv.n, 0)" : "s.pageviews"}) AS views,
         SUM(CASE WHEN #{Sql::BOUNCE} THEN 1 ELSE 0 END) AS bounced, SUM(#{Sql::DURATION}) AS duration
       FROM b JOIN rl_sessions s ON s.site = ? AND s.started_at >= b.bs AND s.started_at < b.be
       #{pv ? "LEFT JOIN #{pv["sql"]} pv ON pv.session = s.id" : ""}
       WHERE #{Sql::IS_VISIT}#{scope["sql"]} AND #{w["sql"]}
       GROUP BY b.i",
          [*params, query["site"], *(pv ? pv["params"] : []), *scope["params"], *w["params"]],
        )
        rows.each { |row| bump.call(Sql.num(row["i"]).to_i, row) }
        buckets.each_with_index.map do |bucket, i|
          row = sums[i] || {}
          n = Sql.num(row["n"])
          views = Sql.num(row["views"])
          {
            "start" => bucket["start"],
            "visitors" => Sql.num(row["visitors"]),
            "visits" => n,
            "pageviews" => views,
            "viewsPerVisit" => n.positive? ? whole(Js.round(views.fdiv(n) * 100) / 100) : 0,
            "bounceRate" => n.positive? ? whole(Sql.num(row["bounced"]).fdiv(n)) : 0,
            "visitDuration" => n.positive? ? whole(Js.round(Sql.num(row["duration"]).fdiv(n))) : 0,
          }
        end
      end

      # BreakdownRow list.
      def breakdown(query, dimension, limit, offset)
        page = [limit, offset]
        dialect = @db.dialect
        if dimension == "ai_agent" || dimension == "ai_page"
          col = dimension == "ai_agent" ? "e.name" : "e.path"
          rows = @db.all(
            "SELECT #{col} AS value, COUNT(*) AS fetches FROM rl_events e
         WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'fetch'
         GROUP BY #{col} ORDER BY fetches DESC, #{col}#{text_order} LIMIT ? OFFSET ?",
            [query["site"], query["from"], query["to"], *page],
          )
          return rows.map { |row| { "value" => Sql.string(row["value"]), "visitors" => 0, "fetches" => Sql.num(row["fetches"]) } }
        end

        rolled = rolled_breakdown(query, dimension, limit, offset)
        return rolled unless rolled.nil?

        # Filtered or not, the visits are those that started in the range (see visit_scope).
        scope = Sql.visit_scope(query["filters"], query["site"], query["from"], query["to"], dialect)
        if Query.session_dimension?(dimension)
          pv = Sql.pageviews_of(query["filters"], query["site"], query["from"], query["to"], dialect)
          col = "s.#{Query::SESSION_DIMENSIONS[dimension]}"
          entry_exit = dimension == "entry" || dimension == "exit"
          rows = @db.all(
            "SELECT #{col} AS value, COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits, SUM(#{pv ? "COALESCE(pv.n, 0)" : "s.pageviews"}) AS pageviews,
           SUM(CASE WHEN #{Sql::BOUNCE} THEN 1 ELSE 0 END) AS bounced, SUM(#{Sql::DURATION}) AS duration
         FROM rl_sessions s #{pv ? "LEFT JOIN #{pv["sql"]} pv ON pv.session = s.id" : ""}
         WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND #{Sql::IS_VISIT}#{scope["sql"]} AND #{col} <> ''
         GROUP BY #{col} ORDER BY #{entry_exit ? "visits DESC" : "visitors DESC, visits DESC"}, #{col}#{text_order} LIMIT ? OFFSET ?",
            [*(pv ? pv["params"] : []), query["site"], query["from"], query["to"], *scope["params"], *page],
          )
          return rows.map do |row|
            visits = Sql.num(row["visits"])
            out = {
              "value" => Sql.string(row["value"]),
              "visitors" => Sql.num(row["visitors"]),
              "visits" => visits,
              "bounceRate" => visits.positive? ? whole(Sql.num(row["bounced"]).fdiv(visits)) : 0,
            }
            unless entry_exit
              out["pageviews"] = Sql.num(row["pageviews"])
              out["visitDuration"] = visits.positive? ? whole(Js.round(Sql.num(row["duration"]).fdiv(visits))) : 0
            end
            out
          end
        end

        # Rows from the visits that started in the range and that the filters pick, narrowed by any filter on
        # the same kind of row ("page is /pricing" on pages), as the rollups count them.
        within = lambda do |dimensions|
          rows = Sql.row_scope(query["filters"], dimensions, dialect)
          {
            "sql" => " AND e.session IN (SELECT s.id FROM rl_sessions s WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND #{Sql::IS_VISIT}#{scope["sql"]})#{rows["sql"]}",
            "params" => [query["site"], query["from"], query["to"], *scope["params"], *rows["params"]],
            "to" => query["to"] + Sql::EVENT_TAIL_MS,
          }
        end

        if dimension == "page" || dimension == "hostname"
          col = "e.#{Query::EVENT_DIMENSIONS[dimension]}"
          w = within.call(%w[page hostname])
          rows = @db.all(
            "SELECT #{col} AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(*) AS pageviews, #{Sql::LIVE_VIEWS} AS views
         FROM rl_events e
         WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'pageview'#{w["sql"]}
         GROUP BY #{col} ORDER BY visitors DESC, pageviews DESC, #{col}#{text_order} LIMIT ? OFFSET ?",
            [query["site"], query["from"], w["to"], *w["params"], *page],
          )
          out = rows.map { |row| { "value" => Sql.string(row["value"]), "visitors" => Sql.num(row["visitors"]), "pageviews" => Sql.num(row["pageviews"]) } }
          live = {}
          rows.each { |row| live[Sql.string(row["value"])] = Sql.num(row["views"]) }
          if dimension == "page" && !out.empty?
            # Each pageview's engaged time added up and its deepest scroll, then the mean over pageviews. Filters add
            # values of their own, so fewer paths go in each statement, keeping it within D1's 100.
            size = [1, [Sql::VALUES_PER_QUERY, Sql::MAX_PARAMS - 3 - w["params"].length].min].max
            times = Sql.in_pieces(out, size) do |piece|
              @db.all(
                "SELECT value, SUM(total) AS total, COUNT(*) AS views, AVG(deepest) AS scroll FROM (
               SELECT e.path AS value, SUM(e.engaged_ms) AS total, MAX(e.scroll) AS deepest
               FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'engagement'#{w["sql"]}
               AND e.path IN (#{(["?"] * piece.length).join(", ")}) GROUP BY e.path, e.pageview) t GROUP BY value",
                [query["site"], query["from"], w["to"], *w["params"], *piece.map { |r| r["value"] }],
              )
            end
            by_path = {}
            times.each { |t| by_path[Sql.string(t["value"])] = t }
            out.each do |row|
              time = by_path[row["value"]]
              views = live[row["value"]] || 0
              row["timeOnPage"] = !time.nil? && views != 0 ? whole(Js.round(Sql.num(time["total"]).fdiv(views))) : 0
              row["scrollDepth"] = time.nil? || time["scroll"].nil? ? 0 : whole(Js.round(Sql.num(time["scroll"])))
            end
          end
          return out
        end

        if dimension == "event"
          w = within.call(["event"])
          rows = @db.all(
            "SELECT e.name AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(*) AS events
         FROM rl_events e
         WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'event'#{w["sql"]}
         GROUP BY e.name ORDER BY visitors DESC, events DESC, e.name#{text_order} LIMIT ? OFFSET ?",
            [query["site"], query["from"], w["to"], *w["params"], *page],
          )
          return rows.map { |row| { "value" => Sql.string(row["value"]), "visitors" => Sql.num(row["visitors"]), "events" => Sql.num(row["events"]) } }
        end

        []
      end

      # Visits by quarter hour since the epoch, which the caller folds into local weekdays and hours,
      # keeping time zones (DST included) out of SQL. Quarters, not hours, so a site in a
      # half-hour or 45-minute timezone (India, Nepal) folds each into the right local hour.
      # [{"quarter", "visits", "visitors", "pageviews", "bounced"}].
      def hourly(query)
        dialect = @db.dialect
        plan = rollup_plan(query, query["from"], query["to"])
        unless plan.nil?
          sums = {}
          bump = lambda do |quarter, row|
            key = quarter.to_s
            into = sums[key] || { "quarter" => quarter, "visits" => 0, "visitors" => 0, "pageviews" => 0, "bounced" => 0 }
            into["visits"] += Sql.num(row["visits"])
            into["visitors"] += Sql.num(row["visitors"])
            into["pageviews"] += Sql.num(row["pageviews"])
            into["bounced"] += Sql.num(row["bounced"])
            sums[key] = into
          end
          rolled = @db.all(
            "SELECT value, visits, visitors, pageviews, bounced FROM rl_rollups WHERE site = ? AND dim = 'quarter' AND day IN (#{Sql::BUILT_DAYS})",
            [query["site"], query["site"], query["from"], query["to"]],
          )
          rolled.each { |row| bump.call(Js.number(Sql.string(row["value"])), row) }
          w = within(plan["rest"])
          raw = @db.all(
            "SELECT #{Sql.div(dialect, "s.started_at", 900_000)} AS quarter, COUNT(*) AS visits, COUNT(DISTINCT s.visitor) AS visitors,
           SUM(s.pageviews) AS pageviews, SUM(CASE WHEN #{Sql::BOUNCE} THEN 1 ELSE 0 END) AS bounced
         FROM rl_sessions s WHERE s.site = ? AND #{w["sql"]} AND #{Sql::IS_VISIT} GROUP BY 1",
            [query["site"], *w["params"]],
          )
          raw.each { |row| bump.call(whole(Sql.num(row["quarter"]).floor), row) }
          return sums.values
        end
        matching = Sql.visit_scope(query["filters"], query["site"], query["from"], query["to"], dialect)
        # A page filter counts that page's views as pageviews here too, as the cards do.
        pv = Sql.pageviews_of(query["filters"], query["site"], query["from"], query["to"], dialect)
        rows = @db.all(
          "SELECT #{Sql.div(dialect, "s.started_at", 900_000)} AS quarter, COUNT(*) AS visits, COUNT(DISTINCT s.visitor) AS visitors,
         SUM(#{pv ? "COALESCE(pv.n, 0)" : "s.pageviews"}) AS pageviews, SUM(CASE WHEN #{Sql::BOUNCE} THEN 1 ELSE 0 END) AS bounced
       FROM rl_sessions s #{pv ? "LEFT JOIN #{pv["sql"]} pv ON pv.session = s.id" : ""}
       WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ? AND #{Sql::IS_VISIT}#{matching["sql"]}
       GROUP BY 1",
          [*(pv ? pv["params"] : []), query["site"], query["from"], query["to"], *matching["params"]],
        )
        rows.map do |row|
          {
            "quarter" => whole(Sql.num(row["quarter"]).floor),
            "visits" => Sql.num(row["visits"]),
            "visitors" => Sql.num(row["visitors"]),
            "pageviews" => Sql.num(row["pageviews"]),
            "bounced" => Sql.num(row["bounced"]),
          }
        end
      end

      # {"visitors", "pages", "sources", "countries", "minutes", "recent"}.
      def realtime(site, now)
        since = now - 5 * 60_000
        active = @db.all(
          "SELECT COUNT(DISTINCT visitor) AS n FROM rl_events WHERE site = ? AND ts >= ? AND kind IN ('pageview', 'event', 'engagement')",
          [site, since],
        )[0] || {}
        pages = @db.all(
          "SELECT path AS value, COUNT(DISTINCT visitor) AS visitors FROM rl_events
       WHERE site = ? AND ts >= ? AND kind = 'pageview' GROUP BY path ORDER BY visitors DESC, path#{text_order} LIMIT 10",
          [site, since],
        )
        sources = @db.all(
          "SELECT s.source AS value, COUNT(DISTINCT e.visitor) AS visitors FROM rl_events e JOIN rl_sessions s ON s.id = e.session
       WHERE e.site = ? AND e.ts >= ? AND e.kind IN ('pageview', 'event') AND s.source <> ''
       GROUP BY s.source ORDER BY visitors DESC, s.source#{text_order} LIMIT 10",
          [site, since],
        )
        start = now.fdiv(60_000).floor * 60_000 - 29 * 60_000
        per_minute = @db.all(
          "SELECT #{Sql.div(@db.dialect, "(ts - ?)", 60_000)} AS m, COUNT(*) AS n FROM rl_events
       WHERE site = ? AND ts >= ? AND kind = 'pageview' GROUP BY 1",
          [start, site, start],
        )
        minutes = Array.new(30, 0)
        per_minute.each do |row|
          index = Sql.num(row["m"]).floor
          minutes[index] += Sql.num(row["n"]) if index >= 0 && index < 30
        end
        countries = @db.all(
          "SELECT s.country AS value, COUNT(DISTINCT e.visitor) AS visitors FROM rl_events e JOIN rl_sessions s ON s.id = e.session
       WHERE e.site = ? AND e.ts >= ? AND e.kind IN ('pageview', 'event') AND s.country <> ''
       GROUP BY s.country ORDER BY visitors DESC, s.country#{text_order} LIMIT 10",
          [site, since],
        )
        recent = @db.all(
          "SELECT e.ts, e.kind, e.path, e.name, s.country, s.city, s.source, s.device FROM rl_events e JOIN rl_sessions s ON s.id = e.session
       WHERE e.site = ? AND e.ts >= ? AND e.kind IN ('pageview', 'event') ORDER BY e.ts DESC, e.id DESC LIMIT 20",
          [site, start],
        )
        pairs = ->(list) { list.map { |row| { "value" => Sql.string(row["value"]), "visitors" => Sql.num(row["visitors"]) } } }
        {
          "visitors" => Sql.num(active["n"]),
          "pages" => pairs.call(pages),
          "sources" => pairs.call(sources),
          "countries" => pairs.call(countries),
          "minutes" => minutes,
          "recent" => recent.map do |r|
            {
              "ts" => Sql.num(r["ts"]),
              "kind" => Sql.string(r["kind"]),
              "path" => Sql.string(r["path"]),
              "name" => Sql.string(r["name"]),
              "country" => Sql.string(r["country"]),
              "city" => Sql.string(r["city"]),
              "source" => Sql.string(r["source"]),
              "device" => Sql.string(r["device"]),
            }
          end,
        }
      end

      private

      # SQL for "a visit that started in one of these stretches".
      def within(rest)
        return { "sql" => "1 = 0", "params" => [] } if rest.empty?

        {
          "sql" => "(#{(["(s.started_at >= ? AND s.started_at < ?)"] * rest.length).join(" OR ")})",
          "params" => rest.flat_map { |r| [r[0], r[1]] },
        }
      end

      def stats_of(visitors, visits, pageviews, bounced, duration)
        {
          "visitors" => visitors,
          "visits" => visits,
          "pageviews" => pageviews,
          "viewsPerVisit" => visits.positive? ? whole(Js.round(pageviews.fdiv(visits) * 100) / 100) : 0,
          "bounceRate" => visits.positive? ? whole(bounced.fdiv(visits)) : 0,
          "visitDuration" => visits.positive? ? whole(Js.round(duration.fdiv(visits))) : 0,
        }
      end

      # A whole Float as an Integer, as JavaScript holds one number type; anything else as it is.
      def whole(n)
        n.is_a?(Float) && n.finite? && n == n.floor && n.abs < 2**53 ? n.to_i : n
      end

      # Math.round(n * 100) / 100, for money.
      def cents(n)
        whole(Js.round(n * 100) / 100)
      end

      def bucket_params(buckets)
        buckets.each_with_index.flat_map { |b, i| [i, b["start"], b["end"]] }
      end

      # True for a database reached one statement at a time with a cap on statements per request (Cloudflare D1).
      def metered?
        @db.respond_to?(:metered?) && @db.metered?
      end

      # How many rows an UPDATE or DELETE of rows with an id matched. MySQL has no RETURNING, so its driver counts them.
      def changed(sql, params)
        return @db.affected(sql, params) if @db.dialect == "mysql" && @db.respond_to?(:affected)

        @db.all("#{sql} RETURNING id", params).length
      end

      def upgrade(db, postgres)
        statements = Sql.schema(db.dialect)
        db.run(statements[0])
        found = db.all("SELECT value FROM rl_meta WHERE \"key\" = 'schema'")[0]
        from = found.nil? ? Sql::SCHEMA_VERSION : Js.number(Sql.string(found["value"]))
        if postgres
          # A concurrent build that was stopped leaves its index unusable; it goes, and is built again below.
          broken = db.all(
            "SELECT c.relname AS name FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
           WHERE NOT i.indisvalid AND c.relname LIKE 'rl\\_%' AND c.relnamespace = current_schema()::regnamespace",
          )
          broken.each { |row| db.run("DROP INDEX IF EXISTS \"#{Sql.string(row["name"]).delete('"')}\"") }
        end
        statements.each do |statement|
          index = statement.match(/\ACREATE (UNIQUE )?INDEX IF NOT EXISTS (\w+) ON (\w+)/)
          if db.dialect == "mysql" && index
            # MySQL has no CREATE INDEX IF NOT EXISTS, so it is looked for first.
            unique, name, table = index.captures
            there = db.all("SELECT 1 AS there FROM information_schema.statistics WHERE table_schema = DATABASE() AND table_name = ? AND index_name = ? LIMIT 1", [table, name])
            db.run(statement.sub(/\ACREATE (UNIQUE )?INDEX IF NOT EXISTS/, "CREATE #{unique}INDEX")) if there.empty?
          else
            db.run(postgres ? statement.sub(/\ACREATE (UNIQUE )?INDEX IF NOT EXISTS/) { "CREATE #{Regexp.last_match(1)}INDEX CONCURRENTLY IF NOT EXISTS" } : statement)
          end
        end
        # A column added by an upgrade that stopped before it recorded the new version is already there.
        add_column = lambda do |sql|
          db.run(sql)
        rescue StandardError => e
          raise unless e.message.match?(/duplicate column|already exists/i)
        end
        # Version 2: settings changed in the dashboard, kept apart from the ones in code.
        add_column.call("ALTER TABLE rl_sites ADD COLUMN overrides TEXT NOT NULL DEFAULT '{}'") if from < 2
        db.run("DROP INDEX IF EXISTS rl_links_slug") if from < 4
        # Version 10: tokens that may change one site's settings, for a hub.
        add_column.call("ALTER TABLE rl_tokens ADD COLUMN scope TEXT NOT NULL DEFAULT 'read'") if from >= 8 && from < 10
        # Written only when it changes, so a database opened read-only can still be read.
        return unless found.nil? || Sql.string(found["value"]) != Sql::SCHEMA_VERSION.to_s

        db.run(Sql.upsert(db.dialect, "rl_meta", ['"key"', "value"], ['"key"'], ["value"]), ["schema", Sql::SCHEMA_VERSION.to_s])
      end

      # When a site's oldest row at or after `from` is (nil for no lower bound), or nil when there is none.
      def oldest(table, col, site, from)
        row = @db.all("SELECT MIN(#{col}) AS t FROM #{table} WHERE site = ?#{from.nil? ? "" : " AND #{col} >= ?"}", from.nil? ? [site] : [site, from])[0]
        row.nil? || row["t"].nil? ? nil : Sql.num(row["t"])
      end

      # How to answer a range from rollups: the built days that lie wholly inside
      # it, and the stretches left over, which are read from the visits as usual.
      # Nil when no built day helps.
      def rollup_plan(query, from, to)
        return nil unless query["filters"].to_a.empty?

        rows = @db.all("SELECT day, start_at, end_at FROM rl_rollup_days WHERE site = ? AND start_at >= ? AND end_at <= ? ORDER BY start_at", [query["site"], from, to])
        return nil if rows.empty?

        days = rows.map { |r| { "day" => Sql.string(r["day"]), "start" => Sql.num(r["start_at"]), "end" => Sql.num(r["end_at"]) } }
        rest = []
        at = from
        days.each do |d|
          rest << [at, d["start"]] if d["start"] > at
          at = [at, d["end"]].max
        end
        rest << [at, to] if at < to
        { "days" => days, "rest" => rest }
      end

      # A breakdown of a visit dimension or of pages from rollups and the visits
      # left over, merged, then sorted and cut to the page asked for.
      def rolled_breakdown(query, dimension, limit, offset)
        page = dimension == "page"
        event = dimension == "event"
        return nil if !page && !event && !Query.session_dimension?(dimension)
        return nil unless query["filters"].to_a.empty?

        # Pages and events always go this way without filters, so a range gives the same answer whether its days are built or not.
        plan = rollup_plan(query, query["from"], query["to"]) || (page || event ? { "days" => [], "rest" => [[query["from"], query["to"]]] } : nil)
        return nil if plan.nil?

        zero = { "visitors" => 0, "visits" => 0, "pageviews" => 0, "bounced" => 0, "duration" => 0, "engaged" => 0, "views" => 0, "scroll_sum" => 0, "scroll_n" => 0, "events" => 0 }
        # Keyed by value in the order first seen.
        sums = {}
        bump = lambda do |row|
          key = Sql.string(row["value"])
          sums[key] = (sums[key] || zero).to_h { |k, n| [k, n + Sql.num(row[k])] }
        end
        unless plan["days"].empty?
          rolled = @db.all(
            "SELECT value, SUM(visitors) AS visitors, SUM(visits) AS visits, SUM(pageviews) AS pageviews, SUM(bounced) AS bounced, SUM(duration) AS duration,
           SUM(engaged) AS engaged, SUM(views) AS views, SUM(scroll_sum) AS scroll_sum, SUM(scroll_n) AS scroll_n, SUM(events) AS events
         FROM rl_rollups WHERE site = ? AND dim = ? AND day IN (#{Sql::BUILT_DAYS}) GROUP BY value",
            [query["site"], dimension, query["site"], query["from"], query["to"]],
          )
          rolled.each { |row| bump.call(row) }
        end
        w = within(plan["rest"])
        if (page || event) && !plan["rest"].empty?
          # A visit's pageviews and events belong to the day it started, as in the rollups.
          # Bounded by time as well, so the events index finds them (see build_rollup_day).
          lo = plan["rest"].map { |r| r[0] }.min
          hi = plan["rest"].map { |r| r[1] }.max + Sql::EVENT_TAIL_MS
          of_rest = ->(kind) { "FROM rl_events e JOIN rl_sessions s ON s.id = e.session WHERE e.site = ? AND e.kind = '#{kind}' AND e.ts >= ? AND e.ts < ? AND #{Sql::IS_VISIT} AND #{w["sql"]}" }
          at = [query["site"], lo, hi, *w["params"]]
          if page
            @db.all("SELECT e.path AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(DISTINCT e.session) AS visits, COUNT(*) AS pageviews, #{Sql::LIVE_VIEWS} AS views #{of_rest.call("pageview")} GROUP BY e.path", at).each { |row| bump.call(row) }
            @db.all(
              "SELECT value, SUM(total) AS engaged, SUM(deepest) AS scroll_sum, COUNT(deepest) AS scroll_n FROM (
             SELECT e.path AS value, SUM(e.engaged_ms) AS total, MAX(e.scroll) AS deepest #{of_rest.call("engagement")} GROUP BY e.path, e.pageview) t GROUP BY value",
              at,
            ).each { |row| bump.call(row) }
          else
            @db.all("SELECT e.name AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(*) AS events #{of_rest.call("event")} GROUP BY e.name", at).each { |row| bump.call(row) }
          end
        elsif page || event
          # Every day of the range is built.
        else
          col = "s.#{Query::SESSION_DIMENSIONS[dimension]}"
          @db.all(
            "SELECT #{col} AS value, COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits, SUM(s.pageviews) AS pageviews,
           SUM(CASE WHEN #{Sql::BOUNCE} THEN 1 ELSE 0 END) AS bounced, SUM(#{Sql::DURATION}) AS duration
         FROM rl_sessions s WHERE s.site = ? AND #{Sql::IS_VISIT} AND #{w["sql"]} AND #{col} <> '' GROUP BY #{col}",
            [query["site"], *w["params"]],
          ).each { |row| bump.call(row) }
        end
        entry_exit = dimension == "entry" || dimension == "exit"
        rows = sums.select do |value, x|
          (event || value != "") && (page ? x["pageviews"].positive? : (event ? x["events"].positive? : x["visits"].positive?))
        end.to_a
        rows.sort! do |(a, x), (b, y)|
          order = if entry_exit then [y["visits"] - x["visits"]]
                  elsif event then [y["visitors"] - x["visitors"], y["events"] - x["events"]]
                  elsif page then [y["visitors"] - x["visitors"], y["pageviews"] - x["pageviews"]]
                  else [y["visitors"] - x["visitors"], y["visits"] - x["visits"]]
                  end
          d = order.find { |n| n != 0 }
          d.nil? ? Sql.code_order(a, b) : (d.negative? ? -1 : 1)
        end
        (rows[offset, limit] || []).map do |value, x|
          if event
            { "value" => value, "visitors" => x["visitors"], "events" => x["events"] }
          elsif page
            {
              "value" => value,
              "visitors" => x["visitors"],
              "pageviews" => x["pageviews"],
              # Over every pageview that could report its time, counting those that sent none (under a second) as none.
              "timeOnPage" => x["views"].positive? ? whole(Js.round(x["engaged"].fdiv(x["views"]))) : 0,
              "scrollDepth" => x["scroll_n"].positive? ? whole(Js.round(x["scroll_sum"].fdiv(x["scroll_n"]))) : 0,
            }
          else
            row = { "value" => value, "visitors" => x["visitors"], "visits" => x["visits"], "bounceRate" => x["visits"].positive? ? whole(x["bounced"].fdiv(x["visits"])) : 0 }
            unless entry_exit
              row["pageviews"] = x["pageviews"]
              row["visitDuration"] = x["visits"].positive? ? whole(Js.round(x["duration"].fdiv(x["visits"]))) : 0
            end
            row
          end
        end
      end

      def rolled_stats(query)
        plan = rollup_plan(query, query["from"], query["to"])
        return nil if plan.nil?

        rolled = @db.all(
          "SELECT SUM(visitors) AS visitors, SUM(visits) AS visits, SUM(pageviews) AS pageviews, SUM(bounced) AS bounced, SUM(duration) AS duration
       FROM rl_rollups WHERE site = ? AND dim = '' AND day IN (#{Sql::BUILT_DAYS})",
          [query["site"], query["site"], query["from"], query["to"]],
        )[0] || {}
        w = within(plan["rest"])
        raw = @db.all(
          "SELECT COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits, SUM(s.pageviews) AS pageviews,
         SUM(CASE WHEN #{Sql::BOUNCE} THEN 1 ELSE 0 END) AS bounced, SUM(#{Sql::DURATION}) AS duration
       FROM rl_sessions s WHERE s.site = ? AND #{Sql::IS_VISIT} AND #{w["sql"]}",
          [query["site"], *w["params"]],
        )[0] || {}
        add = ->(k) { Sql.num(rolled[k]) + Sql.num(raw[k]) }
        stats_of(add.call("visitors"), add.call("visits"), add.call("pageviews"), add.call("bounced"), add.call("duration"))
      end

      def share_row(r)
        { "id" => Sql.string(r["id"]), "site" => Sql.string(r["site"]), "name" => Sql.string(r["name"]), "createdAt" => Sql.number(r["created_at"]) }
      end

      def token_row(r)
        {
          "id" => Sql.string(r["id"]),
          "name" => Sql.string(r["name"]),
          "site" => Sql.string(r["site"]),
          "scope" => r["scope"] == "manage" ? "manage" : "read",
          "hash" => Sql.string(r["hash"]),
          "hint" => Sql.string(r["hint"]),
          "createdAt" => Sql.number(r["created_at"]),
          "lastUsedAt" => r["last_used_at"].nil? ? nil : Sql.number(r["last_used_at"]),
        }
      end

      def report_row(r)
        {
          "id" => Sql.string(r["id"]),
          "site" => Sql.string(r["site"]),
          "email" => Sql.string(r["email"]),
          "frequency" => Sql.string(r["frequency"]),
          "lang" => r["lang"].nil? ? "en" : Sql.string(r["lang"]),
          "token" => Sql.string(r["token"]),
          "origin" => Sql.string(r["origin"]),
          "lastPeriod" => Sql.string(r["last_period"]),
          "lastSentAt" => r["last_sent_at"].nil? ? nil : Sql.number(r["last_sent_at"]),
          "createdAt" => Sql.number(r["created_at"]),
        }
      end

      # The events a goal counts, as a WHERE fragment over rl_events e.
      def goal_scope(goal)
        if goal["kind"] == "page"
          return { "sql" => "e.kind = 'pageview' AND e.path = ?", "params" => [goal["match"]] } unless goal["match"].include?("*")

          if @db.dialect != "sqlite"
            # Postgres's LIKE heeds case, and so does MySQL's under Runlight's binary collation.
            return { "sql" => "e.kind = 'pageview' AND e.path LIKE ? ESCAPE '\\'", "params" => [Sql.like_pattern(goal["match"])] }
          end

          # SQLite's LIKE ignores case; GLOB does not, so every database agrees with the others and with exact matches.
          return { "sql" => "e.kind = 'pageview' AND e.path GLOB ?", "params" => [Sql.glob_pattern(goal["match"])] }
        end
        # Event goals count the named event; click goals count the event the tracker sends for them.
        { "sql" => "e.kind = 'event' AND e.name = ?", "params" => [goal["kind"] == "click" ? goal["name"] : goal["match"]] }
      end

      # A numeric event property for one row, as SQL (0 when it is not a number). Property names are checked before they get here.
      def prop_value(prop)
        if @db.dialect == "postgres"
          return {
            "sql" => '(CASE WHEN (e.props::jsonb ->> ?) ~ \'^-?[0-9]+(\.[0-9]+)?$\' THEN (e.props::jsonb ->> ?)::numeric ELSE 0 END)',
            "params" => [prop, prop],
          }
        end
        path = "$.\"#{prop}\""
        if @db.dialect == "mysql"
          # As SQLite: a JSON number as it is, or text of digits with an optional sign and one decimal point.
          value = "JSON_EXTRACT(e.props, ?)"
          return {
            "sql" => "(CASE
          WHEN JSON_TYPE(#{value}) IN ('INTEGER', 'UNSIGNED INTEGER', 'DOUBLE', 'DECIMAL') THEN CAST(#{value} AS DOUBLE)
          WHEN JSON_TYPE(#{value}) = 'STRING' AND JSON_UNQUOTE(#{value}) REGEXP '^-?[0-9]+([.][0-9]+)?$' THEN CAST(JSON_UNQUOTE(#{value}) AS DOUBLE)
          ELSE 0 END)",
            "params" => [path] * 5,
          }
        end
        # As Postgres's pattern: a JSON number, or text of digits with an optional sign and one decimal point.
        text = "CAST(json_extract(e.props, ?) AS TEXT)"
        {
          "sql" => "(CASE
        WHEN json_type(e.props, ?) IN ('integer', 'real') THEN json_extract(e.props, ?)
        WHEN json_type(e.props, ?) = 'text' AND #{text} GLOB '[0-9]*' AND #{text} NOT GLOB '*[^0-9.]*' AND #{text} NOT GLOB '*.*.*' AND #{text} NOT GLOB '*.' THEN CAST(#{text} AS REAL)
        WHEN json_type(e.props, ?) = 'text' AND #{text} GLOB '-[0-9]*' AND substr(#{text}, 2) NOT GLOB '*[^0-9.]*' AND #{text} NOT GLOB '*.*.*' AND #{text} NOT GLOB '*.' THEN CAST(#{text} AS REAL)
        ELSE 0 END)",
          "params" => [path] * 14,
        }
      end

      # The floating point type to cast to, which MySQL names in one word.
      def double
        @db.dialect == "mysql" ? "DOUBLE" : "DOUBLE PRECISION"
      end

      # A goal's worth for one converting row, as SQL.
      def revenue_value(goal)
        return prop_value(goal["valueProp"]) if goal["valueMode"] == "prop" && goal["valueProp"] != ""
        return { "sql" => "CAST(? AS #{double})", "params" => [goal["value"]] } if goal["valueMode"] == "fixed"

        { "sql" => "0", "params" => [] }
      end

      def revenue_sql(goal)
        if goal["valueMode"] == "prop" && goal["valueProp"] != ""
          value = prop_value(goal["valueProp"])
          return { "sql" => "SUM(#{value["sql"]})", "params" => value["params"] }
        end
        # Cast, so Postgres does not read the bound value as a bigint and refuse 9.99.
        return { "sql" => "COUNT(*) * CAST(? AS #{double})", "params" => [goal["value"]] } if goal["valueMode"] == "fixed"

        { "sql" => "0", "params" => [] }
      end

      # Ties are broken by the value in code point order, the order the rolled-up path sorts in, so a report
      # reads the same before and after its days are built. Postgres would otherwise use its locale's order.
      # MySQL's columns already sort this way; a value worked out from JSON may not.
      def text_order
        case @db.dialect
        when "postgres" then ' COLLATE "C"'
        when "mysql" then " COLLATE #{Sql::MYSQL_COLLATION}"
        else ""
        end
      end
    end
  end
end
