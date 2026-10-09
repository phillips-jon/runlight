# frozen_string_literal: true

module Runlight
  # Runlight in an app: the sites it counts, the tracker endpoint's work, short links, email reports, and the
  # scheduled upkeep. A port of the TypeScript SDK's runlight.ts; `Runlight.new(options)` makes one.
  #
  # Options, with the TS names (or their snake_case symbols, so `rate_limit: 60` is `"rateLimit" => 60`):
  # - store: a Store::SqlStore (required), such as Runlight::Stores.sqlite("db/runlight.sqlite3").
  # - site: { id:, name:, hostnames:, timezone: }, the site this install counts. Ignored when `sites` is given.
  #   `id` is a stable id, stored with every row, default "default". `hostnames` are the hostnames that belong
  #   to the site, without www; with one site, empty means any hostname, and with several, each site needs at
  #   least one. `timezone` is an IANA timezone for reports, such as "Europe/London", default "UTC".
  # - sites: several sites in one install, told apart by hostname.
  # - managedSites: sites are added, changed, and deleted in the dashboard and kept in the database, as the
  #   standalone server does. `site` and `sites` are ignored.
  # - geo: a callable taking an IP and giving { "country", "region", "city" } or nil, a location for an IP when
  #   the platform sends no location headers.
  # - trustProxy: true (default), false, or one of "x-forwarded-for", "x-real-ip", "cf-connecting-ip". Read the
  #   client IP from forwarding headers: the last X-Forwarded-For entry, which the nearest proxy wrote, then
  #   X-Real-IP, then CF-Connecting-IP. Name one of them to read only that header, such as "cf-connecting-ip"
  #   behind Cloudflare and another proxy. False reads only the connection's address, for an app nothing sits
  #   in front of.
  # - linkPath: where short links on the app's own domain live, as `{linkPath}/{slug}`. Default "/go".
  # - mail: the mail service for email reports, in code (a Transports config plus `from` and `fromName`).
  #   When set, the dashboard shows it and cannot change it. Otherwise it is set up in Settings.
  # - secret: encrypts the keys kept in the database: the mail service's, the AI Assistant's, and the tokens
  #   for connected installs. Default the RUNLIGHT_SECRET environment variable, then RUNLIGHT_TOKEN.
  # - rateLimit: tracker requests allowed per visitor address per minute. Default 120, which a real visitor
  #   never reaches; false turns the limit off.
  # - now: a callable giving the clock in milliseconds. For tests.
  # - fetcher: what every outgoing request goes through (anything with fetch(url, init)). Default
  #   Http::NetFetcher.
  #
  # TS runs some work after answering or on timers. Here the retention a settings change asks for runs in
  # idle(), which an adapter calls once the answer is sent, and everything else in check().
  class Core
    # A path on every link domain that answers when the domain reaches this Runlight.
    LINK_DOMAIN_CHECK = "/.well-known/runlight-link-domain"

    # The choices for how long a site keeps its visits.
    RETENTION_MONTHS = [6, 12, 24, 36, 60].freeze

    # Thirty minutes without a request ends a session.
    SESSION_IDLE_MS = 30 * 60 * 1000

    # What passes for an email address: something@somewhere.tld, with no spaces, quotes, or angle brackets.
    EMAIL = /\A[^#{Js::SPACE}@<>"]+@[^#{Js::SPACE}@<>"]+\.[^#{Js::SPACE}@<>"]+\z/

    # Raised whenever what a rolled-up day holds changes. 2: the heatmap counts visits only. 3: a page counts the views that can report time.
    ROLLUP_VERSION = 3
    # Days of rollups built per site in one scheduled check, and how long after a day ends it is built.
    ROLLUP_BATCH = 10
    # The most a connected install's list of sites may weigh; a real one is a few kilobytes.
    REMOTE_MAX_BYTES = 2 * 1024 * 1024
    # On a database that caps statements per request (Cloudflare D1), fewer days a check, about 30 statements.
    METERED_ROLLUP_BATCH = 4
    ROLLUP_DELAY_MS = 2 * 3_600_000
    private_constant :ROLLUP_VERSION, :ROLLUP_BATCH, :REMOTE_MAX_BYTES, :METERED_ROLLUP_BATCH, :ROLLUP_DELAY_MS

    BUSY = /timeout exceeded when trying to connect|connection timeout|no MySQL connection was free|SQLITE_BUSY|database is locked/i
    private_constant :BUSY

    attr_reader :store,
                # Whether sites are managed in the dashboard.
                :managed_sites,
                # Short links: create, change, delete, and import.
                :links,
                # Where links on the app's own domain are served, such as "/go".
                :link_path,
                # Encrypts the keys kept in the database; nil leaves them readable, and the dashboard says so.
                :secret,
                # Every outgoing request goes through it.
                :fetcher

    # Where routes() serves the dashboard and API, which a link domain leaves alone, as a list without
    # repeats. Middleware often runs apart from the routes, where none were made, so the default "/runlight"
    # stands in there.
    attr_accessor :route_bases

    def initialize(options = {})
      options = Options.normalize(options, deep: %w[site sites mail])
      unless options["store"].is_a?(Store::SqlStore)
        raise ArgumentError, "Runlight: pass a store, such as Runlight::Stores.sqlite(\"db/runlight.sqlite3\")"
      end

      @store = options["store"]
      @managed_sites = Js.truthy?(options["managedSites"])
      sites = options["sites"]
      sites = sites.values if sites.is_a?(Hash)
      configured = if @managed_sites then []
                   elsif sites.is_a?(Array) && !sites.empty? then sites
                   else [options["site"] || {}]
                   end
      @configured = configured.each_with_index.map { |site, index| site_row(site, index) }
      if @configured.length > 1 && @configured.any? { |site| site["hostnames"].empty? }
        raise ArgumentError, "Runlight: with several sites, give each one its hostnames"
      end
      if @configured.map { |site| site["id"] }.uniq.length != @configured.length
        raise ArgumentError, "Runlight: two sites share an id"
      end

      @geo = options["geo"]
      @trust_proxy = options["trustProxy"].nil? ? true : options["trustProxy"]
      per_minute = options["rateLimit"].nil? ? 120 : options["rateLimit"]
      # false, 0, or anything that is not a positive number means no limit, never a limit of nothing.
      number = per_minute == false ? Float::NAN : Js.number(per_minute)
      @limit = if number.is_a?(Numeric) && number.positive?
                 RateLimit.new(number.infinite? ? (2**63) - 1 : number.floor, -> { now })
               end
      @clock = options["now"] || -> { Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond) }
      @fetcher = options["fetcher"] || Http::NetFetcher.new
      @links = Links.new(self)
      @link_path = "/#{(options["linkPath"].nil? ? "/go" : options["linkPath"]).to_s.gsub(%r{\A/+|/+\z}, "")}"
      @mail_in_code = options["mail"]
      @secret = if options.key?("secret") && !options["secret"].nil?
                  options["secret"].to_s
                else
                  Env.get("RUNLIGHT_SECRET") || Env.get("RUNLIGHT_TOKEN")
                end
      @route_bases = []
      # Sites counted by another Runlight install, read through its API with the token it gave, read or manage.
      @remotes = {}
      @remote_seen = {}
      @overrides = {}
      @ready = false
      @checking = false
      # When planner statistics were last gathered.
      @optimized_at = 0
      @link_domain_cache = nil
      # Each timezone's salts for its current day, so a lookup is a map read until midnight there.
      @salts = {}
      # Retention work asked for and not yet done: a site's id, or nil for every site.
      @pruning = []
      # Work to do once the answer is sent, such as an email whose timing must not show in the answer.
      @later = []
    end

    def managed_sites?
      @managed_sites
    end

    # The clock, in milliseconds.
    def now
      @clock.call.to_i
    end

    # The mail service: from code, or as saved in the dashboard. Nil when there is none.
    def mail_settings
      return @mail_in_code.merge("source" => "code") unless @mail_in_code.nil?

      init
      sealed = @store.setting("mail")
      return nil if sealed.nil? || sealed == ""

      opened = Mail::Secret.unseal(sealed, @secret)
      return nil if opened.nil? || opened == ""

      Json.decode(opened).merge("source" => "dashboard")
    end

    # Saves the mail service from the dashboard. A secret field left blank
    # keeps the saved value, so the browser never needs to see it.
    def save_mail_settings(input)
      raise Mail::MailError.new("The mail service is set in code", "mail_in_code", {}) unless @mail_in_code.nil?

      if input.nil?
        @store.set_setting("mail", nil)
        return
      end
      before = mail_settings || {}
      service = Mail::Transports::SERVICES.find { |s| s["id"] == input["service"] }
      raise Mail::MailError.new("Pick a mail service", "mail_service", {}) if service.nil?

      settings = { "service" => service["id"] }
      service["fields"].each do |f|
        settings[f["name"]] = Js.trim(Js.string(input[f["name"]].nil? ? "" : input[f["name"]])) unless Js.truthy?(f["secret"])
      end
      # A blank secret keeps the saved one only while the connection is the same,
      # so changing the host cannot send a saved password somewhere new.
      same_connection = before["service"] == service["id"]
      if same_connection
        same_connection = service["fields"].none? do |f|
          !Js.truthy?(f["secret"]) && Js.string(before[f["name"]].nil? ? "" : before[f["name"]]) != settings[f["name"]]
        end
      end
      service["fields"].each do |f|
        next unless Js.truthy?(f["secret"])

        given = Js.trim(Js.string(input[f["name"]].nil? ? "" : input[f["name"]]))
        settings[f["name"]] = if given == "" && same_connection
                                Js.string(before[f["name"]].nil? ? "" : before[f["name"]])
                              else
                                given
                              end
      end
      from = Js.trim(Js.string(input["from"].nil? ? "" : input["from"]))
      unless from.match?(EMAIL)
        raise Mail::MailError.new("Enter the address reports come from, like reports@example.com", "mail_from", {})
      end

      from_name = Js.slice(Js.trim(Js.string(input["fromName"].nil? ? "" : input["fromName"])), 0, 80)
      config = settings.merge("from" => from)
      config["fromName"] = from_name unless from_name == ""
      Mail::Transports.check_config(config)
      @store.set_setting("mail", Mail::Secret.seal(Json.encode(config), @secret))
    end

    # Sends one email through the mail service: { "to", "subject", "html", "text", "headers" (optional) }.
    def send_mail(message)
      settings = mail_settings
      raise Mail::MailError.new("Set up a mail service first", "mail_unset", {}) if settings.nil?

      full = message.merge("from" => settings["from"])
      full["fromName"] = settings["fromName"] unless settings["fromName"].nil?
      Mail::Transports.deliver(settings, full, @fetcher, now)
    end

    # Sends every report that is due: last week's on Monday from 8am, last
    # month's on the 1st, in each site's timezone. Safe to run often; each
    # period goes out once. Called by check().
    def send_reports
      init
      result = { "sent" => 0, "failed" => 0 }
      reports = @store.reports
      return result if reports.empty? || mail_settings.nil?

      at = now
      reports.each do |r|
        site = site(r["site"])
        next if site.nil?

        period = Reports.last_period(r["frequency"], at, site["timezone"])
        next if at < period["dueAt"] || r["lastPeriod"] == period["key"]
        next unless @store.claim_report(r["id"], period["key"], at)

        begin
          deliver_report(r, site, period)
          result["sent"] += 1
        rescue StandardError => e
          @store.release_report(r["id"], period["key"], r["lastPeriod"])
          warn("Runlight: could not send the #{r["frequency"]} report for #{site["name"]} to #{r["email"]}: #{e.message}")
          result["failed"] += 1
        end
      end
      result
    end

    # Builds and sends one report. Also used by "Send a sample now".
    def deliver_report(r, site, period = nil)
      period ||= Reports.last_period(r["frequency"], now, site["timezone"])
      unsubscribe = "#{r["origin"]}/unsubscribe/#{r["token"]}"
      report = Reports.build_report(self, site, r["frequency"], period, r["lang"], {
        "dashboard" => "#{r["origin"]}/?site=#{Js.encode_uri_component(site["id"])}",
        "unsubscribe" => unsubscribe,
      })
      send_mail({
        "to" => r["email"],
        "subject" => report["subject"],
        "html" => report["html"],
        "text" => report["text"],
        "headers" => { "List-Unsubscribe" => "<#{unsubscribe}>", "List-Unsubscribe-Post" => "List-Unsubscribe=One-Click" },
      })
    end

    # Creates tables and records the configured sites. Runs once.
    def init
      return if @ready

      @store.migrate
      # A database that never had its statistics gathered gets them now, before any report is read, rather
      # than at the first scheduled check, which an app may never run.
      @store.optimize(true)
      if @managed_sites
        @configured = @store.sites
        load_remotes
      end
      @configured.each { |site| @store.upsert_site(site, now) }
      @overrides = @store.site_overrides
      # A process starting with a timezone set in code is the newest word on it: if the code changed it,
      # the days built in the old one are cleared here, once, and never by a process still running.
      sites.each do |site|
        next if @remotes.key?(site["id"])

        stored = @store.setting("rollup-zone:#{site["id"]}")
        zone = stored.nil? || stored == "" ? nil : Json.decode(stored)["zone"]
        if zone.nil?
          @store.set_setting("rollup-zone:#{site["id"]}", Json.encode({ "zone" => site["timezone"], "since" => 0 }))
        elsif zone != site["timezone"]
          zone_changed(site["id"], site["timezone"])
        end
      end
      @ready = true
    end

    # The dashboard and API. Routes is the port of routes.ts.
    def routes(options = {})
      Routes.new(self, Options.normalize(options))
    end

    # Runlight as a Rack app: link domains, `{linkPath}/{slug}`, and the dashboard and API under the routes'
    # base path, with idle() run once each answer is sent. The options are the routes' options:
    # `run RL.rack_app(base_path: "/runlight")`.
    def rack_app(options = {})
      RackApp.new(nil, runlight: self, **options)
    end

    # The sites, with any settings changed in the dashboard applied.
    def sites
      @configured.map { |site| site.merge(@overrides[site["id"]] || {}) }
    end

    # The install a site is read from, when it is counted elsewhere:
    # { "url", "token", "site", "hostnames", "scope" (optional) }, or nil.
    def remote(id)
      @remotes[id]
    end

    # When a connected install's site last had a visit, asked at most once a minute.
    def remote_last_seen(id)
      remote_info(id)&.[]("lastSeen")
    end

    # What a connected install says about its site: its last visit and how long it keeps visits, asked
    # at most once a minute. Retention is UNDEFINED while the install cannot be reached, and `connection`
    # says whether it answered ("ok"), refused this server's token ("refused"), or could not be reached
    # ("unreachable").
    def remote_info(id)
      remote = @remotes[id]
      return nil if remote.nil?

      cached = @remote_seen[id]
      return cached.except("at") if !cached.nil? && now - cached["at"] < 60_000

      info = { "lastSeen" => cached&.[]("lastSeen"), "retentionMonths" => UNDEFINED, "connection" => "unreachable" }
      begin
        answer = @fetcher.fetch("#{remote["url"]}/api/sites", {
          "headers" => { "authorization" => "Bearer #{remote["token"]}" }, "timeoutMs" => 8000, "maxBytes" => REMOTE_MAX_BYTES,
        })
        info["connection"] = "refused" if answer.status == 401 || answer.status == 403
        body = json_or_nil(answer)
        listed = body.is_a?(Hash) && body["sites"].is_a?(Array) ? body["sites"] : []
        listed.each do |s|
          unless s.is_a?(Hash)
            # TS reads `s.id` of each and stops at a null, as a throw would.
            break if s.nil?

            next
          end
          next unless s.key?("id") && s["id"] == remote["site"]

          info = { "lastSeen" => s["lastSeen"], "retentionMonths" => s["retentionMonths"], "connection" => "ok" }
          break
        end
      rescue StandardError
        nil
      end
      @remote_seen[id] = { "at" => now }.merge(info)
      info
    end

    # Forgets what a connected install said, after a change made through it.
    def forget_remote_info(id)
      @remote_seen.delete(id)
    end

    # Adds a site, when sites are managed in the dashboard: one counted here, or one connected from another
    # install. Input: { "name", "hostnames", "timezone", "remote" }.
    def add_site(input)
      input = Options.normalize(input)
      init
      raise SettingsError.new("Sites are set in code", "sites_in_code") unless @managed_sites

      remote = input["remote"]
      remote = remote.each_with_index.to_h { |value, i| [i.to_s, value] } if remote.is_a?(Array)
      if remote.is_a?(Hash)
        remote = Options.normalize(remote).except("name")
        remote["name"] = input["name"] if input.key?("name")
        return add_remote_site(remote)
      end
      hostnames = hostnames_for(input["hostnames"])
      name = Js.trim(Js.string(input["name"].nil? ? "" : input["name"]))
      name = hostnames[0] if name == ""
      raise SettingsError.new("A site name is 1 to 80 characters", "site_name") if Js.length(name) > 80

      timezone = Js.string(input["timezone"].nil? ? "UTC" : input["timezone"])
      unless Dates.timezone?(timezone)
        raise SettingsError.new("Unknown timezone \"#{timezone}\"", "unknown_timezone", { "timezone" => timezone })
      end

      stem = hostnames[0].gsub(/[^a-z0-9._-]/, "-")[0, 56]
      id = stem
      n = 2
      while site?(id)
        id = "#{stem}-#{n}"
        n += 1
      end
      site = { "id" => id, "name" => name, "hostnames" => hostnames, "timezone" => timezone }
      @store.upsert_site(site, now)
      @configured = by_name(@configured + [site])
      site
    end

    # Deletes a site and everything recorded for it, when sites are managed in the dashboard.
    def delete_site(id)
      init
      raise SettingsError.new("Sites are set in code", "sites_in_code") unless @managed_sites
      raise SettingsError.new("Unknown site", "unknown_site") unless site?(id)

      @store.delete_site(id)
      @store.set_setting("retention:#{id}", nil)
      @store.set_setting("observe-key:#{id}", nil)
      @store.set_setting("rollup-zone:#{id}", nil)
      @store.set_setting("orphans-swept:#{id}", nil)
      # A site made again with the same id starts its Umami import from the beginning.
      @store.settings_starting_with("import:umami-visits:#{id}:").each { |row| @store.set_setting(row["key"], nil) }
      # A connected install keeps its own data; only the connection goes, and its token there with it.
      remote = @remotes[id]
      unless remote.nil?
        revoke_remote_token(remote)
        @remotes.delete(id)
        @store.set_setting("remote:#{id}", nil)
      end
      @configured = @configured.reject { |site| site["id"] == id }
      @overrides.delete(id)
      nil
    end

    # Changes a site's name or timezone from the dashboard. Stored apart from
    # the settings in code, which keep being written on every start. A managed
    # site has no settings in code, so its changes, hostnames too, go to its row.
    # A key left out of `patch` is left alone, as TS's undefined is.
    def update_site(id, patch)
      patch = Options.normalize(patch)
      init
      current = @configured.reverse.find { |site| site["id"] == id }
      raise SettingsError.new("Unknown site", "unknown_site") if current.nil?

      nxt = (@managed_sites ? current : (@overrides[id] || {})).dup
      if given?(patch, "name")
        name = Js.trim(Js.string(patch["name"]))
        raise SettingsError.new("A site name is 1 to 80 characters", "site_name") if name == "" || Js.length(name) > 80

        nxt["name"] = name
      end
      if given?(patch, "timezone")
        timezone = Js.string(patch["timezone"])
        unless Dates.timezone?(timezone)
          raise SettingsError.new("Unknown timezone \"#{timezone}\"", "unknown_timezone", { "timezone" => timezone })
        end

        nxt["timezone"] = timezone
        zone_changed(id, timezone) if timezone != site(id)&.[]("timezone")
      end
      if @managed_sites
        nxt["hostnames"] = hostnames_for(patch["hostnames"], id) if given?(patch, "hostnames") && !@remotes.key?(id)
        @store.upsert_site(nxt, now)
        @configured = @configured.map { |site| site["id"] == id ? nxt : site }
        return site(id)
      end
      @store.set_site_overrides(id, nxt)
      @overrides[id] = nxt
      site(id)
    end

    # How many months of visits a site keeps, or nil to keep everything (the default).
    def retention(site)
      value = Js.number(@store.setting("retention:#{site}"))
      value.is_a?(Integer) && RETENTION_MONTHS.include?(value) ? value : nil
    end

    # Sets how many months of visits a site keeps. Deleting a long history takes a while, so it runs in
    # pieces in idle(), after the answer, with tracking going on between them, as TS runs it after answering.
    def set_retention(site, months)
      raise SettingsError.new("Unknown site", "unknown_site") if site(site).nil? || @remotes.key?(site)

      unless months.nil? || (months.is_a?(Numeric) && RETENTION_MONTHS.include?(months))
        list = RETENTION_MONTHS.join(", ")
        raise SettingsError.new("Keep visits for #{list} months, or forever", "retention_bad", { "months" => list })
      end

      @store.set_setting("retention:#{site}", months.nil? ? nil : Json.number(months))
      @pruning << site
      nil
    end

    # Queues work for idle, so it runs after the answer is sent, as TypeScript leaves a promise running.
    def later(&work)
      @later << work
      nil
    end

    # Runs the work still waiting from earlier calls (later work and a retention change's deletions); the
    # scheduled check and tests wait for it.
    def idle
      until @later.empty?
        work = @later.shift
        begin
          work.call
        rescue StandardError => e
          warn("Runlight: #{e.message}")
        end
      end
      until @pruning.empty?
        only = @pruning.shift
        begin
          apply_retention(only)
        rescue StandardError => e
          warn("Runlight: could not apply retention #{e.message}")
        end
      end
    end

    # Adds up each site's finished days, so long ranges read a row a day instead
    # of every visit. A day is built two hours after it ends in the site's
    # timezone, once late engagement has landed, and at most ROLLUP_BATCH days
    # a run, so a long history fills in over a few runs. Reports read the raw
    # visits for any day not built yet, so the numbers are the same either way.
    # Only a visit still going two hours past midnight, with no 30 minute gap,
    # could add to a day after it is built.
    def build_rollups
      # Days rolled up by an earlier way of counting are cleared once, and built again below.
      if @store.setting("rollup-version") != ROLLUP_VERSION.to_s
        sites.each { |site| @store.clear_rollups(site["id"]) }
        @store.set_setting("rollup-version", ROLLUP_VERSION.to_s)
      end
      built = 0
      at = now
      db = @store.db
      batch = db.respond_to?(:metered?) && db.metered? ? METERED_ROLLUP_BATCH : ROLLUP_BATCH
      sites.each do |site|
        next if @remotes.key?(site["id"])

        first = @store.first_seen(site["id"])
        next if first.nil?

        cutoff = retention_cutoff(site["id"]) || 0
        since = rollup_since(site)
        next if since.nil?

        done = @store.rollup_days(site["id"]).to_h { |day| [day.to_s, true] }
        today = Dates.local_date(at, site["timezone"])
        oldest = Dates.local_date([first, cutoff].max.to_i, site["timezone"])
        made = 0
        # Newest first, so recent ranges speed up before a long history is done.
        day = Dates.add_days(today, -1)
        while day >= oldest && made < batch
          unless done.key?(day)
            start = Dates.start_of(day, site["timezone"])
            finish = Dates.start_of(Dates.add_days(day, 1), site["timezone"])
            break if start < since

            unless at < finish + ROLLUP_DELAY_MS || start < cutoff
              begin
                @store.build_rollup_day(site["id"], day, start, finish)
                made += 1
              rescue StandardError => e
                # Another process building the same day at once loses nothing: the day is there either way.
                unless @store.rollup_days(site["id"]).map(&:to_s).include?(day)
                  warn("Runlight: could not add up #{day} for #{site["id"]} #{e.message}")
                end
              end
            end
          end
          day = Dates.add_days(day, -1)
        end
        built += made
      end
      built
    end

    # The dashboard assistant's provider, model, and key, kept sealed like the mail keys. Nil until an owner
    # sets it up.
    def assistant_settings
      stored = @store.setting("assistant")
      opened = stored.nil? || stored == "" ? nil : Mail::Secret.unseal(stored, @secret)
      opened.nil? || opened == "" ? nil : Json.decode(opened)
    end

    # Saves the assistant's settings; an empty key keeps the one saved for the same provider. Nil removes them.
    def save_assistant_settings(input)
      if input.nil? || input == false
        @store.set_setting("assistant", nil)
        return
      end
      input = Options.normalize(input)
      provider = Assistant::PROVIDERS.find { |p| p["id"] == input["provider"] }
      raise SettingsError.new("Choose a provider", "assistant_provider") if provider.nil?

      base_url = Js.trim(Js.string(input["baseUrl"].nil? ? "" : input["baseUrl"])).sub(%r{/+\z}, "")
      if base_url != ""
        parsed = Http::Url.parse(base_url)
        if parsed.nil? || (parsed.protocol != "https:" && parsed.protocol != "http:")
          raise SettingsError.new("Enter the service's address, starting with https://", "assistant_address_bad")
        end
      end
      raise SettingsError.new("Enter the service's address", "assistant_address") if base_url == "" && provider["baseUrl"] == ""

      model = Js.slice(Js.trim(Js.string(input["model"].nil? ? "" : input["model"])), 0, 200)
      raise SettingsError.new("Enter the model to use", "assistant_model") if model == "" && provider["model"] == ""

      before = assistant_settings || {}
      key = Js.trim(Js.string(input["key"].nil? ? "" : input["key"]))
      # A saved key is kept only for the same service at the same address, so it is never sent somewhere new.
      before_base = before["baseUrl"].to_s
      if key == "" && before["provider"] == provider["id"] &&
         (before_base == "" ? provider["baseUrl"] : before_base) == (base_url == "" ? provider["baseUrl"] : base_url)
        key = before["key"].to_s
      end
      if key == "" && provider["key"] == "yes"
        raise SettingsError.new("Enter your #{provider["name"]} key", "assistant_key", { "provider" => provider["name"] })
      end

      settings = { "provider" => provider["id"], "model" => model, "baseUrl" => base_url, "key" => key }
      @store.set_setting("assistant", Mail::Secret.seal(Json.encode(settings), @secret))
      nil
    end

    # The oldest moment a site keeps visits from, or nil when it keeps everything.
    def retention_cutoff(site)
      months = retention(site)
      return nil if months.nil?

      # setUTCMonth: the same day and time that many months back, a day past the month's end running on.
      at = now
      ms = at % 1000
      time = Time.at((at - ms) / 1000).utc
      total = (time.year * 12) + (time.month - 1) - months
      first = Time.utc(total.div(12), (total % 12) + 1, 1, time.hour, time.min, time.sec)
      ((first.to_i + ((time.day - 1) * 86_400)) * 1000) + ms
    end

    def site(id = nil)
      all = sites
      return all[0] if id.nil? || id == ""

      all.find { |site| site["id"] == id }
    end

    # The site a page belongs to, or nil if it belongs to none.
    def site_for(hostname, id = nil)
      host = Sources.strip_www(hostname)
      # A site counted by another install never takes hits here.
      unless @remotes.empty?
        local = sites.reject { |site| @remotes.key?(site["id"]) }
        return @remotes.key?(id) ? nil : site_for_among(local, host, id) if !id.nil? && id != ""

        return site_for_among(local, host)
      end
      site_for_among(sites, host, id)
    end

    # The visitor's address, for the daily visitor hash and the rate limit. Behind a proxy it comes
    # from a header. By default that is the last X-Forwarded-For entry, which the nearest proxy wrote
    # and a client cannot choose (Vercel, Netlify, Cloudflare, Caddy, and nginx all append there),
    # then X-Real-IP and CF-Connecting-IP. Naming one header (after another proxy in front, such as
    # Cloudflare before nginx) reads only that one. Otherwise it is the connection's address: the
    # context's "ip", or else the request's own remote_address.
    def client_ip(request, context = {})
      if @trust_proxy != false
        h = request.headers
        last = lambda do |name|
          value = h.get(name)
          next nil if value.nil?

          parts = value.split(",", -1).map { |x| Js.trim(x) }.reject(&:empty?)
          parts.empty? ? nil : parts[-1]
        end
        forwarded = if @trust_proxy == true
                      last.call("x-forwarded-for") || h.get("x-real-ip") || h.get("cf-connecting-ip")
                    elsif @trust_proxy == "x-forwarded-for"
                      last.call("x-forwarded-for")
                    else
                      h.get(@trust_proxy.to_s)
                    end
        return Js.trim(forwarded) if !forwarded.nil? && Js.trim(forwarded) != ""
      end
      ip = context_ip(context)
      (ip.nil? ? request.remote_address : ip).to_s
    end

    # Handles one tracker request. Bad input is dropped quietly; only a database that keeps failing raises.
    def collect(request, context = {})
      length = Js.number(request.headers.get("content-length") || 0)
      return if length > Payload::MAX_BODY

      # Read no more than a tracker hit can be, whatever the length header says (or when there is none).
      bytes = request.text
      return if bytes.bytesize > Payload::MAX_BODY

      payload = Payload.parse_payload(Body.utf8(bytes))
      return if payload.nil?

      ua = request.headers.get("user-agent") || ""
      return if !Ua.ai_agent(ua).nil? || Ua.bot?(ua)
      return if !@limit.nil? && !@limit.allow(client_ip(request, context))

      # A database too busy to take the hit right now (every pooled connection held by long reports, or
      # another process writing the SQLite file) gets it a little later, at the time it arrived.
      at = now
      attempt = 1
      begin
        record(payload, request, context, at)
      rescue StandardError => e
        raise if attempt >= 3 || !busy?(e)

        sleep(0.5 * attempt)
        attempt += 1
        retry
      end
      nil
    end

    # Clears the cached link domains after one is added or removed.
    def forget_link_domains
      @link_domain_cache = nil
    end

    # Handles `{linkPath}/{slug}` on the app's own domain: a callable taking a Request (and a context) and
    # giving a Response. In a Rack app:
    # `return core.link_handler.call(request).to_rack if path.start_with?("/go/")`.
    def link_handler
      lambda do |request, context = {}|
        path = Http::Url.new(request.url).pathname
        slug = path.start_with?("#{@link_path}/") ? decode(path[(@link_path.length + 1)..]) : ""
        found = slug != "" && !slug.include?("/") ? redirect(request, slug, "", context) : nil
        found || not_found
      end
    end

    # For middleware: when a request arrives on a link domain added in
    # Settings (such as t.example.com), answers `/{slug}` there with the
    # redirect, and anything else with a 404. Nil for every other host, so
    # the app carries on as normal, and for the dashboard's own paths, so
    # its owner can always reach it to remove the domain.
    def link_domain_response(request, context = {})
      url = Http::Url.new(request.url)
      # A forwarded host only counts behind a proxy that sets it; otherwise any client could pick one.
      given = forwarded_host(request) || request.headers.get("host") || url.host
      host = Sources.strip_www(Js.trim(given.split(",", -1).first.to_s).split(":", -1).first.to_s)
      return nil unless link_domain_set.key?(host)

      # Lets the dashboard confirm that requests to this domain reach Runlight.
      if url.pathname == LINK_DOMAIN_CHECK
        return Http::Response.new(Json.encode({ "runlight" => true, "domain" => host }), status: 200,
                                                                                       headers: { "content-type" => "application/json", "cache-control" => "no-store" })
      end

      (@route_bases.empty? ? ["/runlight"] : @route_bases).each do |base|
        return nil if base != "/" && (url.pathname == base || url.pathname.start_with?("#{base}/"))
      end
      slug = decode(url.pathname[1..].to_s)
      found = slug != "" && !slug.include?("/") ? redirect(request, slug, host, context) : nil
      found || not_found
    end

    # Answers a request for a short link: a redirect to its destination, with
    # the click recorded like a visit (source, place, device, and any campaign
    # tags on the short URL) but kept out of visitor and pageview counts.
    # Bots are redirected and not counted. `domain` is the link domain the
    # request came in on, or "" for the app's own link path, which answers for
    # every link. Nil when no link fits.
    def redirect(request, slug, domain, context = {})
      init
      url = Http::Url.new(request.url)
      host = Sources.strip_www((forwarded_host(request) || request.headers.get("host") || url.host).split(":", -1).first.to_s)
      link = @store.link_by_slug(slug)
      # The app's own link path answers for every link, so a link whose domain
      # was removed keeps working; a link domain answers only for its own links.
      return nil if link.nil? || (domain != "" && link["domain"] != domain)

      site = site(link["site"]) || sites[0]
      ua = request.headers.get("user-agent") || ""
      if !site.nil? && Ua.ai_agent(ua).nil? && !Ua.bot?(ua) && request.method == "GET"
        begin
          at = now
          first = (request.headers.get("accept-language") || "").split(",", -1).first.to_s.split(";", -1).first.to_s
          language = Js.slice(Js.trim(first), 0, 35)
          session = session_for(site, request, context, Sources.parse_page(url), request.headers.get("referer") || "", at,
                                { "screen" => "", "language" => language })
          @store.touch_session(session["id"], at, "click", url.pathname)
          @store.insert_event({
            "site" => site["id"],
            "ts" => at,
            "kind" => "click",
            "visitor" => session["visitor"],
            "session" => session["id"],
            "pageview" => "",
            "path" => Js.slice(url.pathname, 0, 1000),
            "hostname" => host,
            "title" => "",
            "name" => link["slug"],
            "props" => nil,
            "engagedMs" => 0,
            "scroll" => nil,
            "link" => link["id"],
          })
        rescue StandardError => e
          # A failed count must never break the redirect.
          warn("Runlight: could not record a link click #{e.message}")
        end
      end
      Http::Response.new("", status: 302, headers: {
        "location" => link["url"], "cache-control" => "no-store", "referrer-policy" => "no-referrer-when-downgrade",
      })
    end

    # Records a request from a known AI agent. Call it from middleware for
    # every page request; it ignores everything else and never raises.
    # Agents do not run JavaScript, so the tracker cannot see them.
    def observe(request, at = nil)
      return false if request.method != "GET"

      agent = Ua.ai_agent(request.headers.get("user-agent") || "")
      return false if agent.nil?

      url = Http::Url.new(request.url)
      # Pages, not their assets.
      extension = url.pathname.match(/\.([a-z0-9]+)\z/i)
      return false if extension && !%w[html htm md txt php].include?(extension[1].downcase)

      host = forwarded_host(request) || request.headers.get("host") || url.hostname
      init
      site = site_for(host.split(":", -1).first.to_s)
      return false if site.nil?

      # A log reader sends when the page was served. Older than a week is dropped, so a first run over
      # an old log does not land as one spike on today; a time ahead of now counts as now.
      current = now
      finite = at.is_a?(Numeric) && at.to_f.finite?
      return false if finite && at < current - (7 * 86_400_000)

      ts = finite && at <= current ? at.floor : current
      @store.insert_event({
        "site" => site["id"],
        "ts" => ts,
        "kind" => "fetch",
        "visitor" => "",
        "session" => "",
        "pageview" => "",
        "path" => Js.slice(url.pathname, 0, 1000),
        "hostname" => Sources.strip_www(url.hostname),
        "title" => "",
        "name" => agent["name"],
        "props" => { "company" => agent["company"], "kind" => agent["kind"] },
        "engagedMs" => 0,
        "scroll" => nil,
        "link" => "",
      })
      true
    rescue StandardError => e
      # Analytics must never break the page it watches, but a failure should still be seen.
      warn("Runlight: could not record an AI agent fetch #{e.message}")
      false
    end

    # Scheduled upkeep, safe to run every minute. It rotates salts, sends the email
    # reports that are due, deletes visits past each site's retention, and builds
    # daily rollups. It also rereads sites, their dashboard settings, and connected
    # installs, so a change made by another process sharing the database shows up here too.
    # A check called while one is running (from inside it) does nothing more.
    def check
      return { "ok" => true, "reports" => { "sent" => 0, "failed" => 0 } } if @checking

      @checking = true
      begin
        run_check
      ensure
        @checking = false
      end
    end

    private

    def site_row(options, index)
      options = Options.normalize(options)
      timezone = options["timezone"].nil? ? "UTC" : options["timezone"]
      raise ArgumentError, "Runlight: unknown timezone \"#{timezone}\"" unless timezone.is_a?(String) && Dates.timezone?(timezone)

      id = options["id"].nil? ? (index.zero? ? "default" : "") : options["id"]
      unless id.is_a?(String) && id.match?(/\A[a-z0-9][a-z0-9._-]{0,63}\z/i)
        raise ArgumentError, "Runlight: site id \"#{id}\" must be letters, digits, dots, dashes, or underscores"
      end

      hostnames = options["hostnames"].nil? ? [] : options["hostnames"].to_a
      {
        "id" => id,
        "name" => options["name"].nil? ? (hostnames[0].nil? ? "My site" : hostnames[0]) : options["name"],
        "hostnames" => hostnames.map { |h| Sources.strip_www(h.to_s) },
        "timezone" => timezone,
      }
    end

    # Sites in name order, as TS sorts them with localeCompare: letters before case, as a collator puts them.
    def by_name(sites)
      sites.each_with_index.sort do |(a, i), (b, j)|
        order = Js.lower(a["name"]) <=> Js.lower(b["name"])
        order = Js.compare(b["name"], a["name"]) if order.zero?
        order.zero? ? i <=> j : order
      end.map(&:first)
    end

    def site_for_among(sites, host, id = nil)
      if !id.nil? && id != ""
        site = sites.find { |s| s["id"] == id }
        return nil if site.nil?

        return site["hostnames"].empty? || site["hostnames"].include?(host) ? site : nil
      end
      if sites.length == 1
        only = sites[0]
        return only["hostnames"].empty? || only["hostnames"].include?(host) ? only : nil
      end
      sites.find { |site| site["hostnames"].include?(host) }
    end

    def not_found
      Http::Response.new("Not found", status: 404, headers: { "content-type" => "text/plain; charset=utf-8" })
    end

    # decodeURIComponent, raising where it throws a URIError.
    def decode(text)
      Js.decode_uri_component(text) || raise(ArgumentError, "URI malformed")
    end

    # True for a database that could not take a statement just now and may a moment later.
    def busy?(error)
      error.message.match?(BUSY)
    end

    # Whether a patch gives a key, as TS reads `patch.key !== undefined`.
    def given?(patch, key)
      patch.key?(key) && !patch[key].equal?(UNDEFINED)
    end

    def context_ip(context)
      return nil unless context.is_a?(Hash)

      context.key?("ip") ? context["ip"] : context[:ip]
    end

    # Checks a list of hostnames for a managed site: at least one, each a domain, none taken.
    def hostnames_for(input, except = nil)
      items = input.is_a?(Array) ? input : Js.string(input.nil? ? "" : input).split(/[#{Js::SPACE},]+/)
      hostnames = []
      items.each do |h|
        host = Js.trim(Js.string(h))
        host = host.sub(%r{\Ahttps?://}, "")
        host = host.sub(%r{[/:][^\n\r  ]*\z}, "")
        host = Sources.strip_www(host)
        hostnames << host if host != "" && !hostnames.include?(host)
      end
      raise SettingsError.new("Add the site's domain, like example.com", "site_domain_needed") if hostnames.empty?

      hostnames.each do |host|
        if !host.match?(/\A(?=.{1,253}\z)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z/) && host != "localhost"
          raise SettingsError.new("\"#{host}\" is not a domain name", "site_domain_invalid", { "host" => host })
        end

        @configured.each do |site|
          next unless site["id"] != except && site["hostnames"].include?(host)

          raise SettingsError.new("#{host} already belongs to #{site["name"]}", "site_domain_taken",
                                  { "host" => host, "site" => site["name"] })
        end
      end
      hostnames
    end

    def load_remotes
      @remotes = {}
      @store.settings_starting_with("remote:").each do |row|
        opened = Mail::Secret.unseal(row["value"], @secret)
        @remotes[row["key"].delete_prefix("remote:")] = Json.decode(opened) unless opened.nil? || opened == ""
      end
    end

    # A capped JSON body, or nil where TS's readJsonCapped(...).catch(() => null) gives null.
    def json_or_nil(answer)
      Body.read_json_capped(answer, REMOTE_MAX_BYTES)
    rescue StandardError
      nil
    end

    # Asks a connected install to delete the token this server holds for it. A failure leaves it listed there.
    def revoke_remote_token(remote)
      @fetcher.fetch("#{remote["url"]}/api/token", {
        "method" => "DELETE", "headers" => { "authorization" => "Bearer #{remote["token"]}" }, "timeoutMs" => 5_000,
      })
    rescue StandardError
      nil
    end

    # Connects a site counted by another Runlight (an app's own install) so this
    # server shows it too. Takes the install's address, as its dashboard is
    # (https://example.com/runlight), and an API token made there.
    def add_remote_site(input)
      url = Js.trim(Js.string(input["url"].nil? ? "" : input["url"])).sub(%r{/+\z}, "")
      unless url.match?(%r{\Ahttps://[^/]+|\Ahttp://(localhost|127\.0\.0\.1)(:\d+)?(/|\z)})
        raise SettingsError.new("Enter the install's address, like https://example.com/runlight", "connect_url")
      end

      token = Js.trim(Js.string(input["token"].nil? ? "" : input["token"]))
      raise SettingsError.new("Enter an API token from that install", "install_token") if token == ""

      begin
        answer = @fetcher.fetch("#{url}/api/sites", {
          "headers" => { "authorization" => "Bearer #{token}" }, "timeoutMs" => 10_000, "maxBytes" => REMOTE_MAX_BYTES,
        })
      rescue Http::BodyTooLong
        # An answer too long to read is no Runlight's.
        raise SettingsError.new("#{url} did not answer like a Runlight install", "connect_not_runlight", { "url" => url })
      rescue StandardError
        raise SettingsError.new("Could not reach #{url}", "unreachable", { "host" => Http::Url.new(url).host })
      end
      raise SettingsError.new("That install refused the token", "install_refused") if answer.status == 401 || answer.status == 403

      body = json_or_nil(answer)
      listed = body.is_a?(Hash) && body["sites"].is_a?(Array) ? body["sites"] : []
      if !answer.ok? || listed.empty?
        raise SettingsError.new("#{url} did not answer like a Runlight install", "connect_not_runlight", { "url" => url })
      end

      # What the token may do there; an install from before manage tokens has no /api/token and reads only.
      scope = "read"
      token_site = ""
      begin
        about = @fetcher.fetch("#{url}/api/token", {
          "headers" => { "authorization" => "Bearer #{token}" }, "timeoutMs" => 10_000, "maxBytes" => REMOTE_MAX_BYTES,
        })
        info = about.ok? ? json_or_nil(about) : nil
        scope = "manage" if info.is_a?(Hash) && info["scope"] == "manage"
        token_site = Js.string(info.is_a?(Hash) && !info["site"].nil? ? info["site"] : "")
      rescue StandardError
        nil
      end
      want = if token_site != "" then token_site
             elsif input.key?("site") then input["site"]
             else UNDEFINED
             end
      there = listed.find do |s|
        next false unless s.is_a?(Hash)

        id = s.key?("id") ? s["id"] : UNDEFINED
        id.equal?(UNDEFINED) || want.equal?(UNDEFINED) ? id.equal?(want) : id == want
      end
      there ||= listed[0]
      field = ->(key) { there.is_a?(Hash) ? there[key] : nil }
      there_hostnames = field.call("hostnames").is_a?(Array) ? field.call("hostnames").grep(String) : []
      # Connecting the same site again (to allow changes, or with a new token) updates it in place.
      @remotes.each do |existing, known|
        next unless known["url"] == url && known["site"] == field.call("id")

        updated = known.merge("token" => token, "scope" => scope, "hostnames" => there_hostnames)
        revoke_remote_token(known) if known["token"] != token
        @store.set_setting("remote:#{existing}", Mail::Secret.seal(Json.encode(updated), @secret))
        @remotes[existing.to_s] = updated
        @remote_seen.delete(existing)
        return site(existing.to_s)
      end
      # As TS's replace without the u flag, a character outside the BMP is two units, so two dashes.
      host = Js.lower((there_hostnames[0] || Http::Url.new(url).host).to_s.gsub(/[^a-z0-9._-]/i) { |c| c.ord > 0xFFFF ? "--" : "-" })
      id = Js.slice(host, 0, 56)
      n = 2
      while site?(id)
        id = "#{Js.slice(host, 0, 56)}-#{n}"
        n += 1
      end
      name = Js.slice(Js.trim(Js.string(input["name"].nil? ? "" : input["name"])), 0, 80)
      name = Js.string(field.call("name").nil? ? UNDEFINED : field.call("name")) if name == ""
      # No hostnames: tracker hits never land on a site that is counted elsewhere.
      timezone = field.call("timezone")
      site = { "id" => id, "name" => name, "hostnames" => [],
               "timezone" => timezone.is_a?(String) && Dates.timezone?(timezone) ? timezone : "UTC" }
      remote = { "url" => url, "token" => token, "site" => field.call("id"), "hostnames" => there_hostnames, "scope" => scope }
      @store.upsert_site(site, now)
      @store.set_setting("remote:#{id}", Mail::Secret.seal(Json.encode(remote), @secret))
      @remotes[id] = remote
      @configured = by_name(@configured + [site])
      site
    end

    def site?(id)
      @configured.any? { |site| site["id"] == id }
    end

    # Days are the site's local days, so a new timezone clears the built ones. Visitor ids recorded before
    # the change were made per day of the old timezone, and could count one person twice in a new day, so
    # only days that start after the change are built; earlier ones are always counted visit by visit.
    def zone_changed(id, timezone)
      since = now
      @store.clear_rollups(id)
      @store.set_setting("rollup-zone:#{id}", Json.encode({ "zone" => timezone, "since" => since }))
      since
    end

    # Since when a site's days may be built: 0 for always, or when its timezone last changed. Nil when
    # this process holds a different timezone than the one on record, such as an older copy still running
    # during a deploy, or one that has not yet seen a change made in the dashboard. It builds nothing for
    # that site, and reports read the visits themselves for any day not built, so nothing is wrong meanwhile.
    def rollup_since(site)
      stored = @store.setting("rollup-zone:#{site["id"]}")
      if stored.nil? || stored == ""
        @store.set_setting("rollup-zone:#{site["id"]}", Json.encode({ "zone" => site["timezone"], "since" => 0 }))
        return 0
      end
      zone = Json.decode(stored)
      zone["zone"] == site["timezone"] ? zone["since"] : nil
    end

    # Deletes visits older than each site's retention allows. Cheap when there is nothing to delete.
    def apply_retention(only = nil)
      sites.each do |site|
        next if (!only.nil? && only != "" && site["id"] != only) || @remotes.key?(site["id"])

        cutoff = retention_cutoff(site["id"])
        next if cutoff.nil?

        @store.drop_before(site["id"], cutoff)
        # Earlier versions let an event join its visit days late, so retention could leave such an event behind
        # once its visit was gone. They are swept once; events can no longer join a visit that late.
        unless Js.truthy?(@store.setting("orphans-swept:#{site["id"]}"))
          @store.drop_orphans(site["id"], cutoff, now)
          @store.set_setting("orphans-swept:#{site["id"]}", "1")
        end
      end
    end

    # A test from a developer's own machine while a site is being set up. A site
    # with no visits yet accepts hits from localhost and .local or .test names,
    # so the install screen confirms it works; after its first visit they are
    # ignored again, so local browsing never mixes with real traffic.
    def setup_site(hostname, id = nil)
      host = Js.lower(hostname).gsub(/\A\[|\]\z/, "")
      return nil unless %w[localhost 127.0.0.1 ::1].include?(host) || host.match?(/\.(localhost|local|test)\z/)

      all = sites
      site = !id.nil? && id != "" ? site(id) : (all.length == 1 ? all[0] : nil)
      return nil if site.nil? || @remotes.key?(site["id"])

      @store.last_seen(site["id"]).nil? ? site : nil
    end

    # Today's salt in a site's timezone and, if it still exists, yesterday's.
    # Salts follow the site's own days, as its reports do, so a visitor is one
    # visitor for the whole of that site's day. Old salts go on the way.
    def current_salts(at, timezone)
      day = Dates.local_date(at, timezone)
      cached = @salts[timezone]
      return cached if !cached.nil? && cached["day"] == day

      today = @store.salt(day, Hashing.random_salt)
      yesterday = @store.salt_if_exists(Dates.add_days(day, -1))
      drop_old_salts(at)
      @salts[timezone] = { "day" => day, "today" => today, "yesterday" => yesterday }
    end

    # Deletes salts whose day has ended everywhere. The earliest timezone is a
    # day behind UTC and still needs its yesterday, so a salt goes two UTC days
    # after its date.
    def drop_old_salts(at)
      @store.drop_salts_before(Time.at((at - (2 * 86_400_000)).div(1000)).utc.strftime("%Y-%m-%d"))
    end

    # The host a proxy says the request was for, read only when proxy headers are trusted, as the client's address is.
    def forwarded_host(request)
      @trust_proxy == false ? nil : request.headers.get("x-forwarded-host")
    end

    def record(payload, request, context, at)
      # Managed sites load from the database in init(), so it must come first.
      init
      url = payload["url"]
      site = site_for(url.hostname, payload["site"]) || setup_site(url.hostname, payload["site"])
      return if site.nil?

      if payload["kind"] == "engagement"
        engagement(site, payload, at)
        return
      end

      page = Sources.parse_page(url)
      session = nil
      reopen = true
      if payload["kind"] == "event" && payload["pageviewId"] != ""
        pageview = @store.pageview(site["id"], payload["pageviewId"])
        # An event joins its page's visit unless that visit began longer ago than reports look for its rows
        # (a tab left open for days); it then starts a visit of its own, as any later activity would.
        if !pageview.nil? && at - pageview["startedAt"] < Store::SqlStore::EVENT_TAIL_MS
          session = { "id" => pageview["session"], "visitor" => pageview["visitor"] }
          # A visit idle past the 30 minutes stays ended: the event counts in it without reopening it.
          reopen = at - pageview["lastAt"] <= SESSION_IDLE_MS
          if at - pageview["startedAt"] > 3_600_000
            @store.touched_old_visit(site["id"], pageview["startedAt"].to_i, at - ROLLUP_DELAY_MS + 3_600_000)
          end
        end
      end
      screen = if Js.truthy?(payload["screenWidth"]) && Js.truthy?(payload["screenHeight"])
                 "#{Js.string(payload["screenWidth"])}x#{Js.string(payload["screenHeight"])}"
               else
                 ""
               end
      session ||= session_for(site, request, context, page, payload["referrer"], at, {
        "screenWidth" => payload["screenWidth"], "screen" => screen, "language" => payload["language"],
      })

      @store.touch_session(session["id"], at, payload["kind"], page["path"], reopen)
      @store.insert_event({
        "site" => site["id"],
        "ts" => at,
        "kind" => payload["kind"],
        "visitor" => session["visitor"],
        "session" => session["id"],
        "pageview" => payload["pageviewId"],
        "path" => page["path"],
        "hostname" => page["hostname"],
        "title" => payload["kind"] == "pageview" ? payload["title"] : "",
        "name" => payload["kind"] == "event" ? payload["name"] : "",
        "props" => payload["props"],
        "engagedMs" => 0,
        "scroll" => nil,
        "link" => "",
      })
    end

    # The visitor's open session on a site, or a new one attributed to this
    # request. Shared by tracker hits and short link clicks.
    #
    # TS takes turns per visitor here, so one process's pageview and the event right after it find one
    # session; a Ruby process serves each request on one thread, and a visitor's hits come one after another.
    def session_for(site, request, context, page, referrer, at, client)
      ua = request.headers.get("user-agent") || ""
      ip = client_ip(request, context)
      salts = current_salts(at, site["timezone"])
      today = Hashing.visitor_hash(salts["today"], site["id"], ip, ua)
      candidates = [today]
      candidates << Hashing.visitor_hash(salts["yesterday"], site["id"], ip, ua) unless salts["yesterday"].nil? || salts["yesterday"] == ""
      open = @store.open_session(site["id"], candidates, at - SESSION_IDLE_MS)
      return open unless open.nil?

      session = { "id" => Hashing.random_id, "visitor" => today }
      attribution = Sources.attribute(page, referrer, site["hostnames"])
      parsed = Ua.parse_client(ua, {
        "brands" => request.headers.get("sec-ch-ua"),
        "mobile" => request.headers.get("sec-ch-ua-mobile"),
        "platform" => request.headers.get("sec-ch-ua-platform"),
      }, client["screenWidth"])
      location = Geo.locate(request.headers, ip, @geo)
      row = {
        "id" => session["id"],
        "site" => site["id"],
        "visitor" => session["visitor"],
        "startedAt" => at,
        "hostname" => page["hostname"],
      }.merge(attribution).merge(
        "utmSource" => page["utm"]["source"],
        "utmMedium" => page["utm"]["medium"],
        "utmCampaign" => page["utm"]["campaign"],
        "utmTerm" => page["utm"]["term"],
        "utmContent" => page["utm"]["content"],
      ).merge(location).merge(parsed).merge("screen" => client["screen"], "language" => client["language"])
      @store.insert_session(row)
      session
    end

    # The link domains, read at most every 30 seconds. Every request to a
    # standalone server asks, so this saves a query on each tracker hit; a
    # change made here clears it at once, one made by another process within
    # half a minute.
    def link_domain_set
      at = now
      return @link_domain_cache["domains"] if !@link_domain_cache.nil? && at - @link_domain_cache["at"] < 30_000

      init
      domains = @store.link_domains.to_h { |d| [d["domain"], true] }
      @link_domain_cache = { "at" => at, "domains" => domains }
      domains
    end

    def engagement(site, payload, at)
      return if payload["engagedMs"] <= 0

      pageview = @store.pageview(site["id"], payload["pageviewId"])
      # Reports look for a visit's rows only so long after it began, so later time on it is let go.
      return if pageview.nil? || at - pageview["startedAt"] >= Store::SqlStore::EVENT_TAIL_MS

      @store.add_engagement(pageview["session"], payload["engagedMs"])
      # Only a visit that began more than an hour ago can belong to a day that is already added up.
      if at - pageview["startedAt"] > 3_600_000
        @store.touched_old_visit(site["id"], pageview["startedAt"].to_i, at - ROLLUP_DELAY_MS + 3_600_000)
      end
      @store.insert_event({
        "site" => site["id"],
        "ts" => at,
        "kind" => "engagement",
        "visitor" => pageview["visitor"],
        "session" => pageview["session"],
        "pageview" => payload["pageviewId"],
        "path" => pageview["path"],
        "hostname" => pageview["hostname"],
        "title" => "",
        "name" => "",
        "props" => nil,
        "engagedMs" => payload["engagedMs"],
        "scroll" => payload["scroll"],
        "link" => "",
      })
    end

    def run_check
      init
      # Requests take a current schema version on trust; the scheduled check goes over every table and index.
      @store.migrate(true)
      if @managed_sites
        @configured = @store.sites
        load_remotes
      end
      # A name or timezone changed in the dashboard by another process reaches this one too.
      @overrides = @store.site_overrides
      @salts = {}
      sites.map { |site| site["timezone"] }.uniq.each { |timezone| current_salts(now, timezone) }
      drop_old_salts(now)
      # Every site's retention covers any one site's that is still waiting.
      @pruning = []
      begin
        apply_retention
      rescue StandardError => e
        warn("Runlight: could not apply retention #{e.message}")
      end
      if now - @optimized_at >= 86_400_000
        @optimized_at = now
        @store.optimize
      end
      build_rollups
      { "ok" => true, "reports" => send_reports }
    end
  end
end
