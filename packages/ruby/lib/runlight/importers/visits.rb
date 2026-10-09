# frozen_string_literal: true

module Runlight
  module Importers
    # Visit history from Umami: pageviews and custom events with where each
    # visit came from, its place, and its device, written as imported visits so
    # the dashboard's history does not start the day Runlight was installed.
    #
    # The dashboard drives it a few days at a time, oldest first, so it fits any
    # host's time limit and shows progress. It stops where Runlight's own visits
    # begin, so nothing is counted twice, and it remembers how far it got, so
    # running it again carries on from there.
    #
    # An ImportedHit, the shape every visit import writes, is a Hash: `ts`, `key` (groups rows into visitors,
    # as Umami's session id does), `kind` ("pageview" or "event"), and the strings `hostname`, `path`, `query`,
    # `referrer`, `title`, `name`, `country`, `region`, `city`, `browser`, `os`, `device`, `screen`, `language`.
    module Visits
      DAY = 86_400_000
      # Each step reads at most this many days, or stops after this many events.
      STEP_DAYS = 14
      STEP_EVENTS = 5_000
      # A single day with more than this is refused rather than read without end.
      MAX_DAY_EVENTS = 200_000

      # Umami's event types that are visits: a pageview, and a custom event.
      PAGEVIEW = 1
      CUSTOM_EVENT = 2
      private_constant :DAY, :STEP_DAYS, :STEP_EVENTS, :MAX_DAY_EVENTS, :PAGEVIEW, :CUSTOM_EVENT

      module_function

      def progress_key(site, website)
        "import:umami-visits:#{site}:#{website}"
      end

      # The websites an Umami account can see, to pick which one becomes this site's history: a list of
      # { "id", "name", "domain" }.
      def umami_websites(credentials, fetcher = nil)
        http = Client.new(fetcher)
        login = Umami.umami_sign_in(http, credentials)
        headers = { "authorization" => "Bearer #{Client.str(login["token"])}" }
        out = []
        (1...100).each do |page|
          body = http.get_json("#{login["base"]}/api/websites?page=#{page}&pageSize=100", { "headers" => headers })
          body["data"].each { |w| out << { "id" => w["id"], "name" => w["name"], "domain" => w["domain"] } }
          break if out.length >= (body["count"].nil? ? Float::INFINITY : body["count"]) || body["data"] == []
        end
        out
      end

      # Every page of an Umami list for a time window.
      def all(http, base, path, headers, limit)
        out = []
        page = 1
        loop do
          body = http.get_json("#{base}/api#{path}&page=#{page}&pageSize=1000", { "headers" => headers })
          body["data"].each { |row| out << row }
          return out if out.length >= (body["count"].nil? ? Float::INFINITY : body["count"]) || body["data"] == []

          if out.length > limit
            text = limit.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
            raise ImportError.new("One day has more than #{text} events, more than an import step can read", "import_day_full",
                                  { "limit" => limit.to_s })
          end
          page += 1
        end
      end

      # One step: read the next few days from Umami and write them as imported visits. Returns
      # { "cursor", "done", "total", "pageviews", "events", "visits" }.
      def import_umami_visits(runlight, site_id, credentials, website, cursor)
        runlight.init
        site = runlight.site(site_id)
        raise ImportError.new("Unknown site", "unknown_site") if site.nil?
        raise ImportError.new("Pick the Umami website to import", "import_website") unless website.match?(/\A[A-Za-z0-9-]{1,64}\z/)

        http = Client.new(runlight.fetcher)

        saved = !cursor.nil? && cursor != "" ? Json.decode(cursor) : nil
        login = Umami.umami_sign_in(http, credentials, saved.nil? ? nil : saved["token"])
        base = login["base"]
        token = login["token"]
        headers = { "authorization" => "Bearer #{Client.str(token)}" }
        if !saved.nil? && saved["website"] == website
          state = saved
        else
          info = http.get_json("#{base}/api/websites/#{website}", { "headers" => headers })
          created = Client.parse_date(info.is_a?(Hash) ? info["createdAt"] : nil)
          created = Js.truthy?(created) ? created : runlight.now
          # Carry on where an earlier run stopped, and end where Runlight's own visits begin.
          setting = runlight.store.setting(progress_key(site_id, website))
          resumed = Js.number(setting.nil? ? 0 : setting)
          # Never older than the site keeps, or the next scheduled check would delete it again.
          cutoff = runlight.retention_cutoff(site_id) || 0
          start = [(created.to_f / DAY).floor * DAY, resumed, (cutoff.to_f / DAY).ceil * DAY].max.to_i
          own = runlight.store.first_own_visit(site_id)
          state = { "website" => website, "day" => start, "start" => start, "end" => (own.nil? ? runlight.now : own).to_i }
        end
        uses_key = Client.trim(credentials["apiKey"].to_s) != ""

        # Read whole days until the step has enough.
        events = []
        from = state["day"].to_i
        to = state["day"].to_i
        finish = state["end"].to_i
        while to < finish && to - from < STEP_DAYS * DAY && events.length < STEP_EVENTS
          following = [to + DAY, finish].min
          all(http, base, "/websites/#{website}/events?startAt=#{to}&endAt=#{following - 1}", headers, MAX_DAY_EVENTS).each { |e| events << e }
          to = following
        end
        sessions = events.empty? ? [] : all(http, base, "/websites/#{website}/sessions?startAt=#{from}&endAt=#{to - 1}", headers, MAX_DAY_EVENTS * STEP_DAYS)
        info = {}
        sessions.each { |s| info[Client.str(s["id"])] = s }

        ns = "umami-visits:#{website}"
        visits = []
        events.each do |e|
          type = e["eventType"]
          next unless type == PAGEVIEW || (type == CUSTOM_EVENT && Js.truthy?(e["eventName"]))

          ts = Client.parse_date(e["createdAt"])
          next if (ts.is_a?(Float) && !ts.finite?) || ts >= finish

          visits << e.merge("ts" => ts.to_i)
        end
        visits = visits.each_with_index.sort_by { |e, i| [e["ts"], i] }.map(&:first)
        hits = visits.map { |e| { "ns" => ns, "hit" => from_umami(e, info[Client.str(e["sessionId"])]) } }
        counts = write_step(runlight, site_id, from, to, hits, lambda { |store|
          store.set_setting(progress_key(site_id, website), to.to_s)
        })

        total_days = [1, ((finish - state["start"]).to_f / DAY).ceil].max.to_i
        done_days = [total_days, ((to - state["start"]).to_f / DAY).ceil].min.to_i
        more = to < finish
        following = state.merge("day" => to)
        following["token"] = token unless uses_key
        {
          "cursor" => more ? Json.encode(following) : nil,
          "done" => done_days,
          "total" => total_days,
        }.merge(counts)
      end

      # Writes one step of imported visits, sorted oldest first, all within [from, to). Whatever an earlier import
      # left in those times is cleared first, so a step can always run again, and a visit carried in from the step
      # before is counted again from its rows. `done` runs in the same transaction, to remember how far it got.
      # Returns { "pageviews", "events", "visits" }.
      def write_step(runlight, site_id, from, to, hits, done = nil)
        site = runlight.site(site_id)
        raise ImportError.new("Unknown site", "unknown_site") if site.nil?

        counts = { "pageviews" => 0, "events" => 0, "visits" => 0 }
        tail = Store::SqlStore::EVENT_TAIL_MS
        runlight.store.transaction do |store|
          # Days this step writes into are added up again later, with the imported visits in them.
          store.clear_rollups(site_id, { "from" => from, "to" => to })
          # A failed earlier try at these days (on D1, which has no transactions) can
          # have left part of them behind. Clear it, so every step can safely run again.
          imported = "SELECT id FROM rl_sessions WHERE site = ? AND imported = 1"
          store.db.run("DELETE FROM rl_events WHERE site = ? AND ts >= ? AND ts < ? AND kind IN ('pageview', 'event') AND session IN (#{imported})",
                       [site_id, from, to, site_id])
          # Visits of these days that kept no rows go too. Their rows would come within EVENT_TAIL_MS of the step,
          # so the time bounds let the (site, ts) index find them, with no scan of every event.
          store.db.run(
            "DELETE FROM rl_sessions WHERE site = ? AND imported = 1 AND started_at >= ? AND started_at < ?
         AND id NOT IN (SELECT e.session FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ?)",
            [site_id, from, to, site_id, from, to + tail],
          )
          hits.each do |h|
            counts["visits"] += 1 if write_event(store, site, h["ns"], h["hit"])
            if h["hit"]["kind"] == "pageview"
              counts["pageviews"] += 1
            else
              counts["events"] += 1
            end
          end
          # A visit that began in an earlier step and went on into this one is counted
          # again from its rows, so a repeated step cannot leave it with doubled totals.
          # The day it began may already be built, so that day is built again too.
          carried = store.db.all(
            "SELECT s.id AS id, s.started_at AS started_at FROM rl_sessions s
       WHERE s.site = ? AND s.imported = 1 AND s.started_at < ? AND s.started_at >= ?
         AND s.id IN (SELECT e.session FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ?)",
            [site_id, from, from - tail, site_id, from, to],
          )
          unless carried.empty?
            earliest = carried.map { |c| Js.number(c["started_at"]) }.min.to_i
            store.clear_rollups(site_id, { "from" => earliest, "to" => from })
            # Their rows lie between the earliest start and this step's end, which the (site, ts) index reads in one pass.
            # Ninety ids a statement, within Cloudflare D1's 100 values.
            rows = []
            carried.each_slice(90) do |chunk|
              ids = chunk.map { |c| c["id"].to_s }
              store.db.all(
                "SELECT e.session AS session, e.kind AS kind, e.ts AS ts, e.path AS path FROM rl_events e
             WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind IN ('pageview', 'event') AND e.session IN (#{(["?"] * ids.length).join(", ")})
             ORDER BY e.ts, e.id",
                [site_id, earliest, to, *ids],
              ).each { |row| rows << row }
            end
            totals = {}
            rows.each do |r|
              session = r["session"].to_s
              t = totals[session] || { "pageviews" => 0, "events" => 0, "last" => 0, "exit" => nil }
              if r["kind"] == "pageview"
                t["pageviews"] += 1
                t["exit"] = r["path"].to_s
              else
                t["events"] += 1
              end
              t["last"] = [t["last"], Js.number(r["ts"])].max
              totals[session] = t
            end
            totals.each do |id, t|
              store.db.run("UPDATE rl_sessions SET pageviews = ?, events = ?, last_at = ?, exit_path = COALESCE(?, exit_path) WHERE id = ?",
                           [t["pageviews"], t["events"], t["last"], t["exit"], id.to_s])
            end
          end
          done&.call(store)
        end
        counts
      end

      def referrer_of(domain, path, query)
        return "" unless Js.truthy?(domain)

        path = Js.truthy?(path) ? Js.string(path) : "/"
        query = Js.truthy?(query) ? "?#{Js.string(query).sub(/\A\?/, "")}" : ""
        "https://#{Js.string(domain)}#{path}#{query}"
      end

      def from_umami(e, session)
        text = ->(value) { value.nil? ? "" : Js.string(value) }
        s = session.is_a?(Hash) ? session : {}
        region = if Js.truthy?(s["subdivision1"]) then s["subdivision1"]
                 elsif Js.truthy?(s["region"]) then s["region"]
                 else ""
                 end
        {
          "ts" => e["ts"],
          "key" => Client.str(e["sessionId"]),
          "kind" => e["eventType"] == PAGEVIEW ? "pageview" : "event",
          "hostname" => text.call(e["hostname"]),
          "path" => text.call(e["urlPath"]),
          "query" => text.call(e["urlQuery"]),
          "referrer" => referrer_of(e["referrerDomain"], e["referrerPath"], e["referrerQuery"]),
          "title" => text.call(e["pageTitle"]),
          "name" => text.call(e["eventName"]),
          "country" => text.call(e["country"]),
          "region" => Js.string(region),
          "city" => text.call(e["city"]),
          "browser" => text.call(e["browser"]),
          "os" => text.call(e["os"]),
          "device" => text.call(e["device"]),
          "screen" => text.call(s["screen"]),
          "language" => text.call(s["language"]),
        }
      end

      # Writes one imported pageview or event as part of a Runlight visit. Visitors
      # are hashed per day from the hit's key, as live visitors are hashed per day,
      # and a hit within thirty minutes of the visitor's last one joins that visit.
      # Ids come from `ns` and the key, so importing the same rows again makes the
      # same ids. Returns whether it started a new visit.
      def write_event(store, site, ns, e)
        # The site's own day, as live visitors are counted, so days add up the same way in rollups.
        day = Dates.local_date(e["ts"], site["timezone"])
        visitor = Write.hex_id("#{ns}:#{e["key"]}:#{day}", 16)
        # A visit that runs past midnight keeps the id it started with, as a live one does.
        yesterday = Write.hex_id("#{ns}:#{e["key"]}:#{Dates.add_days(day, -1)}", 16)
        host = Js.lower(e["hostname"].empty? ? site["hostnames"][0] || "imported.invalid" : e["hostname"])
        url = Http::Url.parse("https://#{host}#{e["path"].empty? ? "/" : e["path"]}#{e["query"].empty? ? "" : "?#{e["query"].sub(/\A\?/, "")}"}") ||
              Http::Url.new("https://#{host}/")
        page = Sources.parse_page(url)
        open = store.open_session(site["id"], [visitor, yesterday], e["ts"] - Core::SESSION_IDLE_MS)
        id = open.nil? ? nil : open["id"]
        if id.nil?
          id = Write.hex_id("#{ns}:#{e["key"]}:#{e["ts"]}")
          store.db.run("DELETE FROM rl_sessions WHERE id = ?", [id])
          country = Js.slice(Js.upper(e["country"]), 0, 2)
          raw_region = e["region"]
          region = raw_region.empty? ? "" : Js.slice(Js.upper(raw_region.include?("-") ? raw_region : "#{country}-#{raw_region}"), 0, 10)
          known = country.match?(/\A[A-Z]{2}\z/)
          store.insert_session(
            {
              "id" => id,
              "site" => site["id"],
              "visitor" => visitor,
              "startedAt" => e["ts"],
              "hostname" => page["hostname"],
            }.merge(Sources.attribute(page, e["referrer"], site["hostnames"])).merge(
              "utmSource" => page["utm"]["source"],
              "utmMedium" => page["utm"]["medium"],
              "utmCampaign" => page["utm"]["campaign"],
              "utmTerm" => page["utm"]["term"],
              "utmContent" => page["utm"]["content"],
              "country" => known ? country : "",
              "region" => known ? region : "",
              "city" => Js.slice(e["city"], 0, 100),
              "browser" => Write.browser(e["browser"]),
              "browserVersion" => "",
              "os" => Write.system_name(e["os"]),
              "osVersion" => "",
              "device" => Write.device(e["device"]),
              "screen" => Js.slice(e["screen"], 0, 20),
              "language" => Js.slice(e["language"], 0, 35),
            ),
          )
          # No engaged time is known, so duration falls back to first-to-last pageview.
          store.db.run("UPDATE rl_sessions SET imported = 1, engaged_ms = NULL WHERE id = ?", [id])
        end
        kind = e["kind"]
        store.touch_session(id, e["ts"], kind, page["path"])
        store.insert_event({
          "site" => site["id"],
          "ts" => e["ts"],
          "kind" => kind,
          # The visit's own visitor, which for one running past midnight is the id of the day it started.
          "visitor" => open.nil? || open["visitor"].nil? ? visitor : open["visitor"],
          "session" => id,
          "pageview" => "",
          "path" => page["path"],
          "hostname" => page["hostname"],
          "title" => kind == "pageview" ? Js.slice(e["title"], 0, 300) : "",
          "name" => kind == "event" ? Js.slice(e["name"], 0, 120) : "",
          "props" => nil,
          "engagedMs" => 0,
          "scroll" => nil,
          "link" => "",
        })
        open.nil?
      end

      # One batch of a CSV file, sorted oldest first by the dashboard. As with Umami, only rows from before
      # Runlight's own first visit, and within what the site keeps, are written. A batch can run again: its
      # time span is cleared first, so batches must not share a moment, which the dashboard sees to.
      # Returns { "pageviews", "events", "visits", "skipped" }.
      def import_csv_visits(runlight, site_id, rows)
        runlight.init
        raise ImportError.new("Unknown site", "unknown_site") if runlight.site(site_id).nil?
        if !rows.is_a?(Array) || rows.length > CsvVisits::CSV_BATCH
          raise ImportError.new("Send at most #{CsvVisits::CSV_BATCH} rows at a time", "import_csv_batch", { "max" => CsvVisits::CSV_BATCH.to_s })
        end

        clean = rows.map do |r|
          entries = if r.is_a?(Hash) then r
                    elsif r.is_a?(Array) then r.each_with_index.map { |v, i| [i, v] }
                    else []
                    end
          row = {}
          entries.each { |k, v| row[Js.lower(Js.trim(k.to_s))] = v.nil? ? "" : Js.string(v) }
          row
        end
        format = CsvVisits.csv_format(clean.empty? ? [] : clean[0].keys)
        raise ImportError.new("This CSV is not an Umami export or Runlight's visit format", "import_csv_format") if format.nil?

        cutoff = runlight.retention_cutoff(site_id) || 0
        own = runlight.store.first_own_visit(site_id)
        finish = [own.nil? ? Float::INFINITY : own, runlight.now].min
        hits = []
        clean.each do |row|
          h = CsvVisits.csv_hit(row, format)
          next unless !h.nil? && h["hit"]["ts"] >= cutoff && h["hit"]["ts"] < finish

          h["hit"]["ts"] = h["hit"]["ts"].to_i
          hits << h
        end
        hits = hits.each_with_index.sort_by { |h, i| [h["hit"]["ts"], i] }.map(&:first)
        skipped = clean.length - hits.length
        return { "pageviews" => 0, "events" => 0, "visits" => 0, "skipped" => skipped } if hits.empty?

        counts = write_step(runlight, site_id, hits[0]["hit"]["ts"], hits[-1]["hit"]["ts"] + 1, hits)
        counts.merge("skipped" => skipped)
      end

      private_class_method :progress_key, :all, :write_step, :referrer_of, :from_umami, :write_event
    end
  end
end
