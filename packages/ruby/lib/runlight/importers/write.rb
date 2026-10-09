# frozen_string_literal: true

module Runlight
  module Importers
    # Writing an imported link and its history, and the names other tools use, in Runlight's spelling.
    module Write
      # Domains run by the shorteners themselves. Links there stay on Runlight's own path.
      SHORTENER_DOMAINS = %w[bit.ly bitly.com j.mp dub.sh dub.co dub.link short.gy rebrand.ly rebrandly.com rb.gy].freeze
      private_constant :SHORTENER_DOMAINS

      # Browser and system names as other tools write them, in Runlight's spelling.
      BROWSERS = {
        "chrome" => "Chrome", "crios" => "Chrome", "chromium-webview" => "Android WebView", "chrome webview" => "Android WebView", "safari" => "Safari",
        "ios" => "Safari", "ios-webview" => "Safari", "mobile safari" => "Safari", "firefox" => "Firefox", "fxios" => "Firefox", "edge" => "Edge",
        "edge-chromium" => "Edge", "edge-ios" => "Edge", "microsoft edge" => "Edge", "opera" => "Opera", "opera-mini" => "Opera",
        "samsung" => "Samsung Internet", "samsung internet" => "Samsung Internet", "yandexbrowser" => "Yandex Browser",
        "facebook" => "Facebook", "instagram" => "Instagram", "brave" => "Brave", "duckduckgo" => "DuckDuckGo",
      }.freeze
      SYSTEMS = {
        "mac os" => "macOS", "mac os x" => "macOS", "macos" => "macOS", "ios" => "iOS", "android os" => "Android", "android" => "Android",
        "windows 10" => "Windows", "windows 11" => "Windows", "windows 7" => "Windows", "windows" => "Windows", "linux" => "Linux",
        "chrome os" => "Chrome OS", "chromium os" => "Chrome OS",
      }.freeze
      DEVICES = { "desktop" => "desktop", "laptop" => "desktop", "mobile" => "mobile", "smartphone" => "mobile", "phone" => "mobile", "tablet" => "tablet" }.freeze

      module_function

      def hex_id(value, length = 24)
        Hashing.sha256(value)[0, length]
      end

      # The Runlight id an imported link gets, from its source and its id there.
      def imported_link_id(source, source_id)
        hex_id("#{source}:#{source_id}")
      end

      # Two destinations are the same link when they differ only by a trailing slash.
      def same_url(a, b)
        a.sub(%r{/\z}, "") == b.sub(%r{/\z}, "")
      end

      # The first letter in upper case, as TS's title() does.
      def title(v)
        v == "" ? "" : Js.upper(Js.slice(v, 0, 1)) + Js.slice(v, 1)
      end

      # A browser name in Runlight's spelling: a known one, or the name with a capital first letter.
      def browser(name)
        BROWSERS[Js.lower(name)] || title(name)
      end

      # A system name in Runlight's spelling, or the name as given.
      def system_name(name)
        SYSTEMS[Js.lower(name)] || name
      end

      def device(name)
        DEVICES[Js.lower(name)] || ""
      end

      # A field of a foreign click as text, "" where it is missing, as `c.field || ""` reads it.
      def str(c, key)
        value = c[key]
        Js.truthy?(value) ? Js.string(value) : ""
      end

      # A field of a foreign click as String(c.field ?? "").
      def text(c, key)
        value = c[key]
        Js.string(value.nil? ? "" : value)
      end

      # Writes one link and its history in a single transaction: the link (and its
      # branded domain), then each click as a visit like a live one, or daily
      # counts as clicks without visitors. Ids come from the source's own ids, so
      # importing again skips what is already there.
      #
      # foreign: { "sourceId", "slug", "domain", "name", "url", "createdAt" }; history: { "clicks"?, "daily"? }.
      # Returns { "status", "clicks", "reason"?, "code"?, "params"? }.
      def write_link(runlight, site, source, foreign, history)
        source_id = Js.string(foreign["sourceId"])
        id = imported_link_id(source, source_id)
        return { "status" => "skipped", "clicks" => 0 } unless runlight.store.link_by_id(id).nil?

        slug = foreign["slug"].to_s
        taken = runlight.store.link_by_slug(slug)
        # The same slug to the same place is this link, brought in earlier some other way.
        return { "status" => "skipped", "clicks" => 0 } if !taken.nil? && same_url(taken["url"], foreign["url"].to_s)

        unless taken.nil?
          return { "status" => "failed", "clicks" => 0, "reason" => "/#{slug} is already used by \"#{taken["name"]}\"", "code" => "import_slug_taken",
                   "params" => { "slug" => slug, "name" => taken["name"] } }
        end
        unless slug.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]{0,99}\z/)
          return { "status" => "failed", "clicks" => 0, "reason" => "/#{slug} has characters Runlight slugs cannot use", "code" => "import_slug_bad",
                   "params" => { "slug" => slug } }
        end

        domain = Sources.strip_www(Js.truthy?(foreign["domain"]) ? foreign["domain"].to_s : "")
        domain = "" if SHORTENER_DOMAINS.include?(domain)
        now = runlight.now
        clicks = 0
        # Nothing in the transaction is one link's own problem (those are checked above),
        # so a failure in it is the database's, and it stops the import rather than marking the link.
        runlight.store.transaction do |store|
          # On a database without transactions (D1), a failed earlier try can have left
          # some of this link's clicks behind. Clear them, then write the link row last,
          # so a link only counts as imported once all of its history is in.
          store.db.run("DELETE FROM rl_sessions WHERE id IN (SELECT DISTINCT session FROM rl_events WHERE link = ? AND session <> '')", [id])
          store.db.run("DELETE FROM rl_events WHERE link = ?", [id])

          made = {}
          (history["clicks"] || []).each do |c|
            ts = c["ts"]
            next unless ts.is_a?(Integer) || (ts.is_a?(Float) && ts.finite?)

            ts = ts.to_i
            visit_key = !c["visit"].nil? ? Js.string(c["visit"]) : "#{ts}:#{clicks}"
            session = hex_id("#{source}:#{source_id}:#{visit_key}")
            # A visitor id lasts one day at most, as every other visitor id does.
            visitor = hex_id("#{source}:#{visit_key}:#{Client.iso_string(ts)[0, 10]}", 16)
            path = str(c, "path")
            unless made[session]
              made[session] = true
              store.db.run("DELETE FROM rl_sessions WHERE id = ?", [session])
              host = domain.empty? ? "link.invalid" : domain
              query = str(c, "query")
              url = Http::Url.parse("https://#{host}#{path.empty? ? "/#{slug}" : path}#{query.empty? ? "" : "?#{query.sub(/\A\?/, "")}"}") ||
                    Http::Url.new("https://#{host}/#{slug}")
              page = Sources.parse_page(url)
              country = Js.slice(Js.upper(str(c, "country")), 0, 2)
              raw_region = str(c, "region")
              region = raw_region.empty? ? "" : Js.slice(Js.upper(raw_region.include?("-") ? raw_region : "#{country}-#{raw_region}"), 0, 10)
              store.insert_session(
                {
                  "id" => session,
                  "site" => site,
                  "visitor" => visitor,
                  "startedAt" => ts,
                  "hostname" => page["hostname"],
                }.merge(Sources.attribute(page, text(c, "referrer"), [])).merge(
                  "utmSource" => page["utm"]["source"],
                  "utmMedium" => page["utm"]["medium"],
                  "utmCampaign" => page["utm"]["campaign"],
                  "utmTerm" => page["utm"]["term"],
                  "utmContent" => page["utm"]["content"],
                  "country" => country.match?(/\A[A-Z]{2}\z/) ? country : "",
                  "region" => country.empty? ? "" : region,
                  "city" => Js.slice(str(c, "city"), 0, 100),
                  "browser" => browser(str(c, "browser")),
                  "browserVersion" => "",
                  "os" => SYSTEMS[Js.lower(str(c, "os"))] || text(c, "os"),
                  "osVersion" => "",
                  "device" => device(str(c, "device")),
                  "screen" => text(c, "screen"),
                  "language" => text(c, "language"),
                ),
              )
              store.db.run("UPDATE rl_sessions SET imported = 1 WHERE id = ?", [session])
            end
            click_path = path.empty? ? "/#{slug}" : path
            store.touch_session(session, ts, "click", click_path)
            store.insert_event({
              "site" => site, "ts" => ts, "kind" => "click", "visitor" => visitor, "session" => session, "pageview" => "",
              "path" => Js.slice(click_path, 0, 1000), "hostname" => domain, "title" => "", "name" => slug, "props" => nil, "engagedMs" => 0,
              "scroll" => nil, "link" => id,
            })
            clicks += 1
          end

          # Counts without detail: clicks spread through each day, with no visitor or visit.
          (history["daily"] || []).each do |d|
            start = Client.parse_date("#{d["day"]}T00:00:00Z")
            next if (start.is_a?(Float) && !start.finite?) || !(d["clicks"].is_a?(Numeric) && d["clicks"].positive?)

            n = [d["clicks"], 1_000_000].min
            i = 0
            while i < n
              store.insert_event({
                "site" => site, "ts" => start.to_i + ((i + 0.5) / n * 86_400_000).floor, "kind" => "click", "visitor" => "", "session" => "",
                "pageview" => "", "path" => "/#{slug}", "hostname" => domain, "title" => "", "name" => slug, "props" => { "imported" => "daily" },
                "engagedMs" => 0, "scroll" => nil, "link" => id,
              })
              clicks += 1
              i += 1
            end
          end
          store.add_link_domain(domain, site, now) unless domain.empty?
          name = Js.truthy?(foreign["name"]) ? foreign["name"].to_s : slug
          created = Js.truthy?(foreign["createdAt"]) ? foreign["createdAt"].to_i : now
          store.insert_link({
            "id" => id,
            "site" => site,
            "domain" => domain,
            "slug" => slug,
            "name" => Js.slice(name, 0, 100),
            "url" => foreign["url"],
            "createdAt" => created,
            "updatedAt" => created,
          })
        end
        runlight.forget_link_domains unless domain.empty?
        { "status" => "created", "clicks" => clicks }
      end

      private_class_method :str, :text
    end
  end
end
