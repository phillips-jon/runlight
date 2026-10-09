# frozen_string_literal: true

require "fileutils"
require "stringio"

module Runlight
  module Server
    # The standalone server: Runlight's routes at the root of their own domain, behind a sign-in, with sites managed
    # in the dashboard and short links answered on any domain pointed at it. This is the port of
    # packages/server/src/server.ts. Config builds one from the environment or a config.rb, and it is a Rack app:
    # config.ru runs `Runlight::Server::Standalone.app` under any Rack server, and `runlight serve` runs the same
    # app with Puma, or WEBrick when Puma is not installed.
    #
    # The names the owner and admins signed in from are kept in the database, so every process serving the same
    # database knows them, and the scheduled check runs every five minutes in the server itself, or from cron
    # (`runlight cron`).
    class Standalone
      # The server's own pages, which answer as the server on every name it is reached at, a link domain too.
      SERVER_PATHS = ["/login", "/logout", "/setup", "/invite", "/healthz", "/auth.css", "/auth.js", "/api", "/mcp",
                      "/s.js", "/pick.js", "/e"].freeze

      # The most names remembered as the server's own. The first ones stay and later ones are not learned, so
      # a server reached at more names than this needs RUNLIGHT_URL to keep the rest from becoming link domains.
      MAX_OWN_HOSTS = 20

      # The collect endpoint's limit; its payloads are under 8 KB.
      MAX_COLLECT_BODY = 16 * 1024

      # Everything else, such as a link import of 5,000 rows.
      MAX_BODY = 10 * 1024 * 1024

      # How often the server runs the scheduled check, in seconds.
      EVERY = 5 * 60

      TOO_LARGE = Json.encode({ "error" => "That request is too large" })
      private_constant :TOO_LARGE

      attr_reader :runlight, :accounts, :web, :routes

      # The standalone server from the environment and config.rb in root (the working folder by default), as a Rack
      # app. With schedule, the scheduled check (salts, email reports, retention, and rollups) and this month's
      # location data run now and every five minutes in a thread of their own, as the Node server runs them.
      def self.app(root = Dir.pwd, file = nil, schedule: true)
        config = Config.new(root, file)
        server = config.standalone
        server.runlight.init
        server.schedule(config) if schedule
        server
      end

      # options (String keys, as Config passes them, or symbols in snake_case):
      # - store: the SqlStore
      # - secret: signs sessions and encrypts saved keys. Keep it stable.
      # - token: also accepted as a bearer token on the API, for scripts. When there is no setupCode, the first
      #   account is made with it instead.
      # - url: the dashboard's public address, such as https://stats.example.com. It can never become a link
      #   domain, short links never answer on it, and emails link to it whatever Host header a request carries.
      # - trustProxy, geo, geoCredit, now, fetcher: as the Core's and the routes' options of those names.
      # - setupCode: the one-time code that unlocks /setup while no account exists; setupWhere says where it is
      #   written down, for the page that asks for it.
      # - cronSecret: a bearer secret for POST /api/check, for a scheduler that calls it over HTTP.
      # - observeKey: one key for every site's AI agent reports.
      def initialize(options)
        options = Options.normalize(options)
        @store = options["store"]
        now = options["now"] || -> { Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond) }
        @now = now
        @token = options["token"].nil? || options["token"] == "" ? nil : options["token"].to_s
        @trust_proxy = options["trustProxy"].nil? ? true : options["trustProxy"]
        @public_url = options["url"].nil? || options["url"] == "" ? nil : Http::Url.new(options["url"].to_s)
        @public_host = @public_url.nil? ? nil : Routes.host_name(@public_url.host)
        @own_hosts = nil
        @schedule = nil

        core = {
          "store" => @store,
          "managedSites" => true,
          "secret" => options["secret"],
          "trustProxy" => @trust_proxy,
          "now" => now,
        }
        core["geo"] = options["geo"] unless options["geo"].nil?
        core["fetcher"] = options["fetcher"] unless options["fetcher"].nil?
        @runlight = rl = Core.new(core)

        # Accounts, shared with apps that turn them on. The first one is made with the one-time code, or with the
        # token when there is no code, and emails link to the public address, or else the first name the owner or
        # an admin signed in from.
        code = options["setupCode"]
        first = if !code.nil? && code != "" then { "code" => code }
                elsif !@token.nil? then { "token" => @token }
                else "locked"
                end
        web = {
          "runlight" => rl,
          "secret" => options["secret"],
          "base" => "",
          "now" => now,
          "firstAccount" => first,
          "home" => -> { @public_url&.origin || (known_hosts[0].nil? ? nil : "https://#{known_hosts[0]}") },
          "forgot" => "https://runlight.sh/docs/ruby/#forgotten-passwords",
        }
        web["setupWhere"] = options["setupWhere"] unless options["setupWhere"].nil?
        @web = Accounts::Web.new(web)
        @accounts = @web.accounts

        cron_secret = options["cronSecret"]
        routes = {
          "basePath" => "",
          # Without a secret of its own, the cron route is never needed: the server runs the check itself.
          "cronSecret" => cron_secret.nil? || cron_secret == "" ? Hashing.random_id(32) : cron_secret.to_s,
          "observeKey" => options["observeKey"].to_s,
          "signOut" => "/logout",
          "signIn" => "/login",
          "geoCredit" => options["geoCredit"] ? true : false,
          "accounts" => @web,
          "authorize" => lambda do |request|
            auth = request.headers.get("authorization") || ""
            if !@token.nil? && auth.downcase.start_with?("bearer ") && Accounts::Crypto.same_text(Js.trim(auth[7..]), @token)
              next true
            end

            access = @web.access(request)
            learn_host(request) if access == true
            access
          end,
          "ownHosts" => -> { known_hosts },
        }
        routes["origin"] = @public_url.origin unless @public_url.nil?
        @routes = rl.routes(routes)
      end

      # The answer to one request. context: { "ip" => the client's address }.
      def handle(request, context = {})
        path = Http::Url.new(request.url).pathname
        begin
          # A domain pointed at this server for short links answers at its root, with links one segment deep. The
          # server's own pages and its public address never answer as links, and "/" stays the dashboard for someone
          # signed in, so a link domain added on the dashboard's own name can always be removed again.
          linkable = path == Core::LINK_DOMAIN_CHECK ||
                     (path.match?(%r{\A/[^/]*\z}) && !SERVER_PATHS.include?(path) &&
                      !(path == "/" && !@web.signed_in(request).nil?))
          if linkable && !(!@public_host.nil? && host_of(request) == @public_host)
            linked = @runlight.link_domain_response(request, context)
            return linked unless linked.nil?
          end
          if path == "/healthz"
            return Http::Response.new("ok", status: 200, headers: { "content-type" => "text/plain", "cache-control" => "no-store" })
          end
          if request.method == "GET" && path.match?(%r{\A/go/[^/]+/?\z})
            return @runlight.link_handler.call(request, context)
          end

          # Everything else, the sign-in pages and People included, is the routes'.
          @routes.handle(request, context)
        rescue StandardError => e
          warn "Runlight: #{e.message}"
          Routes.coded("Internal error", "internal", 500)
        end
      end

      # The Rack entry point: answers the request, then does the work left after answering (a retention change's
      # deletions) once the server has sent the answer. Bodies past the limits the Node server keeps get a 413, and
      # X-Forwarded-Proto names the scheme, as the Node server reads them.
      def call(env)
        limit = "#{env["SCRIPT_NAME"]}#{env["PATH_INFO"]}".end_with?("/e") ? MAX_COLLECT_BODY : MAX_BODY
        method = env["REQUEST_METHOD"].to_s.upcase
        unless %w[GET HEAD].include?(method)
          text = read_body(env, limit)
          return [413, { "content-type" => "application/json" }, [TOO_LARGE]] if text.nil?

          env["rack.input"] = StringIO.new(text)
        end
        request = Http::Request.from_rack(env)
        proto = request.headers.get("x-forwarded-proto").to_s.split(",")[0].to_s.strip.downcase
        if %w[http https].include?(proto) && !request.url.start_with?("#{proto}://")
          request = request.with(url: request.url.sub(%r{\Ahttps?://}, "#{proto}://"))
        end
        status, headers, body = handle(request, { "ip" => request.remote_address }).to_rack
        body = [] if method == "HEAD"
        [status, headers, Finished.new(body, -> { idle })]
      end

      # Starts the scheduled work in a thread of its own: now, then every five minutes. A run that starts while
      # another process (`runlight cron`, or another worker) is still going leaves it to that one.
      def schedule(config, every = EVERY)
        @schedule ||= Thread.new do
          Thread.current.name = "runlight-schedule"
          loop do
            tick(config)
            sleep(every)
          end
        end
      end

      # Stops the schedule, for a server shutting down.
      def stop
        @schedule&.kill
        @schedule = nil
      end

      # The scheduled work: salts, email reports that are due, retention, and rollups.
      def check
        result = @runlight.check
        @runlight.idle
        result
      end

      private

      # One run of the schedule, as `runlight cron` runs it, with whatever goes wrong said and left for next time.
      def tick(config)
        lock = begin
          File.open("#{config.data_dir}/cron.lock", File::RDWR | File::CREAT, 0o600)
        rescue SystemCallError
          nil
        end
        begin
          if lock.nil? || lock.flock(File::LOCK_EX | File::LOCK_NB)
            begin
              check
              # The setup link is no use once someone has an account.
              FileUtils.rm_f(config.setup_file) if File.file?(config.setup_file) && @accounts.count.positive?
            rescue StandardError => e
              warn "Runlight: the scheduled check failed: #{e.message}"
            end
            begin
              config.db_ip&.refresh(@now.call)
            rescue StandardError => e
              warn "Runlight: could not refresh location data: #{e.message}"
            end
          end
        ensure
          lock&.close
        end
        # Another process may have downloaded the release this one reads.
        config.db_ip&.load_newest
      rescue StandardError => e
        warn "Runlight: the scheduled check failed: #{e.message}"
      end

      def idle
        @runlight.idle
      rescue StandardError => e
        warn "Runlight: #{e.message}"
      end

      # The request body, read up to the limit, or nil past it.
      def read_body(env, limit)
        length = env["CONTENT_LENGTH"].to_s
        return nil if length.match?(/\A\d+\z/) && length.to_i > limit

        input = env["rack.input"]
        return "".b if input.nil?

        input.rewind if input.respond_to?(:rewind)
        body = "".b
        while (chunk = input.read(64 * 1024))
          body << chunk
          return nil if body.bytesize > limit
        end
        body
      end

      # The name a request came in on, read as link domains read it.
      def host_of(request)
        forwarded = @trust_proxy == false ? nil : request.headers.get("x-forwarded-host")
        Routes.host_name(forwarded || request.headers.get("host") || Http::Url.new(request.url).host)
      end

      def saved_hosts
        @runlight.init
        begin
          saved = Json.decode(@store.setting("server-hosts") || "[]")
        rescue StandardError
          return []
        end
        saved.is_a?(Array) ? saved.grep(String) : []
      end

      # The names the owner and admins signed in from, kept in the database, so a link domain can never be one of
      # them even when whoever adds it picks another Host header.
      def known_hosts
        @own_hosts ||= saved_hosts
      end

      # Only the owner and admins teach the server its names, since anyone else could fill the list with made-up
      # ones, and only real domain names. Names that are already link domains are left out.
      def learn_host(request)
        host = host_of(request)
        known = known_hosts
        return if !host.match?(Routes::DOMAIN_NAME) || known.include?(host) || known.length >= MAX_OWN_HOSTS
        return if @store.link_domains.any? { |domain| domain["domain"] == host }

        known = known.dup
        # Another process may have saved names since this one read them.
        saved_hosts.each { |saved| known << saved unless known.include?(saved) }
        known << host
        @own_hosts = known.first(MAX_OWN_HOSTS)
        @store.set_setting("server-hosts", Json.encode(@own_hosts))
      end

      # A Rack body that runs a block once the server has sent it and closes it.
      class Finished
        def initialize(body, after)
          @body = body
          @after = after
        end

        def each(&block)
          @body.each(&block)
        end

        def close
          @body.close if @body.respond_to?(:close)
        ensure
          @after.call
        end
      end
      private_constant :Finished
    end
  end
end
