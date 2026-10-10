# frozen_string_literal: true

require "openssl"

module Runlight
  # The dashboard, its API, the tracker, the MCP server, and OAuth, under one base path, as routes.ts serves them.
  #
  # Options (the TypeScript names as String keys, read with key? where absence means something):
  # - basePath: where the routes are mounted. Default "/runlight".
  # - token: required to read stats. Send it as `Authorization: Bearer <token>`, or open the dashboard once with
  #   `?token=<token>` and a cookie is set. Absent means RUNLIGHT_TOKEN. Without one, the dashboard and API are
  #   open only when NODE_ENV is "development", and answer 503 everywhere else. Pass nil to leave them open
  #   everywhere, for example behind your own auth middleware.
  # - authorize: a callable taking the Request and returning true, false, "member", or "read", your own check
  #   instead of a token. True is full access, "member" changes everything but the install-wide controls (the
  #   mail service, the assistant's settings, and deleting a site), "read" reads every site's stats and changes
  #   nothing (as an API token can).
  # - cronSecret: also accepted as a bearer token on POST /api/check. Defaults to CRON_SECRET.
  # - observeKey: lets another site report AI agent fetches to POST /api/observe. Defaults to RUNLIGHT_OBSERVE_KEY.
  # - signOut, signIn: links the dashboard shows. The standalone server sets them.
  # - accounts: true for sign-in accounts, or a Runlight::Accounts::Web of your own.
  # - geoCredit: credits DB-IP in the dashboard's footer.
  # - origin: the address people open the app at, such as https://example.com.
  # - ownHosts: a callable returning more names the dashboard is reached at.
  # - accountOf: a callable taking the Request and returning the account it comes from, or nil (internal, for the
  #   standalone server).
  # - tokenMade: a callable taking a token row and who made it, returning whether that is allowed (internal).
  class Routes
    COOKIE = "runlight_token"
    IMPLEMENTATION = { "library" => "runlight", "language" => "ruby" }.freeze

    # API tokens start with this, so they are told apart from the main token.
    TOKEN_PREFIX = "rl_"
    # The header a shared dashboard sends its share id in.
    SHARE_HEADER = "x-runlight-share"
    # The header an embedded dashboard sends its session in.
    EMBED_HEADER = "x-runlight-embed"
    # What a share, or the dashboard inside a CMS, can read: one site's reports, nothing that changes anything.
    SHARED_PATHS = %w[/api/sites /api/icon /api/realtime /api/stats /api/series /api/rhythm /api/breakdown /api/goals
                      /api/event-props /api/export /api/funnels /api/journeys].freeze
    # Where the tracker's click rules go; the script ships with this string in their place.
    RULES_PLACEHOLDER = '"__RUNLIGHT_RULES__"'
    # Where the picker's one allowed receiver goes, the dashboard origin its ticket names.
    PICK_TARGET_PLACEHOLDER = '"__RUNLIGHT_PICK_TARGET__"'
    # Where the hostnames of the site its ticket names go, as JSON inside a string.
    PICK_HOSTS_PLACEHOLDER = '"__RUNLIGHT_PICK_HOSTS__"'
    # How long a picker ticket works: long enough to find the element, not to be kept.
    PICK_TICKET_MS = 30 * 60_000
    # Questions one person may put to the assistant in an hour, and at once.
    ASK_PER_HOUR = 30
    ASK_AT_ONCE = 2
    # Questions each viewer may ask a day, until an owner sets another number.
    VIEWER_DAILY = 50
    SHARE_ID = /\A[a-f0-9]{32}\z/
    # How long an embed ticket works: long enough for the admin page to load its frame, never to be kept.
    EMBED_TICKET_MS = 5 * 60_000
    # How long an embedded dashboard reads before the admin page has to be loaded again for a new ticket.
    EMBED_SESSION_MS = 60 * 60_000
    PATH_DIMENSIONS = %w[page entry exit ai_page].freeze
    # runlight.ts's LINK_DOMAIN_CHECK: the path on every link domain that answers when the domain reaches this Runlight.
    LINK_DOMAIN_CHECK = "/.well-known/runlight-link-domain"
    # runlight.ts's RETENTION_MONTHS: the choices for how long a site keeps its visits.
    RETENTION_MONTHS = [6, 12, 24, 36, 60].freeze
    private_constant :RULES_PLACEHOLDER, :PICK_TARGET_PLACEHOLDER, :PICK_HOSTS_PLACEHOLDER, :SHARE_ID,
                     :PATH_DIMENSIONS, :LINK_DOMAIN_CHECK, :RETENTION_MONTHS

    DASHBOARD_CSP = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

    # A domain name, such as go.example.com.
    DOMAIN_NAME = /\A(?=.{1,253}\z)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z/

    # What passes for an email address: something@somewhere.tld, with no spaces, quotes, or angle brackets.
    EMAIL = /\A[^#{Js::SPACE}@<>"]+@[^#{Js::SPACE}@<>"]+\.[^#{Js::SPACE}@<>"]+\z/
    # A dashboard's origin, which a picker ticket names.
    ORIGIN = %r{\Ahttps?://[^/?\##{Js::SPACE}]+\z}
    # An address a report's links may point back to.
    HOME = %r{\Ahttps?://[^#{Js::SPACE}]+\z}
    private_constant :EMAIL, :ORIGIN, :HOME

    # The files in assets/, read once per process.
    @assets = {}
    @locales = nil

    # Requests from a manage token, already checked against its one site, act as the owner's; requests from a
    # member have full access apart from the install-wide controls. Both are keyed by the request object.
    WEAK_MAP = defined?(ObjectSpace::WeakKeyMap) ? ObjectSpace::WeakKeyMap : ObjectSpace::WeakMap
    private_constant :WEAK_MAP

    attr_reader :base

    def initialize(runlight, options = {})
      options = Options.normalize(options)
      @rl = runlight
      @options = options
      @managed = WEAK_MAP.new
      @members = WEAK_MAP.new
      # When each report's last sample went out.
      @sample_sent = {}
      # Each person's questions to the assistant in the last hour, and how many are being answered now.
      @asked = {}
      @lock = Mutex.new
      @warned = false
      # The tracker per site, rebuilt when goals change.
      @trackers = {}
      @base = Routes.normalise_base(options.key?("basePath") && !options["basePath"].nil? ? options["basePath"].to_s : "/runlight")
      # Nil leaves the routes open on purpose; an unset RUNLIGHT_TOKEN is no token (""), never open.
      @token = if options.key?("token")
                 options["token"].nil? ? nil : options["token"].to_s
               else
                 Env.get("RUNLIGHT_TOKEN") || ""
               end
      @cron_secret = options["cronSecret"].nil? ? Env.get("CRON_SECRET") : options["cronSecret"].to_s
      @observe_key = options["observeKey"].nil? ? Env.get("RUNLIGHT_OBSERVE_KEY") : options["observeKey"].to_s
      @origin = Js.truthy?(options["origin"]) ? Http::Url.new(options["origin"].to_s).origin : nil
      # A link domain leaves these paths to the app, so the dashboard stays reachable on every name.
      mount = @base != "" ? @base : "/"
      runlight.route_bases << mount unless runlight.route_bases.include?(mount)

      # Accounts: the standalone server passes its own, and an app turns them on with true. Sessions need a secret
      # that outlives the process; in development without one, a made-up one does, so a restart signs everyone out.
      # An app left open on purpose (token: nil) is treated like development here.
      token = @token
      open_setup = token.nil? || (token == "" && development?)
      account_secret = runlight.secret || (open_setup ? Hashing.random_id(32) : nil)
      accounts = options["accounts"]
      @web = if accounts.is_a?(Accounts::Web)
               accounts
             elsif accounts == true && !account_secret.nil? && account_secret != ""
               web = {
                 "runlight" => runlight,
                 "secret" => account_secret,
                 "base" => @base,
                 "now" => -> { runlight.now },
                 # The app's token proves who may make the first account; in development without one, anyone may.
                 "firstAccount" => !token.nil? && token != "" ? { "token" => token } : (open_setup ? "open" : "locked"),
                 "forgot" => "https://runlight.sh/docs/configuration/#accounts",
               }
               if Js.truthy?(options["origin"])
                 home = Http::Url.new(options["origin"].to_s).origin
                 web["home"] = -> { home }
               end
               Accounts::Web.new(web)
             end

      web = @web
      @sign_in = options["signIn"].nil? ? (web ? "#{@base}/login" : nil) : options["signIn"].to_s
      @sign_out = options["signOut"].nil? ? (web ? "#{@base}/logout" : nil) : options["signOut"].to_s
      @account_of = options["accountOf"] || (web ? ->(r) { web.account_of(r) } : nil)
      @token_made = options["tokenMade"] || (web ? ->(row, by) { web.token_made(row, by) } : nil)
      authorize = options["authorize"]
      oauth = {
        "runlight" => runlight,
        "base" => @base,
        "isOwner" => ->(r) { can_read(r) == true },
        "isReader" => ->(r) { authorize.nil? ? (web ? web.access(r) == "read" : false) : authorize.call(r) == "read" },
      }
      oauth["signIn"] = @sign_in if !@sign_in.nil? && @sign_in != ""
      oauth["accountOf"] = @account_of unless @account_of.nil?
      oauth["tokenMade"] = @token_made unless @token_made.nil?
      @oauth = oauth
    end

    # Helpers that need nothing of an instance, callable from the class and from the routes alike.
    module Helpers
      def escape_html(value)
        value.to_s.gsub(/[&<>"']/, "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", '"' => "&quot;", "'" => "&#39;")
      end

      # The discovery documents OAuth clients read: two of OAuth's own, and OpenID's, which some clients try first.
      def oauth_document?(path)
        path.start_with?("/.well-known/oauth-") || path.start_with?("/.well-known/openid-configuration")
      end

      def development?
        Env.get("NODE_ENV") == "development"
      end

      # An error the dashboard can show in its own language: `code` names it and
      # `params` fill its placeholders, while `error` stays the English message.
      def coded(error, code, status, params = nil, headers = {})
        body = { "error" => error, "code" => code }
        body["params"] = params.to_h unless params.nil?
        json(body, status, headers)
      end

      # A refusal from a check elsewhere: its own code and params when the error
      # carries them, or else `fallback` with its English words as `detail`.
      def refused(error, fallback, status = 400)
        own = error.respond_to?(:code) ? error.code : nil
        if own.is_a?(String)
          params = error.respond_to?(:params) ? error.params : nil
          return coded(error.message, own, status, params.is_a?(Hash) ? params : nil)
        end
        coded(error.message, fallback, status, { "detail" => error.message })
      end

      def json(body, status = 200, headers = {})
        Http::Response.new(Json.encode(body), status: status, headers: {
          "content-type" => "application/json; charset=utf-8",
          "cache-control" => "no-store",
          "x-content-type-options" => "nosniff",
        }.merge(headers))
      end

      # Whether a request's body is JSON by its media type. A cross-site form or a
      # no-cors fetch can only send text/plain, urlencoded, or multipart, so a JSON
      # media type proves the request came from a page allowed to send it. A
      # substring test would accept "text/plain; application/json", which can.
      def json?(request)
        Js.lower(Js.trim((request.headers.get("content-type") || "").split(";", -1).first.to_s)) == "application/json"
      end

      # A Host or X-Forwarded-Host value as a bare name: lowercase, with no port, no final dot, and no www.
      def host_name(value)
        first = Js.lower(Js.trim(value.to_s.split(",", -1).first.to_s))
        name = if first.start_with?("[")
                 close = first.index("]")
                 close.nil? ? "" : first[0, close + 1]
               else
                 first.sub(/:\d*\z/, "")
               end
        name.sub(/\.+\z/, "").sub(/\Awww\./, "")
      end

      # Whether a domain name is one kept for private networks or tests, or has
      # an IPv4 address inside it (as nip.io answers). The link-domain check
      # fetches from it, so a name inside the install's own network must never
      # get that far; names that only resolve there are refused when fetched.
      def private_name?(domain)
        return true if domain.match?(/(\A|\.)\d{1,3}(\.\d{1,3}){3}(\.|\z)/)

        domain.match?(/\.(internal|intranet|private|local|localhost|localdomain|lan|home|corp|home\.arpa|arpa|test|invalid|example)\z/)
      end

      def email?(value)
        Js.scrub(value).match?(EMAIL)
      end

      # A plain page in a visitor's language, for unsubscribing and for a share link that is gone.
      def small_page(lang, body, status = 200)
        Http::Response.new(
          "<!doctype html><html lang=\"#{lang}\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><meta name=\"robots\" content=\"noindex\"><title>Runlight</title>\n" \
          '<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#f4f4f5;font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;color:#111827}main{max-width:420px;margin:24px;padding:32px;background:#fff;border:1px solid #e5e7eb;border-radius:14px}h1{font-size:20px;margin:0 0 12px}p{margin:0 0 20px;color:#4b5563}button{height:40px;padding:0 18px;border:0;border-radius:8px;background:#111827;color:#fff;font:inherit;font-weight:600;cursor:pointer}</style></head><body><main>' \
          "#{body}</main></body></html>",
          status: status,
          headers: {
            "content-type" => "text/html; charset=utf-8",
            "cache-control" => "no-store",
            "content-security-policy" => "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'",
            "referrer-policy" => "no-referrer",
          },
        )
      end

      # The first language a browser asks for that the dashboard speaks, else English.
      def accepted_language(request)
        (request.headers.get("accept-language") || "").split(",", -1).each do |part|
          code = Js.lower(Js.slice(Js.trim(part.split(";", -1).first.to_s), 0, 2))
          return code if Messages.languages.include?(code)
        end
        "en"
      end

      # Rows of objects as CSV, with a column for every key the first row has, in the units a spreadsheet reads.
      def rows_csv(rows, sheet)
        readable = rows.map { |r| sheet_row(r, sheet) }
        header = readable.empty? ? ["value"] : readable[0].keys.map(&:to_s)
        Zip.csv(header, readable.map { |r| header.map { |k| r.key?(k) ? r[k] : nil } })
      end

      # One row for a spreadsheet: a bucket's start as the site's local date (and hour), rates as percents,
      # durations in seconds, and paths as people write them.
      def sheet_row(row, sheet)
        out = {}
        row.each do |key, value|
          key = key.to_s
          number = value.is_a?(Integer) || value.is_a?(Float)
          if key == "start" && number
            hour = sheet["interval"] == "hour" ? " #{Dates.local_weekday_hour(value.to_i, sheet["timezone"])[1].to_s.rjust(2, "0")}:00" : ""
            out["date"] = "#{Dates.local_date(value.to_i, sheet["timezone"])}#{hour}"
          elsif key == "bounceRate" && number
            out["bounceRatePercent"] = Js.round(value * 1000) / 10
          elsif %w[visitDuration timeOnPage].include?(key) && number
            out["#{key}Seconds"] = Js.round(value / 1000.0)
          elsif key == "value" && value.is_a?(String) && PATH_DIMENSIONS.include?(sheet["dimension"] || "")
            out["value"] = Sources.readable_path(value)
          else
            out[key] = value
          end
        end
        out
      end

      # A file to save, never shown in the browser or kept in a shared cache.
      def download(name, body, type)
        Http::Response.new(body, status: 200, headers: {
          "content-type" => type,
          "content-disposition" => "attachment; filename=\"#{name.gsub(/[^A-Za-z0-9._-]/, "-")}\"",
          "cache-control" => "private, no-store",
        })
      end

      def constant_time_equal(a, b)
        a = a.b
        b = b.b
        a.bytesize == b.bytesize && OpenSSL.fixed_length_secure_compare(a, b)
      end

      def cookie_value(token)
        Hashing.sha256("runlight-cookie:#{token}")
      end

      def read_cookie(request, name)
        (request.headers.get("cookie") || "").split(";", -1).each do |part|
          pieces = Js.trim(part).split("=", -1)
          pieces = [""] if pieces.empty?
          return pieces[1..].join("=") if pieces.first == name
        end
        ""
      end

      def bearer(request)
        header = request.headers.get("authorization") || ""
        header.b[0, 7].downcase == "bearer " ? Js.trim(header.b[7..]) : ""
      end

      def normalise_base(path)
        trimmed = "/#{path.to_s.gsub(%r{\A/+|/+\z}, "")}"
        trimmed == "/" ? "" : trimmed
      end

      def escape_attr(value)
        value.to_s.gsub(/[&"<>]/, "&" => "&#38;", '"' => "&#34;", "<" => "&#60;", ">" => "&#62;")
      end

      # A file from assets/, which scripts/ruby-assets.mts copies from the TypeScript SDK's generated files.
      def asset(name)
        cache = Routes.instance_variable_get(:@assets)
        cache[name] ||= begin
          File.read(File.join(Version::ASSETS, name), mode: "rb").force_encoding(Encoding::UTF_8)
        rescue Errno::ENOENT
          raise "Runlight: assets/#{name} is missing; run node --import tsx scripts/ruby-assets.mts."
        end
      end

      # Each language but English, as the dashboard fetches them.
      def locales
        Routes.instance_variable_get(:@locales) || begin
          all = Json.decode(asset("locales.json"))
          all.delete("en")
          Routes.instance_variable_set(:@locales, all)
        end
      end

      # One of the hashes in assets/build.json (PHP's Routes::hash, renamed so it never shadows Object#hash).
      def build_hash(name)
        Version.build[name].to_s
      end

      def locale_urls(base)
        urls = {}
        locales.each_key { |code| urls[code] = "#{base}/assets/locale.#{code}.#{build_hash("localesHash")}.json" }
        Json.encode(urls)
      end

      # The dashboard's page, which holds no data: the API it calls checks access. `embed` is the dashboard inside a
      # CMS's admin pages: { "session", "origin" }, its session (empty once its ticket was used or ran out) and the
      # admin origin that frames it.
      def dashboard(base, share = "", sign_out = "", geo_credit = false, accounts = false, sign_in = "", embed = nil)
        b = escape_attr(base)
        hash = build_hash("dashboardHash")
        attributes = (share != "" ? " data-share=\"#{escape_attr(share)}\"" : "") +
                     (sign_out != "" ? " data-sign-out=\"#{escape_attr(sign_out)}\"" : "") +
                     (sign_in != "" ? " data-sign-in=\"#{escape_attr(sign_in)}\"" : "") +
                     (geo_credit ? ' data-geo-credit=""' : "") +
                     (accounts ? ' data-accounts=""' : "") +
                     (embed.nil? ? "" : " data-embed=\"#{escape_attr(embed["session"])}\" data-embed-origin=\"#{escape_attr(embed["origin"])}\"")
        "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<meta name=\"robots\" content=\"noindex\">\n<title>Runlight</title>\n" \
          "<link rel=\"icon\" href=\"#{Brand.runlight_icon}\">\n" \
          "<link rel=\"stylesheet\" href=\"#{b}/assets/app.#{hash}.css\">\n</head>\n<body>\n" \
          "<div id=\"app\" data-base=\"#{b}\"#{attributes} data-world=\"#{b}/assets/world.#{build_hash("worldHash")}.json\" data-locales=\"#{escape_attr(locale_urls(base))}\"></div>\n" \
          "<script type=\"module\" src=\"#{b}/assets/app.#{hash}.js\"></script>\n</body>\n</html>\n"
      end

      def shared_path?(path)
        SHARED_PATHS.include?(path) || path.match?(%r{\A/api/goals/[a-f0-9]{24}\z})
      end

      # What a manage token, held by a Runlight hub, may read and change: one
      # site's goals, funnels, short links, link domains, email reports, and share
      # links, along with its name, timezone, and retention, and tickets for the
      # element picker. It may read which mail service sends reports, through GET
      # /api/mail, which hides the service's keys. Never people, tokens, changes to
      # the mail service, imports, or other sites.
      def manage_path(method, path)
        return false if path.start_with?("/api/links/import")
        return true if path.match?(%r{\A/api/(links|link-domains|reports|goals|funnels|shares)(/|\z)})
        return method == "POST" if path == "/api/pick"
        return method == "GET" if path == "/api/mail"
        return method == "PATCH" if path.match?(%r{\A/api/sites/[^/]+\z})

        false
      end

      def origin?(value)
        Js.scrub(value).match?(ORIGIN)
      end

      # decodeURIComponent, which throws on a broken escape, as the TypeScript does (an internal error there).
      def decode(text)
        decoded = Js.decode_uri_component(text)
        raise ArgumentError, "URI malformed" if decoded.nil?

        decoded
      end

      # `String(body[key] ?? fallback)`.
      def text(body, key, fallback = "")
        value = Js.get(body, key)
        value.nil? || value.equal?(UNDEFINED) ? fallback : Js.string(value)
      end

      def given?(body, key)
        !Js.get(body, key).equal?(UNDEFINED)
      end

      # A JSON value as the core's methods take it; undefined becomes nil.
      def plain(value)
        value.equal?(UNDEFINED) ? nil : value
      end

      # `Object.entries(value)` for an object or an array.
      def entries(value)
        value.is_a?(Hash) ? value.map { |k, v| [k.to_s, v] } : value.each_with_index.map { |v, i| [i.to_s, v] }
      end

      # `Object.fromEntries(Object.entries(value).map(([k, v]) => [k, String(v)]))` for an object, else nothing.
      def credentials(value)
        out = {}
        entries(value).each { |k, v| out[k] = Js.string(v) } if Js.truthy?(value) && Js.object?(value)
        out
      end

      # `Math.min(1000, Math.max(1, Number(value) || fallback))`.
      def limit(value, fallback)
        n = Js.number(value)
        n = fallback if (n.is_a?(Float) && n.nan?) || n.zero?
        [1000, [1, n].max].min
      end

      # A number as a whole one for SQL, as PHP's (int) cast makes it.
      def whole(n)
        n.is_a?(Float) ? (n.finite? ? n.to_i : 0) : n.to_i
      end

      # The controls a member cannot change: the mail service and its keys, the assistant's settings, and deleting a site.
      def admin_only?(path, method)
        (path == "/api/mail" && %w[PUT DELETE].include?(method)) ||
          (path == "/api/assistant" && %w[PUT DELETE].include?(method)) ||
          (path == "/api/assistant/limits" && method == "PUT") ||
          (path == "/api/assistant/models" && method == "POST") ||
          (path.match?(%r{\A/api/sites/[^/]+\z}) && method == "DELETE")
      end

      # The refusal for a hub that asks for something only safe once this app knows its own address.
      def origin_needed
        coded("Set this Runlight's own address first (RUNLIGHT_URL on the server, or origin in routes()), so a connected hub can add link domains and email reports.", "origin_needed", 400)
      end

      def denied(result)
        return coded("Only an owner can change this", "owner_only", 403) if result == "read"

        if result == "unconfigured"
          coded("Set RUNLIGHT_TOKEN, or pass token or authorize to routes(). Without one, Runlight only runs open when NODE_ENV is development.", "token_unset", 503)
        else
          coded("Unauthorized", "unauthorized", 401)
        end
      end

      def read_json(request)
        # A form posted from another site cannot carry this content type without CORS.
        return coded("Send JSON", "send_json", 415) unless json?(request)

        parsed, body = Js.parse_json(request.text)
        parsed && body.is_a?(Hash) ? body : coded("Send a JSON object", "send_object", 400)
      end

      def report_view(r)
        { "id" => r["id"], "site" => r["site"], "email" => r["email"], "frequency" => r["frequency"], "lang" => r["lang"],
          "lastSentAt" => r["lastSentAt"], "createdAt" => r["createdAt"] }
      end

      # A field of a remote's info, or undefined when there is none, which JSON leaves out.
      def field(info, key)
        !info.nil? && info.key?(key) ? info[key] : UNDEFINED
      end

      # `text.replace(search, () => value)`: the first match only, with nothing in `value` read as a pattern.
      def replace_once(text, search, value)
        text.sub(search) { value }
      end
    end

    extend Helpers
    include Helpers

    PUBLIC_HELPERS = %i[coded json json? host_name cookie_value read_cookie bearer normalise_base dashboard manage_path].freeze
    private_constant :PUBLIC_HELPERS
    private(*Helpers.instance_methods(false))
    private_class_method(*(Helpers.instance_methods(false) - PUBLIC_HELPERS))

    # Answers one request under the base path: the dashboard and its assets, the tracker, the API, MCP,
    # OAuth, accounts, and the small pages, as the TypeScript handler does. context: { "ip" => ... }.
    def handle(request, context = {})
      url = Http::Url.new(request.url)
      base = @base
      # OAuth clients look for these at the site's root; an app routes them here when it wants OAuth.
      if base != "" && oauth_document?(url.pathname)
        begin
          return OAuth.oauth_response(@oauth, request, url.pathname, url, context) || coded("Not found", "not_found", 404)
        rescue StandardError => e
          warn("Runlight: #{e.full_message(highlight: false)}")
          return coded("Internal error", "internal", 500)
        end
      end
      return coded("Not found", "not_found", 404) if base != "" && url.pathname != base && !url.pathname.start_with?("#{base}/")

      path = url.pathname[base.length..].to_s
      path = "/" if path == ""

      begin
        route(request, path, url, context)
      rescue StandardError => e
        warn("Runlight: #{e.full_message(highlight: false)}")
        coded("Internal error", "internal", 500)
      end
    end

    # The routes as a Rack app. The answer to a HEAD has no body.
    def call(env)
      request = Http::Request.from_rack(env)
      status, headers, body = handle(request).to_rack
      [status, headers, request.method == "HEAD" ? [] : body]
    end

    private

    def sites
      @rl.sites
    end

    def store
      @rl.store
    end

    # Whether this request acts as the owner. "read" is someone signed in who may only read, such as a viewer.
    def can_read(request)
      return true if @managed.key?(request)

      authorize = @options["authorize"]
      if !authorize.nil? || !@web.nil?
        # A script's bearer token still has full access beside the sign-ins.
        given = bearer(request)
        return true if authorize.nil? && !@token.nil? && @token != "" && given != "" && constant_time_equal(given, @token)

        answer = authorize.nil? ? @web.access(request) : authorize.call(request)
        # A member changes things like an owner, apart from the few controls admin_only? names.
        @members[request] = true if answer == "member"
        return answer == "read" ? "read" : (answer == true || answer == "member")
      end
      return true if @token.nil?

      if @token == ""
        # Fails closed: only a process that says it is in development runs open.
        return "unconfigured" unless development?

        unless @warned
          @warned = true
          warn("Runlight: no RUNLIGHT_TOKEN set, so the dashboard is open because NODE_ENV is development. Anywhere else it answers 503 until a token is set.")
        end
        return true
      end
      given = bearer(request)
      return true if given != "" && constant_time_equal(given, @token)

      cookie = read_cookie(request, COOKIE)
      cookie != "" && constant_time_equal(cookie, cookie_value(@token))
    end

    # An API token from the bearer header: read-only, and maybe limited to one site.
    def api_token(request)
      given = bearer(request)
      return nil unless given.start_with?(TOKEN_PREFIX)

      @rl.init
      row = store.token_by_hash(Hashing.sha256(given))
      return nil if row.nil?

      now = @rl.now
      # At most once a minute, so a busy assistant does not write on every call.
      store.touch_token(row["id"], now) if row["lastUsedAt"].nil? || now - row["lastUsedAt"] > 60_000
      row
    end

    # Who may read stats: the owner (true), an API token or a read-only sign-in (its row), or nobody.
    def reader(request)
      token = api_token(request)
      # A key for the dashboard inside a CMS gets tickets and reads nothing itself.
      return token["scope"] == "embed" ? false : token unless token.nil?

      if !@options["authorize"].nil? || !@web.nil?
        access = can_read(request)
        # A read-only sign-in reads like an API token for every site.
        if access == "read"
          return { "id" => "", "name" => "", "site" => "", "scope" => "read", "hash" => "", "hint" => "", "createdAt" => 0,
                   "lastUsedAt" => nil }
        end

        return access == true
      end
      access = can_read(request)
      access == "read" ? false : access
    end

    def query_site(url)
      @rl.site(url.search_params.get("site")) || coded("Unknown site", "unknown_site", 404)
    end

    def read_query(url, site)
      params = url.search_params
      filters = []
      if params.get_all("filter").length > Query::MAX_FILTERS
        return coded("Use at most #{Query::MAX_FILTERS} filters at once.", "filters_max", 400, { "max" => Query::MAX_FILTERS.to_s })
      end

      params.get_all("filter").each do |raw|
        filter = Query.parse_filter(raw)
        return coded("Bad filter \"#{raw}\". Use dimension:is|not|contains:value.", "filter_bad", 400, { "filter" => raw }) if filter.nil?

        filters << filter
      end
      now = @rl.now
      first_date = nil
      if params.get("period") == "all"
        first = store.first_seen(site["id"])
        first_date = Dates.local_date(first.to_i, site["timezone"]) unless first.nil?
      end
      range = Dates.resolve_range({ "period" => params.get("period"), "from" => params.get("from"), "to" => params.get("to"),
                                    "interval" => params.get("interval") }, site["timezone"], now, first_date)
      return coded("Bad date range. Use period, or from and to as YYYY-MM-DD.", "range_bad", 400) if range.nil?

      query = { "site" => site["id"], "from" => range["from"], "to" => range["to"], "filters" => filters }
      # compare=false is the older spelling of off.
      raw = params.get("compare") || "previous"
      mode = raw == "false" ? "off" : raw
      unless %w[previous year custom off].include?(mode)
        return coded("Bad compare \"#{raw}\". Use previous, year, custom, or off.", "compare_bad", 400, { "compare" => raw })
      end

      compared = Dates.compare_range(range, mode, site["timezone"], { "from" => params.get("compare_from"), "to" => params.get("compare_to") })
      if mode == "custom" && compared.nil?
        return coded("Bad comparison range. Use compare_from and compare_to as YYYY-MM-DD.", "compare_range_bad", 400)
      end

      { "query" => query, "range" => range, "compared" => compared }
    end

    # Answers a read for a site counted by another install by asking that install,
    # with its token and its own id for the site, and handing back what it says.
    def pass_through(remote, path, url, request = nil)
      target = Http::Url.new("#{remote["url"]}#{path}")
      query = target.search_params
      url.search_params.each { |key, value| query.append(key.to_s, value) }
      query.set("site", remote["site"].to_s)
      target.search_params = query
      # A change made from the hub goes on to the install with its JSON body; reads carry none.
      write = !request.nil? && request.method != "GET" && request.method != "HEAD"
      headers = { "authorization" => "Bearer #{remote["token"]}" }
      headers["content-type"] = request.headers.get("content-type").to_s if write && Js.truthy?(request.headers.get("content-type"))
      host = Http::Url.new(remote["url"].to_s).host
      begin
        init = {
          "method" => write ? request.method : "GET",
          "headers" => headers,
          # An install that answers with a redirect gets no fetch of somewhere else on its behalf.
          "redirect" => "manual",
          # A long report or an export is worked out in full before the install sends a byte, so reads get
          # two minutes.
          "timeoutMs" => write ? 30_000 : 120_000,
        }
        init["body"] = request.text if write
        answer = @rl.fetcher.fetch(target.href, init)
      rescue StandardError => e
        if e.is_a?(Http::FetchError) && e.timed_out?
          return coded("#{host} took too long to answer. Try a shorter range.", "remote_slow", 504, { "host" => host })
        end

        return coded("Could not reach #{host}", "unreachable", 502, { "host" => host })
      end
      # What comes back is shown from this server's origin, so it is never taken as a page:
      # JSON, or a download for exports, with sniffing off and nothing allowed to run.
      download = path == "/api/export" || (path == "/api/breakdown" && url.search_params.get("format") == "csv")
      type = if download
               (answer.headers.get("content-type") || "").start_with?("text/csv") ? "text/csv; charset=utf-8" : "application/zip"
             else
               "application/json; charset=utf-8"
             end
      back = {
        "cache-control" => "private, no-store",
        "x-content-type-options" => "nosniff",
        "content-security-policy" => "default-src 'none'; frame-ancestors 'none'",
        "content-type" => type,
      }
      if download
        m = (answer.headers.get("content-disposition") || "").match(/filename="([A-Za-z0-9._-]+)"/)
        back["content-disposition"] = "attachment; filename=\"#{m ? m[1] : "runlight-export"}\""
      end
      if answer.status >= 300 && answer.status < 400
        return coded("#{host} answered with a redirect", "redirected", 502, { "host" => host })
      end
      # The install's own errors say what went wrong there; a refused token is this server's problem to report.
      if answer.status == 401
        return coded("#{host} refused the token. Connect it again from the site's settings.", "token_refused", 502, { "host" => host })
      end

      # An install's own error is shown here, so it says where it came from, keeps only short text, and
      # carries its code and params for the dashboard to put in its own words.
      if answer.status >= 400 && !download
        text = begin
          Body.utf8(answer.text)
        rescue StandardError
          ""
        end
        body = nil
        if Js.length(text) <= 65_536
          parsed, value = Js.parse_json(text)
          body = parsed && Js.object?(value) ? value : nil
        end
        read = ->(key) { body.nil? ? nil : Js.get(body, key) }
        params = []
        given = read.call("params")
        if Js.truthy?(given) && Js.object?(given)
          entries(given).each do |k, v|
            params << [Js.slice(k, 0, 40), Js.slice(v, 0, 200)] if v.is_a?(String)
          end
          params = params.first(10)
        end
        error = read.call("error")
        out = { "error" => "#{host}: #{error.is_a?(String) ? Js.slice(error, 0, 300) : "answered #{answer.status}"}" }
        code = read.call("code")
        if code.is_a?(String) && code.match?(/\A[a-z_]{1,40}\z/)
          out["code"] = code
          fields = {}
          params.each { |k, v| fields[k] = v }
          out["params"] = fields
        end
        return json(out, answer.status, back)
      end
      Http::Response.new(answer.text, status: answer.status, headers: back)
    end

    def links_api(request, path, url)
      @rl.init
      site = query_site(url)
      return site if site.is_a?(Http::Response)

      own_domains = -> { store.link_domains.select { |d| d["site"] == site["id"] }.map { |d| d["domain"] } }
      begin
        if path == "/api/link-domains"
          return json({ "domains" => own_domains.call }) if request.method == "GET"

          if request.method == "POST"
            body = read_json(request)
            return body if body.is_a?(Http::Response)

            domain = Js.lower(Js.trim(text(body, "domain")))
            domain = domain.sub(%r{\Ahttps?://}, "")
            domain = domain.sub(%r{/.*\z}, "")
            domain = domain.sub(/\.+\z/, "")
            domain = domain.sub(/\Awww\./, "")
            return coded("That is not a domain name", "domain_invalid", 400) unless domain.match?(DOMAIN_NAME)

            if private_name?(domain) || Safefetch.resolves_privately?(domain)
              return coded("#{domain} is not a public domain name. Use one that browsers anywhere can reach.", "domain_not_public", 400, { "domain" => domain })
            end

            # A link domain answers every path on it, so it must never be where the dashboard or a counted site lives.
            # The request's own Host is the caller's to choose, so the configured address and the names people
            # signed in from count too. A hub cannot know every name this app answers on, so it adds none until
            # the app knows its own address.
            return origin_needed if @managed.key?(request) && @origin.nil?

            here = [request.headers.get("host"), request.headers.get("x-forwarded-host"), url.host].select { |h| Js.truthy?(h) }
            own = [*(@origin.nil? ? [] : [Http::Url.new(@origin).host]), *here]
            @options["ownHosts"]&.call&.each { |host| own << host.to_s }
            taken = own.map { |h| host_name(h) }
            sites.each do |s|
              taken.concat(s["hostnames"])
              taken.concat(@rl.remote(s["id"])&.[]("hostnames") || [])
            end
            if taken.include?(domain)
              return coded("#{domain} is where this dashboard or one of your sites lives. Use a separate domain or subdomain for short links, such as go.#{domain}.", "domain_in_use", 400, { "domain" => domain })
            end

            store.link_domains.each do |d|
              next unless d["domain"] == domain
              return coded("#{domain} already belongs to another site", "domain_taken", 409, { "domain" => domain }) if d["site"] != site["id"]

              break
            end
            store.add_link_domain(domain, site["id"], @rl.now)
            @rl.forget_link_domains
            return json({ "domain" => domain }, 201)
          end
        end
        if (check_match = path.match(%r{\A/api/link-domains/([^/]+)/check\z})) && request.method == "GET"
          domain = decode(check_match[1])
          return coded("Unknown domain", "unknown_domain", 404) unless own_domains.call.include?(domain)

          # One added before names inside private networks were refused is never fetched.
          # What the check found, as a code the dashboard says in its own words, beside the English reason.
          # Where the domain should point, for the setup steps: this server's name, and its public addresses
          # for a bare domain, which takes an A record. A server reached by its address has no name to give.
          own_host = @origin.nil? ? url.hostname : Http::Url.new(@origin).hostname
          target = { "host" => own_host, "addresses" => Safefetch.public_addresses(own_host) }
          result = lambda do |code, reason, params = nil|
            out = { "domain" => domain, "working" => code == "", "reason" => reason, "target" => target }
            if code != ""
              out["code"] = code
              out["params"] = params unless params.nil?
            end
            json(out)
          end
          return result.call("check_not_public", "is not a public domain name") if !domain.match?(DOMAIN_NAME) || private_name?(domain)

          begin
            # Only a public address is fetched, whatever the name resolves to now, so the check cannot be pointed
            # into a private network.
            answer = Safefetch.public_fetch("https://#{domain}#{LINK_DOMAIN_CHECK}", { "timeoutMs" => 5000 }, @rl.fetcher)
            parsed, body = begin
              Js.parse_json(answer.text)
            rescue StandardError
              [false, nil]
            end
            body = parsed && Js.object?(body) ? body : nil
            if answer.ok? && !body.nil? && Js.get(body, "runlight") == true && Js.get(body, "domain") == domain
              return result.call("", "")
            end

            return answer.ok? ? result.call("check_not_runlight", "answered, but not from Runlight") : result.call("check_status", "answered #{answer.status}", { "status" => answer.status.to_s })
          rescue StandardError => e
            # A refused private address answers as a closed port does, so the check tells nothing about a private network.
            return e.is_a?(Http::FetchError) && e.timed_out? ? result.call("check_timeout", "timed out") : result.call("check_https", "could not connect over HTTPS")
          end
        end

        if (domain_match = path.match(%r{\A/api/link-domains/([^/]+)\z})) && request.method == "DELETE"
          domain = decode(domain_match[1])
          return coded("Unknown domain", "unknown_domain", 404) unless own_domains.call.include?(domain)

          store.remove_link_domain(domain)
          @rl.forget_link_domains
          return json({ "ok" => true })
        end

        if path == "/api/links"
          if request.method == "GET"
            read = read_query(url, site)
            return read if read.is_a?(Http::Response)

            links = store.links(site["id"], read["range"]["from"], read["range"]["to"])
            # Links on a removed domain are served from the app's own path until it is added back.
            return json({ "prefix" => "#{url.origin}#{@rl.link_path}", "domains" => own_domains.call, "links" => links })
          end
          if request.method == "POST"
            body = read_json(request)
            return body if body.is_a?(Http::Response)

            input = { "url" => text(body, "url") }
            %w[name slug domain].each { |key| input[key] = Js.string(Js.get(body, key)) if given?(body, key) }
            link = @rl.links.create(site["id"], input)
            return json({ "link" => link }, 201)
          end
        end

        # One step of an import from another shortener; the page calls again with the cursor.
        if (import_match = path.match(%r{\A/api/links/import/([a-z]+)\z})) && request.method == "POST"
          body = read_json(request)
          return body if body.is_a?(Http::Response)

          cursor = Js.get(body, "cursor")
          done = Js.number(Js.get(body, "done"))
          begin
            step = Importers::Index.import_step(
              @rl,
              site["id"],
              import_match[1],
              credentials(Js.get(body, "credentials")),
              cursor.is_a?(String) ? cursor : nil,
              done.is_a?(Float) && done.nan? ? 0 : done,
            )
            return json(step)
          rescue Importers::ImportError => e
            return refused(e, "import_failed")
          end
        end

        if path == "/api/links/import" && request.method == "POST"
          body = read_json(request)
          return body if body.is_a?(Http::Response)

          # Rows that are not objects (null, a number) are dropped rather than failing the import.
          given = Js.get(body, "rows")
          return coded("Send rows as a list", "rows_needed", 400) unless given.is_a?(Array)

          rows = given.select { |row| row.is_a?(Hash) }.first(5000)
          return json(@rl.links.import(site["id"], rows.map { |r| plain(r) }))
        end

        if (link_match = path.match(%r{\A/api/links/([a-f0-9]+)\z}))
          id = link_match[1]
          if request.method == "GET"
            link = store.link_by_id(id)
            return coded("Unknown link", "unknown_link", 404) if link.nil? || link["site"] != site["id"]

            read = read_query(url, site)
            return read if read.is_a?(Http::Response)

            range = read["range"]
            by = lambda do |dimension|
              Query.session_dimension?(dimension) ? store.link_breakdown(site["id"], id, range["from"], range["to"], dimension, 10) : []
            end
            series = store.link_series(site["id"], id, Dates.buckets(range, site["timezone"]))
            clicks = series.sum { |p| p["clicks"] }
            return json({
              "link" => link,
              "range" => { "from" => range["fromDate"], "to" => range["toDate"], "interval" => range["interval"], "timezone" => site["timezone"] },
              "clicks" => clicks,
              "series" => series,
              "sources" => by.call("source"),
              "referrers" => by.call("referrer"),
              "countries" => by.call("country"),
              "devices" => by.call("device"),
              "browsers" => by.call("browser"),
            })
          end
          owned = store.link_by_id(id)
          return coded("Unknown link", "unknown_link", 404) if owned.nil? || owned["site"] != site["id"]

          if request.method == "PATCH"
            body = read_json(request)
            return body if body.is_a?(Http::Response)

            patch = {}
            %w[url name slug domain].each { |key| patch[key] = Js.string(Js.get(body, key)) if given?(body, key) }
            return json({ "link" => @rl.links.update(id, patch) })
          end
          if request.method == "DELETE"
            @rl.links.remove(id)
            return json({ "ok" => true })
          end
        end
      rescue LinkError => e
        return coded(e.message, e.code, 400, e.params)
      rescue RangeError => e
        return coded(e.message, "unknown_link", 404)
      end
      coded("Not found", "not_found", 404)
    end

    # The key picker tickets are signed with, made on first use and kept in the database for every process.
    def pick_key
      @rl.init
      saved = store.setting("pick-key")
      return saved if !saved.nil? && saved != ""

      made = Hashing.random_id(32)
      store.set_setting("pick-key", made)
      made
    end

    # A ticket that lets the picker, on `site`'s pages, send its choice to `origin`, the dashboard that asked, for half an hour.
    def pick_ticket(origin, site)
      payload = "#{@rl.now + PICK_TICKET_MS}.#{site.unpack1("H*")}.#{origin.unpack1("H*")}"
      "#{payload}.#{Hashing.hmac(pick_key, payload)}"
    end

    # The dashboard origin and site a picker ticket names, or nil when it is not one this install signed or has run out.
    def pick_target(ticket)
      parts = ticket.match(/\A(\d+)\.([a-f0-9]{2,512})\.([a-f0-9]{2,512})\.([a-f0-9]{64})\z/)
      return nil if parts.nil? || Js.number(parts[1]) < @rl.now
      return nil unless constant_time_equal(parts[4], Hashing.hmac(pick_key, "#{parts[1]}.#{parts[2]}.#{parts[3]}"))

      unhex = ->(text) { Js.scrub([text[0, text.length - (text.length % 2)]].pack("H*")) }
      origin = unhex.call(parts[3])
      origin?(origin) ? { "origin" => origin, "site" => unhex.call(parts[2]) } : nil
    end

    # The key embed tickets and sessions are signed with, made on first use and kept in the database for every process.
    def embed_key
      @rl.init
      saved = store.setting("embed-key")
      return saved if !saved.nil? && saved != ""

      made = Hashing.random_id(32)
      store.set_setting("embed-key", made)
      made
    end

    # An embed token that still exists, for a site that still does.
    def embed_token(id)
      token = store.tokens.find { |t| t["id"] == id }
      return nil if token.nil?

      token["scope"] == "embed" && token["site"] != "" && !@rl.site(token["site"]).nil? ? token : nil
    end

    # A ticket for one load of the embedded dashboard, signed with when it runs out, a nonce, and the admin origin
    # that may frame it. The nonce is kept, with the token it was made for, until the ticket is used.
    def embed_ticket(origin, token)
      now = @rl.now
      # Tickets nobody used are cleared as new ones are made.
      store.settings_starting_with("embed-ticket:").each do |row|
        store.set_setting(row["key"], nil) if Js.number(row["value"].split(".", -1).first.to_s) < now
      end
      expires_at = now + EMBED_TICKET_MS
      nonce = Hashing.random_id(16)
      store.set_setting("embed-ticket:#{nonce}", "#{expires_at}.#{token}")
      payload = "#{expires_at}.#{nonce}.#{origin.unpack1("H*")}"
      { "ticket" => "#{payload}.#{Hashing.hmac(embed_key, "ticket.#{payload}")}", "expiresAt" => expires_at }
    end

    # What a ticket this install signed names: always its origin, and its token only the first time it is used
    # before it runs out. Nil for anything else.
    def redeem_embed(ticket)
      parts = ticket.match(/\A(\d{1,15})\.([a-f0-9]{32})\.([a-f0-9]{2,512})\.([a-f0-9]{64})\z/)
      return nil if parts.nil?
      return nil unless constant_time_equal(parts[4], Hashing.hmac(embed_key, "ticket.#{parts[1]}.#{parts[2]}.#{parts[3]}"))

      hex = parts[3]
      origin = Js.scrub([hex[0, hex.length - (hex.length % 2)]].pack("H*"))
      return nil unless origin?(origin)

      # A ticket works once: it is gone before anything else is checked.
      kept = store.take_setting("embed-ticket:#{parts[2]}")
      token = !kept.nil? && kept != "" && Js.number(parts[1]) >= @rl.now ? embed_token(kept.split(".", -1)[1] || "") : nil
      { "origin" => origin, "token" => token }
    end

    # A session for an embedded dashboard, which its page sends with every read, signed with when it runs out and its token.
    def embed_session(token)
      payload = "#{@rl.now + EMBED_SESSION_MS}.#{token}"
      "#{payload}.#{Hashing.hmac(embed_key, "session.#{payload}")}"
    end

    # The embed token a session this install signed was made for, while it lasts and the token still exists.
    def embed_reader(session)
      parts = session.match(/\A(\d{1,15})\.([a-f0-9]{24})\.([a-f0-9]{64})\z/)
      return nil if parts.nil? || Js.number(parts[1]) < @rl.now
      return nil unless constant_time_equal(parts[3], Hashing.hmac(embed_key, "session.#{parts[1]}.#{parts[2]}"))

      embed_token(parts[2])
    end

    # The tracker with click rules inside, rebuilt when goals change. With ?site= it carries only that site's rules,
    # so one site's visitors never see another site's domains or goals. The standalone server's snippet always names
    # the site; without a name it serves no rules, and an app's own install, whose sites all belong to one owner,
    # serves every site's.
    def tracker_script(site_id)
      key = site_id || ""
      cached = @trackers[key]
      return cached if !cached.nil? && @rl.now - cached["at"] < 60_000

      @rl.init
      chosen = if site_id.nil?
                 @rl.managed_sites ? [] : sites
               else
                 sites.select { |s| s["id"] == site_id }
               end
      rules = Json.encode(Goals.click_rules(chosen, store.goals))
      body = replace_once(asset("tracker.js"), RULES_PLACEHOLDER, rules)
      script = { "body" => body, "etag" => "\"#{build_hash("trackerHash")}-#{Hashing.sha256(rules)[0, 8]}\"", "at" => @rl.now }
      # One entry per site at most; a query naming no real site gets the empty script without filling the map.
      @trackers[key] = script if site_id.nil? || !chosen.empty?
      script
    end

    def goal_writes(request, path, url)
      @rl.init
      site = query_site(url)
      return site if site.is_a?(Http::Response)

      existing = store.goals(site["id"])
      id = path == "/api/goals" ? nil : decode(path["/api/goals/".length..])
      before = nil
      existing.each { |g| before = g if g["id"] == id }
      return coded("Unknown goal", "unknown_goal", 404) if !id.nil? && before.nil?

      @trackers = {}
      if request.method == "DELETE"
        store.delete_goal(id)
        return json({ "ok" => true })
      end
      body = read_json(request)
      return body if body.is_a?(Http::Response)

      begin
        goal = Goals.goal_from(body, site["id"], existing, @rl.now, id)
        store.save_goal(goal, before)
        json({ "goal" => goal }, !id.nil? && id != "" ? 200 : 201)
      rescue GoalError => e
        refused(e, "goal_invalid")
      end
    end

    def mail_api(request, path, url)
      @rl.init
      begin
        if path == "/api/mail"
          if request.method == "GET"
            settings = @rl.mail_settings
            known = settings || {}
            service = Mail::Transports::SERVICES.find { |s| s["id"] == known["service"] }
            # Secret fields come back only as "saved", never as their value.
            fields = {}
            saved = []
            (service ? service["fields"] : []).each do |f|
              if Js.truthy?(f["secret"])
                saved << f["name"] if Js.truthy?(known[f["name"]])
              else
                value = known[f["name"]]
                fields[f["name"]] = value.nil? ? "" : Js.string(value)
              end
            end
            # A hub with a manage token learns which service sends the reports and from where, nothing more.
            via_manage = @managed.key?(request)
            return json({
              "source" => known["source"],
              "service" => known["service"] || "",
              "from" => known["from"] || "",
              "fromName" => known["fromName"] || "",
              "fields" => via_manage ? {} : fields,
              "saved" => via_manage ? [] : saved,
              "encrypted" => !@rl.secret.nil?,
              "services" => Mail::Transports::SERVICES,
            })
          end
          if request.method == "PUT"
            body = read_json(request)
            return body if body.is_a?(Http::Response)

            @rl.save_mail_settings(plain(body))
            return json({ "ok" => true })
          end
          if request.method == "DELETE"
            @rl.save_mail_settings(nil)
            return json({ "ok" => true })
          end
          return coded("Method not allowed", "method_not_allowed", 405)
        end

        if path == "/api/mail/test" && request.method == "POST"
          body = read_json(request)
          return body if body.is_a?(Http::Response)

          to = Js.trim(text(body, "to"))
          return coded("Enter an email address to send the test to", "test_email", 400) unless email?(to)

          settings = @rl.mail_settings
          return coded("Set up a mail service first", "mail_unset", 400) if settings.nil?

          t = Messages.translator(text(body, "lang", "en"))["t"]
          name = Mail::Transports::SERVICES.find { |s| s["id"] == settings["service"] }&.[]("name") || ""
          @rl.send_mail({
            "to" => to,
            "subject" => t.call("email.test.subject"),
            "text" => t.call("email.test.body", { "service" => name }),
            "html" => "<p style=\"font-family:sans-serif;font-size:15px\">#{escape_html(t.call("email.test.body", { "service" => name }))}</p>",
          })
          return json({ "ok" => true })
        end

        site = query_site(url)
        return site if site.is_a?(Http::Response)

        if path == "/api/reports"
          if request.method == "GET"
            return json({ "reports" => store.reports(site["id"]).map { |r| report_view(r) }, "languages" => Messages.languages })
          end
          if request.method == "POST"
            body = read_json(request)
            return body if body.is_a?(Http::Response)

            email = Js.lower(Js.trim(text(body, "email")))
            return coded("Enter an email address", "email_invalid", 400) unless email?(email)

            frequency = Js.get(body, "frequency") == "monthly" ? "monthly" : "weekly"
            existing = store.reports(site["id"])
            existing.each do |r|
              if r["email"] == email && r["frequency"] == frequency
                return coded("#{email} already gets the #{frequency} report", "report_exists", 400, { "email" => email })
              end
            end
            return coded("A site can send to at most 50 addresses", "report_limit", 400) if existing.length >= 50

            # Links in the email point back to the configured address, or else to this dashboard as the
            # browser sees it. A report made from a hub needs the configured address, where its unsubscribe
            # link answers, since the Host its request names is the hub's to choose.
            return origin_needed if @managed.key?(request) && @origin.nil?

            given = @origin.nil? ? text(body, "origin") : ""
            home = Js.scrub(given).match?(HOME) ? given.sub(%r{/+\z}, "") : "#{@origin || url.origin}#{@base}"
            # A period already due counts as sent, so a report added mid-week first goes out on the next Monday, as the form says.
            now = @rl.now
            due = Reports.last_period(frequency, now, site["timezone"])
            lang = Js.string(Js.get(body, "lang"))
            report = {
              "id" => Hashing.random_id,
              "site" => site["id"],
              "email" => email,
              "frequency" => frequency,
              "lang" => Messages.languages.include?(lang) ? lang : "en",
              "token" => Hashing.random_id(16),
              "origin" => home,
              "lastPeriod" => now >= due["dueAt"] ? due["key"] : "",
              "lastSentAt" => nil,
              "createdAt" => now,
            }
            store.insert_report(report)
            return json({ "report" => report_view(report) }, 201)
          end
          return coded("Method not allowed", "method_not_allowed", 405)
        end

        match = path.match(%r{\A/api/reports/([a-f0-9]{24})(/send)?\z})
        report = match.nil? ? nil : store.report_by("id", match[1])
        return coded("Unknown report", "unknown_report", 404) if report.nil? || report["site"] != site["id"]

        send = !match[2].nil? && match[2] != ""
        if send && request.method == "POST"
          # A sample at most once a minute per report, so the send button cannot be used to flood an inbox. A hub
          # sends one every ten minutes for the whole site, so adding reports again does not start a new count.
          via_hub = @managed.key?(request)
          key = via_hub ? "site:#{site["id"]}" : report["id"]
          wait = via_hub ? 600_000 : 60_000
          last = @lock.synchronize { @sample_sent[key] || 0 }
          if @rl.now - last < wait
            return via_hub ? coded("A connected hub can send one sample every ten minutes. Wait a few minutes and try again.", "sample_soon_hub", 429) : coded("A sample went out a moment ago. Wait a minute and try again.", "sample_soon", 429)
          end

          @lock.synchronize { @sample_sent[key] = @rl.now }
          @rl.deliver_report(report, site)
          return json({ "ok" => true })
        end
        if !send && request.method == "DELETE"
          store.delete_report(report["id"])
          return json({ "ok" => true })
        end
        coded("Method not allowed", "method_not_allowed", 405)
      rescue Mail::MailError => e
        coded(e.message, e.code, 400, e.params)
      end
    end

    # A plain page for unsubscribing: a button, so a link scanner opening the URL changes nothing.
    def unsubscribe_page(request, token)
      @rl.init
      report = token.match?(/\A[a-f0-9]{32}\z/) ? store.report_by("token", token) : nil
      site = report.nil? ? nil : @rl.site(report["site"])
      translator = Messages.translator(report.nil? ? "en" : report["lang"])
      t = translator["t"]
      lang = translator["lang"]
      page = ->(body, status = 200) { small_page(lang, body, status) }
      if report.nil? || site.nil?
        return page.call("<h1>#{escape_html(t.call("email.unsub.goneTitle"))}</h1><p>#{escape_html(t.call("email.unsub.gone"))}</p>", 404)
      end

      if request.method == "POST"
        store.delete_report(report["id"])
        return page.call("<h1>#{escape_html(t.call("email.unsub.doneTitle"))}</h1><p>#{escape_html(t.call("email.unsub.done", { "site" => site["name"], "email" => report["email"] }))}</p>")
      end
      page.call("<h1>#{escape_html(t.call("email.unsub.title", { "site" => site["name"] }))}</h1><p>#{escape_html(t.call("email.unsub.body", { "email" => report["email"] }))}</p><form method=\"post\"><button type=\"submit\">#{escape_html(t.call("email.unsubscribe"))}</button></form>")
    end

    def shares_api(request, path, url)
      @rl.init
      site = query_site(url)
      return site if site.is_a?(Http::Response)

      view = ->(share) { share.merge("path" => "#{@base}/share/#{share["id"]}") }

      if path == "/api/shares"
        return json({ "shares" => store.shares(site["id"]).map(&view) }) if request.method == "GET"

        if request.method == "POST"
          body = read_json(request)
          return body if body.is_a?(Http::Response)

          share = { "id" => Hashing.random_id(16), "site" => site["id"], "name" => Js.slice(Js.trim(text(body, "name")), 0, 100), "createdAt" => @rl.now }
          store.insert_share(share)
          return json({ "share" => view.call(share) }, 201)
        end
        return coded("Method not allowed", "method_not_allowed", 405)
      end

      id = decode(path["/api/shares/".length..])
      share = id.match?(SHARE_ID) ? store.share_by_id(id) : nil
      return coded("Unknown share", "unknown_share", 404) if share.nil? || share["site"] != site["id"]

      if request.method == "PATCH"
        body = read_json(request)
        return body if body.is_a?(Http::Response)

        name = Js.slice(Js.trim(text(body, "name")), 0, 100)
        store.rename_share(share["id"], name)
        return json({ "share" => view.call(share.merge("name" => name)) })
      end
      if request.method == "DELETE"
        store.delete_share(share["id"])
        return json({ "ok" => true })
      end
      coded("Method not allowed", "method_not_allowed", 405)
    end

    # How many questions each viewer may ask the assistant a day, as an owner set it.
    def viewer_daily
      saved = store.setting("assistant-viewer-daily")
      saved.nil? ? VIEWER_DAILY : Js.number(saved)
    end

    # Counts a question to the assistant, which spends the owner's AI credit, or refuses it: past thirty an
    # hour or two at once for anyone, and past the owner's daily number for a viewer. Returns how to finish.
    # As in TypeScript, the hour's questions are counted in this process; the day's, in the settings.
    def ask_turn(who, owner)
      now = @rl.now
      mine = @lock.synchronize do
        held = @asked[who] || { "at" => [], "open" => 0 }
        held["at"] = held["at"].select { |at| now - at < 3_600_000 }
        held
      end
      if mine["at"].length >= ASK_PER_HOUR || mine["open"] >= ASK_AT_ONCE
        return coded("You have asked a lot in a short time. Wait a little and ask again.", "assistant_soon", 429)
      end

      unless owner
        daily = viewer_daily
        day = "assistant-asked:#{Time.at(now.div(1000)).utc.strftime("%Y-%m-%d")}"
        counts = Json.decode(store.setting(day) || "{}")
        if (counts[who] || 0) >= daily
          return coded("Viewers can ask #{Js.string(daily)} questions a day. Ask again tomorrow.", "assistant_daily", 429, { "limit" => Js.string(daily) })
        end

        counts[who] = (counts[who] || 0) + 1
        store.set_setting(day, Json.encode(counts))
        store.settings_starting_with("assistant-asked:").each do |entry|
          store.set_setting(entry["key"], nil) if entry["key"] != day
        end
      end
      @lock.synchronize do
        mine["at"] << now
        mine["open"] += 1
        @asked[who] = mine
        # People who stopped asking are dropped, so the map holds only the last hour's.
        if @asked.size > 1000
          @asked.delete_if { |_key, value| value["open"].zero? && value["at"].none? { |at| now - at < 3_600_000 } }
        end
      end
      -> { @lock.synchronize { mine["open"] -= 1 } }
    end

    def tokens_api(request, path)
      @rl.init
      view = lambda do |t|
        { "id" => t["id"], "name" => t["name"], "site" => t["site"], "scope" => t["scope"], "hint" => t["hint"],
          "createdAt" => t["createdAt"], "lastUsedAt" => t["lastUsedAt"] }
      end
      return json({ "tokens" => store.tokens.map(&view) }) if path == "/api/tokens" && request.method == "GET"

      if path == "/api/tokens" && request.method == "POST"
        body = read_json(request)
        return body if body.is_a?(Http::Response)

        name = Js.slice(Js.trim(text(body, "name")), 0, 100)
        return coded("Name the token", "token_name", 400) if name == ""

        site = text(body, "site")
        return coded("Unknown site", "unknown_site", 404) if site != "" && sites.none? { |s| s["id"] == site }

        asked_scope = Js.get(body, "scope")
        scope = %w[manage embed].include?(asked_scope) ? asked_scope : "read"
        return coded("A token that changes settings is for one site. Pick the site.", "token_site", 400) if scope == "manage" && site == ""
        return coded("A key for the dashboard in a CMS is for one site. Pick the site.", "embed_site", 400) if scope == "embed" && site == ""

        secret = "#{TOKEN_PREFIX}#{Hashing.random_id(20)}"
        row = { "id" => Hashing.random_id, "name" => name, "site" => site, "scope" => scope, "hash" => Hashing.sha256(secret),
                "hint" => secret[-4..], "createdAt" => @rl.now, "lastUsedAt" => nil }
        store.insert_token(row)
        by = @account_of&.call(request)
        if !by.nil? && by != "" && !@token_made.nil? && !@token_made.call(row, by)
          store.delete_token(row["id"])
          return denied("read")
        end
        # The only time the token is ever shown.
        return json({ "token" => view.call(row), "secret" => secret }, 201)
      end
      if (match = path.match(%r{\A/api/tokens/([a-f0-9]{24})\z})) && request.method == "DELETE"
        return store.delete_token(match[1]) ? json({ "ok" => true }) : coded("Unknown token", "unknown_token", 404)
      end

      coded("Not found", "not_found", 404)
    end

    # A request for one API path, with the asker's own headers, as the MCP server and the assistant read it: a
    # callable taking the path and a list of [name, value] pairs.
    def read_api(request, url, default_site = nil)
      headers = Http::Headers.new(request.headers)
      ["content-type", "content-length", SHARE_HEADER, EMBED_HEADER].each { |name| headers.delete(name) }
      lambda do |api_path, params|
        target = Http::Url.new("#{@base}#{api_path}", url.origin)
        query = target.search_params
        params.each { |key, value| query.append(key.to_s, value.to_s) }
        # A tool that names no site reads the one on screen, not the install's first.
        query.set("site", default_site) if !default_site.nil? && api_path != "/api/sites" && !query.has?("site")
        target.search_params = query
        api(Http::Request.new(target.href, method: "GET", headers: headers, body: "", remote_address: ""), api_path, target)
      end
    end

    def api(request, path, url)
      rl = @rl
      method = request.method
      # An embedded dashboard reads what a share link shows and nothing else, whoever else the request comes from.
      if !request.headers.get(EMBED_HEADER).nil? && !(method == "GET" && shared_path?(path))
        return coded("Not available on a shared dashboard", "share_not_available", 403)
      end
      # A write must be JSON, which a form on another page cannot send, even the writes that carry no body.
      # That holds without a cookie too, since a browser also sends Basic credentials or comes from an
      # allowed address on its own. A bearer token is never sent by the browser on its own, so it needs no check.
      if !%w[GET HEAD OPTIONS DELETE].include?(method) && bearer(request) == "" && !json?(request)
        return coded("Send JSON", "send_json", 415)
      end
      if path == "/api" && method == "GET"
        return json({ "name" => "runlight", "version" => Version.version, "api" => Version.api_version }.merge(IMPLEMENTATION))
      end

      # A hub asks what its token may do before offering to change anything.
      if path == "/api/token" && method == "GET"
        token = api_token(request)
        return denied(false) if token.nil?

        return json({ "scope" => token["scope"], "site" => token["site"] })
      end
      # A token can delete itself, which a hub does when it disconnects a site or gets a new token.
      if path == "/api/token" && method == "DELETE"
        token = api_token(request)
        return denied(false) if token.nil?

        store.delete_token(token["id"])
        return json({ "ok" => true })
      end

      # Connecting another Runlight through its consent page, so nobody copies a token.
      if path == "/api/sites/connect" && method == "POST"
        access = can_read(request)
        return denied(access) if access != true

        rl.init
        return coded("Sites are set in code", "sites_in_code", 400) unless rl.managed_sites

        body = read_json(request)
        return body if body.is_a?(Http::Response)

        site = Js.get(body, "site")
        given = Js.get(body, "url")
        begin
          return json({ "authorize" => Connect.start_connect(rl, given.equal?(UNDEFINED) ? nil : given, "#{url.origin}#{@base}/api/sites/connect/done", site.is_a?(String) ? site : "") })
        rescue ConnectError => e
          return coded(e.message, e.code == "unreachable" ? "unreachable" : "connect_#{e.code}", 400, e.params)
        rescue RangeError => e
          return refused(e, "connect_failed")
        end
      end
      if path == "/api/sites/connect/done" && method == "GET"
        home = @base != "" ? @base : "/"
        access = can_read(request)
        return Http::Response.new("", status: 303, headers: { "location" => home, "cache-control" => "no-store" }) if access != true

        rl.init
        begin
          id = Connect.finish_connect(rl, url.search_params)
          # The site's settings open with a word that the connection worked, which a reconnection otherwise lacks.
          to = "#{home}?site=#{Js.encode_uri_component(id)}&settings=general&connected=1"
        rescue RangeError => e
          # A code, never the message: the dashboard shows its own words for it, so a link cannot put text there.
          to = "#{home}?connect_error=#{e.is_a?(ConnectError) ? e.code : "failed"}"
        end
        return Http::Response.new("", status: 303, headers: { "location" => to, "cache-control" => "no-store" })
      end

      # A ticket for one load of the dashboard inside a CMS's admin pages. The plugin's server asks with its embed
      # token on each page view and names the admin's origin, which must be one of the site's domains and alone
      # may frame the page the ticket opens.
      if path == "/api/embed" && method == "POST"
        token = api_token(request)
        return denied(false) if token.nil?
        return coded("Use a key for the dashboard in a CMS, made in Settings, Install", "embed_token", 403) if token["scope"] != "embed"

        site = token["site"] != "" ? rl.site(token["site"]) : nil
        return coded("Unknown site", "unknown_site", 404) if site.nil?

        body = read_json(request)
        return body if body.is_a?(Http::Response)

        origin = text(body, "origin")
        parsed = origin?(origin) && Js.length(origin) <= 200 ? Http::Url.parse(origin) : nil
        return coded("Send the admin page's origin, such as https://example.com", "embed_origin", 400) if parsed.nil? || parsed.origin != origin

        host = host_name(parsed.host)
        domains = ((rl.remote(site["id"]) || {})["hostnames"] || site["hostnames"] || []).map { |h| host_name(h) }
        unless domains.include?(host)
          return coded("#{host} is not one of this site's domains. Add it to the site's domains in Runlight's settings.", "embed_host", 400, { "host" => host })
        end

        made = embed_ticket(origin, token["id"])
        return json({ "ticket" => made["ticket"], "site" => site["id"], "expiresAt" => made["expiresAt"], "path" => "#{@base}/embed?ticket=#{made["ticket"]}" }, 201)
      end

      token = bearer(request).start_with?(TOKEN_PREFIX) ? api_token(request) : nil
      # An embed token gets tickets and reads nothing itself.
      return coded("This key only opens the dashboard inside a CMS", "token_embed_only", 403) if !token.nil? && token["scope"] == "embed"
      if !token.nil? && token["scope"] == "manage" && manage_path(method, path)
        asked = url.search_params.get("site")
        site_match = path.match(%r{\A/api/sites/([^/]+)\z})
        if (!asked.nil? && asked != "" && asked != token["site"]) || (!site_match.nil? && decode(site_match[1]) != token["site"])
          return coded("Unknown site", "unknown_site", 404)
        end

        if !site_match.nil? && json?(request)
          # Where a site lives stays with its owner: a hub may rename it, never move it.
          parsed, body = Js.parse_json(request.text)
          if parsed && Js.truthy?(body) && Js.object?(body) && !Js.get(body, "hostnames").equal?(UNDEFINED)
            return coded("A connected hub cannot change a site's domains", "hub_domains", 403)
          end
        end
        url = Http::Url.new(url.href)
        query = url.search_params
        query.set("site", token["site"].to_s)
        url.search_params = query
        @managed[request] = token
      end
      # A token this install made that tries a change it may not make is known, just not allowed, as for a viewer.
      if !token.nil? && !@managed.key?(request) && !%w[GET HEAD OPTIONS].include?(method)
        return token["scope"] == "manage" ? coded("A manage token changes only its own site's settings", "token_manage_only", 403) : coded("API tokens can only read", "token_read_only", 403)
      end

      # A page another site served to an AI agent, reported by a CMS plugin.
      return observe_api(request) if path == "/api/observe" && method == "POST"

      # GET too: Vercel Cron calls with GET and the cron secret as a bearer token.
      if path == "/api/check" && %w[POST GET].include?(method)
        given = bearer(request)
        allowed = (!@cron_secret.nil? && @cron_secret != "" && given != "" && constant_time_equal(given, @cron_secret)) || can_read(request) == true
        return coded("Unauthorized", "unauthorized", 401) unless allowed

        return json(rl.check)
      end

      # A site counted by another install is read there. Its settings change there too,
      # through this server when the install gave a manage token, and only by an owner here.
      asked = url.search_params.get("site")
      connected = !asked.nil? && asked != "" ? rl.remote(asked) : nil
      if !connected.nil? && connected["scope"] == "manage" && manage_path(method, path) && !(method == "GET" && shared_path?(path))
        access = can_read(request)
        return denied(access) if access != true

        rl.forget_remote_info(asked) if method != "GET"
        return pass_through(connected, path, url, request)
      end
      if !connected.nil? && !(method == "GET" && (shared_path?(path) || path == "/api/links"))
        return coded("This site is counted by its own Runlight. Connect it again from its settings to change it from here.", "site_remote", 400)
      end

      # Visit history from Umami: list the account's websites, then import one a step at a time.
      if ["/api/import/umami/websites", "/api/import/umami/visits"].include?(path) && method == "POST"
        access = can_read(request)
        return denied(access) if access != true

        body = read_json(request)
        return body if body.is_a?(Http::Response)

        creds = credentials(Js.get(body, "credentials"))
        begin
          return json({ "websites" => Importers::Visits.umami_websites(creds, rl.fetcher) }) if path == "/api/import/umami/websites"

          rl.init
          site = query_site(url)
          return site if site.is_a?(Http::Response)

          cursor = Js.get(body, "cursor")
          return json(Importers::Visits.import_umami_visits(rl, site["id"], creds, text(body, "website"), cursor.is_a?(String) ? cursor : nil))
        rescue Importers::ImportError => e
          return refused(e, "import_failed")
        end
      end

      # Visit history from a CSV file, a batch at a time.
      if path == "/api/import/csv/visits" && method == "POST"
        access = can_read(request)
        return denied(access) if access != true

        body = read_json(request)
        return body if body.is_a?(Http::Response)

        rl.init
        site = query_site(url)
        return site if site.is_a?(Http::Response)

        begin
          return json(Importers::Visits.import_csv_visits(rl, site["id"], plain(Js.get(body, "rows"))))
        rescue Importers::ImportError => e
          return refused(e, "import_failed")
        end
      end

      # Each site's key for CMS plugins reporting AI agent fetches: made on first ask, replaced on request.
      if (path == "/api/observe-key" && method == "GET") || (path == "/api/observe-key/new" && method == "POST")
        access = can_read(request)
        return denied(access) if access != true

        rl.init
        site = query_site(url)
        return site if site.is_a?(Http::Response)

        name = "observe-key:#{site["id"]}"
        key = path.end_with?("/new") ? nil : store.setting(name)
        if key.nil? || key == ""
          key = "rlo_#{Hashing.random_id(20)}"
          store.set_setting(name, key)
        end
        return json({ "key" => key })
      end

      # Making, changing, and deleting funnels; reading them is with the other reports.
      if (path == "/api/funnels" && method == "POST") || (path.match?(%r{\A/api/funnels/[a-f0-9]{24}\z}) && %w[PATCH DELETE].include?(method))
        access = can_read(request)
        return denied(access) if access != true

        rl.init
        site = query_site(url)
        return site if site.is_a?(Http::Response)

        existing = store.funnels(site["id"])
        id = path == "/api/funnels" ? nil : path["/api/funnels/".length..]
        return coded("Unknown funnel", "unknown_funnel", 404) if !id.nil? && existing.none? { |f| f["id"] == id }

        if method == "DELETE"
          store.delete_funnel(id)
          return json({ "ok" => true })
        end
        body = read_json(request)
        return body if body.is_a?(Http::Response)

        begin
          funnel = Funnels.funnel_from(body, site["id"], existing, rl.now, id)
          store.save_funnel(funnel)
          return json({ "funnel" => funnel }, id.nil? ? 201 : 200)
        rescue FunnelError => e
          return refused(e, "funnel_invalid")
        end
      end

      # The assistant: an owner sets it up; anyone signed in to the dashboard can ask it.
      if path == "/api/assistant"
        own = can_read(request)
        # A member uses the assistant like anyone else, but its settings are for owners and admins.
        owner = own == true && !@members.key?(request)
        if method == "GET"
          access = reader(request)
          return denied(access) if access == false || access == "unconfigured"
          # Only people at the dashboard, never an API token or a share, so nobody spends the owner's AI credit from outside.
          return coded("Only the dashboard can use the assistant", "assistant_dashboard", 403) if access.is_a?(Hash) && access["id"] != ""

          rl.init
          settings = rl.assistant_settings
          return json({ "configured" => !settings.nil? }) unless owner

          known = settings || {}
          return json({
            "configured" => !settings.nil?,
            "viewerDaily" => viewer_daily,
            "provider" => known["provider"] || "",
            "model" => known["model"] || "",
            "baseUrl" => known["baseUrl"] || "",
            "keySaved" => Js.truthy?(known["key"]),
            "encrypted" => !rl.secret.nil?,
            "providers" => Assistant::PROVIDERS,
          })
        end
        return own == true ? coded("Only an owner or admin can change this", "admin_only", 403) : denied(own) unless owner

        rl.init
        if method == "DELETE"
          rl.save_assistant_settings(nil)
          return json({ "ok" => true })
        end
        if method == "PUT"
          body = read_json(request)
          return body if body.is_a?(Http::Response)

          begin
            rl.save_assistant_settings(plain(body))
            return json({ "ok" => true })
          rescue RangeError => e
            return refused(e, "assistant_invalid")
          end
        end
        return coded("Method not allowed", "method_not_allowed", 405)
      end
      # How many questions each viewer may ask a day; 0 keeps the assistant for owners.
      if path == "/api/assistant/limits" && method == "PUT"
        access = can_read(request)
        return denied(access) if access != true

        rl.init
        body = read_json(request)
        return body if body.is_a?(Http::Response)

        daily = Js.number(Js.get(body, "viewerDaily"))
        integral = daily.is_a?(Integer) || (daily.is_a?(Float) && daily.finite? && daily == daily.floor)
        return coded("Use a whole number from 0 to 1,000", "assistant_limit", 400) if !integral || daily.negative? || daily > 1000

        store.set_setting("assistant-viewer-daily", Js.string(daily))
        return json({ "viewerDaily" => daily })
      end
      # The models a service offers, for the setup form's dropdown. The key can be the one already saved.
      if path == "/api/assistant/models" && method == "POST"
        access = can_read(request)
        return denied(access) if access != true

        rl.init
        body = read_json(request)
        return body if body.is_a?(Http::Response)

        provider = text(body, "provider")
        saved = rl.assistant_settings
        base_url = Js.trim(text(body, "baseUrl")).sub(%r{/+\z}, "")
        # The saved key only for the address it was saved with.
        same_address = !saved.nil? && saved["provider"] == provider && (Js.truthy?(saved["baseUrl"]) ? saved["baseUrl"] : "") == base_url
        key = Js.trim(text(body, "key"))
        key = same_address ? saved["key"].to_s : "" if key == ""
        begin
          return json({ "models" => Assistant.list_models({ "provider" => provider, "baseUrl" => Js.trim(text(body, "baseUrl")), "key" => key }, rl.fetcher) })
        rescue AssistantError => e
          return refused(e, "assistant_failed")
        end
      end
      return chat(request, url) if path == "/api/assistant/chat" && method == "POST"

      # Only the owner manages tokens: an API token cannot make or revoke one.
      if path == "/api/tokens" || path.start_with?("/api/tokens/")
        access = can_read(request)
        return denied(access) if access != true

        return tokens_api(request, path)
      end

      if !connected.nil? && path == "/api/links"
        access = reader(request)
        return denied(access) if access == false || access == "unconfigured"
        # A token limited to one site reads only that site's links, here as everywhere else.
        return coded("Unknown site", "unknown_site", 404) if access.is_a?(Hash) && access["site"] != "" && access["site"] != asked

        return pass_through(connected, path, url)
      end

      # An API token, or someone signed in to read, may list links and see each one's clicks, but not change them.
      if method == "GET" && (path == "/api/links" || path.match?(%r{\A/api/links/[a-f0-9]+\z}))
        access = reader(request)
        return denied(access) if access == false || access == "unconfigured"

        if access.is_a?(Hash)
          rl.init
          site = rl.site(url.search_params.get("site") || (access["site"] != "" ? access["site"] : nil))
          return coded("Unknown site", "unknown_site", 404) if site.nil? || (access["site"] != "" && site["id"] != access["site"])

          scoped = Http::Url.new(url.href)
          query = scoped.search_params
          query.set("site", site["id"])
          scoped.search_params = query
          return links_api(request, path, scoped)
        end
      end

      if path == "/api/links" || path.start_with?("/api/links/") || path == "/api/link-domains" || path.start_with?("/api/link-domains/")
        access = can_read(request)
        return denied(access) if access != true

        return links_api(request, path, url)
      end

      if path == "/api/mail" || path == "/api/mail/test" || path == "/api/reports" || path.start_with?("/api/reports/")
        access = can_read(request)
        return denied(access) if access != true

        return mail_api(request, path, url)
      end

      # A ticket for the element picker, naming the dashboard it may send its choice to. A hub asks the install
      # that serves the site's script, with its own origin, since that install signs what the script will trust.
      if path == "/api/pick" && method == "POST"
        access = can_read(request)
        return denied(access) if access != true

        rl.init
        site = query_site(url)
        return site if site.is_a?(Http::Response)

        body = read_json(request)
        return body if body.is_a?(Http::Response)

        origin = text(body, "origin")
        return coded("Send the dashboard's origin, such as https://stats.example.com", "pick_origin", 400) unless origin?(origin)

        # A hub's ticket only ever sends to the hub it connected from, never to an origin it names now.
        hub = @managed[request]
        if !hub.nil? && store.setting("token-origin:#{hub["id"]}") != origin
          return coded("This hub's address is not the one it connected from. Connect the site again from here.", "pick_hub", 403)
        end

        return json({ "ticket" => pick_ticket(origin, site["id"]) })
      end

      if (path == "/api/goals" && method == "POST") || (path.match?(%r{\A/api/goals/[^/]+\z}) && %w[PATCH DELETE].include?(method))
        access = can_read(request)
        return denied(access) if access != true

        return goal_writes(request, path, url)
      end

      if path == "/api/shares" || path.start_with?("/api/shares/")
        access = can_read(request)
        return denied(access) if access != true

        return shares_api(request, path, url)
      end

      # Adding and deleting sites, when they are managed in the dashboard.
      if path == "/api/sites" && method == "POST"
        access = can_read(request)
        return denied(access) if access != true

        body = read_json(request)
        return body if body.is_a?(Http::Response)

        begin
          return json({ "site" => rl.add_site(plain(body)) }, 201)
        rescue RangeError => e
          return refused(e, "site_invalid")
        end
      end

      site_match = path.match(%r{\A/api/sites/([^/]+)\z})
      if site_match && method == "DELETE"
        access = can_read(request)
        return denied(access) if access != true

        begin
          rl.delete_site(decode(site_match[1]))
          return json({ "ok" => true })
        rescue RangeError => e
          return e.message == "Unknown site" ? coded(e.message, "unknown_site", 404) : refused(e, "site_invalid")
        end
      end
      return patch_site(request, site_match[1], url) if site_match && method == "PATCH"

      return coded("Method not allowed", "method_not_allowed", 405) if method != "GET"

      reports(request, path, url)
    end

    def observe_api(request)
      rl = @rl
      given = bearer(request)
      # The install-wide key and the owner's access can report for any site.
      any_site = (!@observe_key.nil? && @observe_key != "" && given != "" && constant_time_equal(given, @observe_key)) || can_read(request) == true
      return coded("Unauthorized", "unauthorized", 401) if !any_site && given == ""

      body = read_json(request)
      return body if body.is_a?(Http::Response)

      # One fetch as { url, userAgent, at? }, or up to 500 as { fetches: [...] } from a log reader.
      fetches = Js.get(body, "fetches")
      batch = fetches.is_a?(Array)
      list = batch ? fetches : [body]
      return coded("Send at most 500 fetches at a time", "observe_many", 413) if list.length > 500

      pages = []
      list.each do |item|
        read = ->(key) { item.is_a?(Hash) ? Js.get(item, key) : UNDEFINED }
        raw = read.call("url")
        page = Http::Url.parse(raw.nil? || raw.equal?(UNDEFINED) ? "" : Js.string(raw))
        return coded("Send the page's url", "observe_url", 400) if page.nil? || (page.protocol != "https:" && page.protocol != "http:")

        at = read.call("at")
        whenever = if at.is_a?(Integer) || at.is_a?(Float)
                     at
                   elsif at.is_a?(String)
                     Importers::Client.parse_date(at)
                   end
        agent = read.call("userAgent")
        pages << {
          "page" => page,
          "userAgent" => Js.slice(agent.nil? || agent.equal?(UNDEFINED) ? "" : Js.string(agent), 0, 500),
          "at" => !whenever.nil? && whenever.to_f.finite? ? whenever : nil,
        }
      end
      rl.init
      keep = pages
      unless any_site
        # A site's own key reports only pages on that site's domains. Pages elsewhere in a batch (another
        # host in the same log, say) are skipped, not a reason to refuse the rest.
        key_site = nil
        sites.each do |site|
          key = store.setting("observe-key:#{site["id"]}")
          key_site = site["id"] if !key.nil? && key != "" && constant_time_equal(given, key)
        end
        return coded("Unauthorized", "unauthorized", 401) if key_site.nil?

        keep = pages.select { |p| rl.site_for(p["page"].hostname)&.[]("id") == key_site }
        # A single report for another site's page is a misconfigured plugin, which should hear about it.
        return coded("Unauthorized", "unauthorized", 401) if !batch && keep.empty?
      end
      recorded = 0
      keep.each do |p|
        recorded += 1 if rl.observe(Http::Request.new(p["page"].href, method: "GET", headers: { "user-agent" => p["userAgent"] }), p["at"])
      end
      # A single report, as the CMS plugins send, needs no answer; a batch learns what was kept.
      return Http::Response.new("", status: 204) unless batch

      json({ "recorded" => recorded, "skipped" => pages.length - recorded })
    end

    def chat(request, url)
      rl = @rl
      access = reader(request)
      return denied(access) if access == false || access == "unconfigured"
      return coded("Only the dashboard can use the assistant", "assistant_dashboard", 403) if access.is_a?(Hash) && access["id"] != ""
      return coded("Not available on a shared dashboard", "share_not_available", 403) unless request.headers.get(SHARE_HEADER).nil?

      rl.init
      settings = rl.assistant_settings
      if settings.nil?
        return coded("The assistant is not set up yet. An owner can set it up in Settings, AI Assistant.", "assistant_unset", 400)
      end

      body = read_json(request)
      return body if body.is_a?(Http::Response)

      site_id = text(body, "site")
      site = rl.site(site_id != "" ? site_id : nil)
      return coded("Unknown site", "unknown_site", 404) if site.nil?

      messages = []
      given = Js.get(body, "messages")
      if given.is_a?(Array)
        given.each do |m|
          next unless m.is_a?(Hash) && %w[user assistant].include?(Js.get(m, "role")) && Js.get(m, "content").is_a?(String)

          messages << { "role" => m["role"], "content" => m["content"] }
        end
      end
      return coded("Ask a question", "question_needed", 400) if messages.empty? || messages[-1]["role"] != "user"

      owner = access == true
      who = @account_of&.call(request)
      turn = ask_turn(who || (owner ? "owner" : "viewer"), owner)
      return turn if turn.is_a?(Http::Response)

      language = Js.string(Js.get(body, "language"))
      begin
        answer = Assistant.chat(
          settings,
          messages,
          {
            "site" => { "id" => site["id"], "name" => site["name"], "timezone" => site["timezone"] },
            "today" => Dates.local_date(rl.now, site["timezone"]),
            "view" => Js.slice(text(body, "view", "the last 30 days"), 0, 200),
            "language" => language.match?(/\A[a-z]{2}\z/) ? language : "en",
          },
          # Each tool reads the HTTP API with the asker's own headers, as the MCP server does.
          read_api(request, url, site["id"]),
          rl.fetcher,
          -> { rl.now },
        )
        json(answer)
      rescue AssistantError => e
        refused(e, "assistant_failed", 502)
      ensure
        turn.call
      end
    end

    def patch_site(request, raw_id, url)
      rl = @rl
      access = can_read(request)
      return denied(access) if access != true

      # A form posted from another site cannot carry this content type without CORS.
      body = read_json(request)
      return body if body.is_a?(Http::Response)

      rl.init
      # Every field is checked before any changes, since a shorter retention deletes visits at once.
      if given?(body, "name")
        name = Js.trim(Js.string(Js.get(body, "name")))
        return coded("A site name is 1 to 80 characters", "site_name", 400) unless name != "" && Js.length(name) <= 80
      end
      if given?(body, "timezone") && !Dates.timezone?(Js.string(Js.get(body, "timezone")))
        timezone = Js.string(Js.get(body, "timezone"))
        return coded("Unknown timezone \"#{timezone}\"", "unknown_timezone", 400, { "timezone" => timezone })
      end
      retention = Js.get(body, "retentionMonths")
      if !retention.equal?(UNDEFINED) && !retention.nil? && !RETENTION_MONTHS.include?(Js.number(retention))
        months = RETENTION_MONTHS.join(", ")
        return coded("Keep visits for #{months} months, or forever", "retention_bad", 400, { "months" => months })
      end
      begin
        id = decode(raw_id)
        remote = rl.remote(id)
        # How long a connected site keeps visits, and the timezone its days follow, are the install's
        # settings: this server passes them on, and changes its own row only once the install took them.
        forward = {}
        forward["retentionMonths"] = retention unless retention.equal?(UNDEFINED)
        if given?(body, "timezone") && Js.string(Js.get(body, "timezone")) != rl.site(id)&.[]("timezone")
          forward["timezone"] = Js.string(Js.get(body, "timezone"))
        end
        if !remote.nil? && !forward.empty?
          return coded("Connect this site again to change it from here", "connect_again", 400) if remote["scope"] != "manage"

          answer = pass_through(
            remote,
            "/api/sites/#{Js.encode_uri_component(remote["site"].to_s)}",
            Http::Url.new(url.href),
            Http::Request.new(request.url, method: "PATCH", headers: { "content-type" => "application/json" }, body: Json.encode(forward)),
          )
          return answer unless answer.ok?

          rl.forget_remote_info(id)
        elsif remote.nil? && !retention.equal?(UNDEFINED)
          rl.set_retention(id, retention.nil? ? nil : Js.number(retention))
        end
        patch = {}
        patch["name"] = Js.string(Js.get(body, "name")) if given?(body, "name")
        patch["timezone"] = Js.string(Js.get(body, "timezone")) if given?(body, "timezone")
        patch["hostnames"] = plain(Js.get(body, "hostnames")) if given?(body, "hostnames") && rl.managed_sites
        site = rl.update_site(decode(raw_id), patch).dup
        # A connected site answers as the list shows it, so the dashboard keeps its install and domains.
        unless remote.nil?
          site["remote"] = remote["url"]
          site["remoteSite"] = remote["site"]
          site["manage"] = remote["scope"] == "manage"
          site["hostnames"] = remote["hostnames"]
        end
        json({ "site" => site })
      rescue RangeError => e
        e.message == "Unknown site" ? coded(e.message, "unknown_site", 404) : refused(e, "site_invalid")
      end
    end

    # The reads: sites, stats, and every report, for the owner, a token, a viewer, or a share.
    def reports(request, path, url)
      rl = @rl
      store = self.store
      params = url.search_params
      rl.init
      # A shared dashboard sees exactly what its visitors see, even for someone signed in.
      share_id = request.headers.get(SHARE_HEADER)
      shared = nil
      # The one site a share or a site's API token may read; nil for every site.
      only = nil
      embed = request.headers.get(EMBED_HEADER)
      if share_id.nil? && !embed.nil?
        token = embed_reader(embed)
        return coded("This dashboard has expired. Reload the page to open it again.", "embed_expired", 401) if token.nil?

        # An embedded dashboard sees what a share link of its token's site shows.
        shared = { "id" => "", "site" => token["site"], "name" => "", "createdAt" => 0 }
        only = token["site"]
      elsif share_id.nil?
        access = reader(request)
        return denied(access) if access == false || access == "unconfigured"

        if access != true
          return coded("API tokens can only read", "token_read_only", 403) unless shared_path?(path)

          only = access["site"] != "" ? access["site"] : nil
        end
      else
        shared = share_id.match?(SHARE_ID) ? store.share_by_id(share_id) : nil
        return coded("This share link no longer works", "share_gone", 404) if shared.nil?
        return coded("Not available on a shared dashboard", "share_not_available", 403) unless shared_path?(path)

        only = shared["site"]
      end

      if path == "/api/sites"
        visible = only.nil? ? sites : sites.select { |s| s["id"] == only }
        rows = visible.map do |site|
          remote = rl.remote(site["id"])
          row = site.dup
          # A connected install's address, so the dashboard can say where the site is counted.
          # Its domains as the install reported them, for the goal picker; tracker hits never match them here.
          if !remote.nil? && shared.nil?
            row["remote"] = remote["url"]
            row["remoteSite"] = remote["site"]
            row["manage"] = remote["scope"] == "manage"
            row["hostnames"] = remote["hostnames"]
          end
          # Hostnames say where the site lives; a share shows only its name.
          row["hostnames"] = [] unless shared.nil?
          row["lastSeen"] = remote.nil? ? store.last_seen(site["id"]) : rl.remote_last_seen(site["id"])
          # Left out for a connected install that cannot be reached, so nobody reads "forever" by mistake.
          row["retentionMonths"] = remote.nil? ? rl.retention(site["id"]) : field(rl.remote_info(site["id"]), "retentionMonths") if shared.nil?
          # Whether a connected install still takes this server's token, so the dashboard offers to connect it
          # again only when it no longer does.
          row["connection"] = field(rl.remote_info(site["id"]), "connection") if !remote.nil? && shared.nil?
          row
        end
        # A share never learns how the install is run.
        return json(shared.nil? ? { "sites" => rows, "managed" => rl.managed_sites } : { "sites" => rows })
      end

      site = if !shared.nil?
               rl.site(shared["site"])
             elsif !only.nil?
               rl.site(params.get("site") || only)
             else
               query_site(url)
             end
      return site if site.is_a?(Http::Response)
      return coded("Unknown site", "unknown_site", 404) if site.nil? || (!only.nil? && site["id"] != only)

      remote = rl.remote(site["id"])
      return pass_through(remote, path, url, request) unless remote.nil?

      if path == "/api/icon"
        host = site["hostnames"][0]
        # Only a site's own domain, never the request's Host header, which a caller can write.
        icon = !host.nil? && host != "" ? Icon.fetch_icon("https://#{host}", rl.now, rl.fetcher) : nil
        return coded("No icon", "icon_none", 404, nil, { "cache-control" => "private, max-age=3600" }) if icon.nil?

        return Http::Response.new(icon["body"], status: 200, headers: {
          "content-type" => icon["type"],
          "cache-control" => "private, max-age=86400",
          # An SVG served from this origin must never run script.
          "content-security-policy" => "default-src 'none'; style-src 'unsafe-inline'; sandbox",
          "x-content-type-options" => "nosniff",
        })
      end

      return json(store.realtime(site["id"], rl.now)) if path == "/api/realtime"

      read = read_query(url, site)
      return read if read.is_a?(Http::Response)

      query = read["query"]
      range = read["range"]
      compared = read["compared"]
      range_out = { "from" => range["fromDate"], "to" => range["toDate"], "interval" => range["interval"], "timezone" => site["timezone"] }
      compare_out = compared.nil? ? UNDEFINED : { "from" => compared["fromDate"], "to" => compared["toDate"] }
      before = compared.nil? ? nil : { "from" => compared["from"], "to" => compared["to"] }.merge(query) { |_key, mine, _theirs| mine }

      if path == "/api/stats"
        stats = store.stats(query)
        previous = before.nil? ? UNDEFINED : store.stats(before)
        return json({ "site" => site["id"], "range" => range_out, "compare" => compare_out, "stats" => stats, "previous" => previous })
      end

      if path == "/api/goals"
        goals = store.goals(site["id"])
        visitors = store.visitors(query)
        previous_visitors = before.nil? ? 0 : store.visitors(before)
        # Every goal in one pass for the range, and one more for the comparison.
        now_all = store.goal_totals_all(query, goals)
        before_all = before.nil? ? nil : store.goal_totals_all(before, goals)
        rows = goals.map do |goal|
          now = now_all[goal["id"]]
          from_then = before_all&.[](goal["id"])
          row = goal.merge(now)
          row["rate"] = Js.truthy?(visitors) ? now["visitors"].fdiv(visitors) : 0
          row["previous"] = if from_then.nil?
                              UNDEFINED
                            else
                              from_then.merge("rate" => Js.truthy?(previous_visitors) ? from_then["visitors"].fdiv(previous_visitors) : 0)
                            end
          row
        end
        return json({ "site" => site["id"], "range" => range_out, "compare" => compare_out, "visitors" => visitors, "goals" => rows })
      end

      if (goal_match = path.match(%r{\A/api/goals/([a-f0-9]{24})\z}))
        goal = store.goal_by_id(goal_match[1])
        return coded("Unknown goal", "unknown_goal", 404) if goal.nil? || goal["site"] != site["id"]

        visitors = store.visitors(query)
        totals = store.goal_totals(query, goal).dup
        series = store.goal_series(query, goal, Dates.buckets(range, site["timezone"]))
        sources = store.goal_breakdown(query, goal, "source")
        channels = store.goal_breakdown(query, goal, "channel")
        pages = store.goal_breakdown(query, goal, "path")
        totals["rate"] = Js.truthy?(visitors) ? totals["visitors"].fdiv(visitors) : 0
        return json({ "site" => site["id"], "range" => range_out, "goal" => goal, "totals" => totals, "series" => series,
                      "sources" => sources, "channels" => channels, "pages" => pages })
      end

      if path == "/api/series"
        points = store.series(query, Dates.buckets(range, site["timezone"]))
        # Comparison points line up with the main ones by position.
        previous = compared.nil? ? UNDEFINED : store.series(query, Dates.buckets(compared, site["timezone"])).first(points.length)
        return json({ "site" => site["id"], "range" => range_out, "compare" => compare_out, "points" => points, "previous" => previous })
      end

      if path == "/api/rhythm"
        # Visits per weekday and hour, plus each cell's details for its tooltip.
        # Visitors are summed over the hours folded into a cell, so someone who
        # came on two Tuesdays at 2pm counts twice there.
        grid = Array.new(7) { Array.new(24, 0) }
        cells = Array.new(7) { Array.new(24) { { "visits" => 0, "visitors" => 0, "pageviews" => 0, "bounced" => 0 } } }
        store.hourly(query).each do |row|
          weekday, h = Dates.local_weekday_hour((row["quarter"] * 900_000).to_i, site["timezone"])
          grid[weekday][h] += row["visits"]
          cell = cells[weekday][h]
          cell["visits"] += row["visits"]
          cell["visitors"] += row["visitors"]
          cell["pageviews"] += row["pageviews"]
          cell["bounced"] += row["bounced"]
        end
        details = cells.map do |day|
          day.map do |c|
            { "visits" => c["visits"], "visitors" => c["visitors"], "pageviews" => c["pageviews"],
              "bounceRate" => Js.truthy?(c["visits"]) ? c["bounced"].fdiv(c["visits"]) : 0 }
          end
        end
        return json({ "site" => site["id"], "range" => range_out, "grid" => grid, "cells" => details })
      end

      if path == "/api/journeys"
        through = (params.get("through") || "").match(/\A(\d+):(.+)\z/)
        # Journeys reads the newest visits up to a cap; say when it was reached.
        read = store.journey_pages(query, Journeys::PAGES_PER_VISIT)
        options = { "steps" => Js.number(params.get("steps") || 5) }
        options["start"] = params.get("start") if Js.truthy?(params.get("start"))
        options["end"] = params.get("end") if Js.truthy?(params.get("end"))
        options["through"] = { "step" => Js.number(through[1]), "value" => through[2] } unless through.nil?
        answer = { "site" => site["id"], "range" => range_out }.merge(Journeys.journeys(read["rows"], options)) { |_key, mine, _theirs| mine }
        answer["sampled"] = Store::SqlStore::JOURNEY_VISITS if read["sampled"]
        return json(answer)
      end

      if path == "/api/funnels"
        # One funnel at a time, so a page of funnels never takes every database connection at once.
        rows = store.funnels(site["id"]).map do |funnel|
          counts = store.funnel_counts(query, funnel)
          funnel.merge("steps" => funnel["steps"].each_with_index.map { |step, i| step.merge("visits" => counts[i]) })
        end
        return json({ "site" => site["id"], "range" => range_out, "funnels" => rows })
      end

      if path == "/api/event-props"
        event = params.get("event") || ""
        return coded("Name the event", "event_needed", 400) if event == ""

        keys = store.event_prop_keys(query, event)
        asked = params.get("key")
        # A property name goes into a JSON path on SQLite, so quotes and backslashes are refused.
        return coded("Bad property name", "property_bad", 400) if !asked.nil? && !asked.match?(/\A[^"\\]{1,64}\z/)

        key = asked || keys.first&.[]("key")
        count = limit(params.get("limit"), 100)
        rows = !key.nil? && key != "" ? store.event_prop_values(query, event, key, whole(count)) : []
        return json({ "site" => site["id"], "range" => range_out, "event" => event, "keys" => keys, "key" => key, "rows" => rows })
      end

      if path == "/api/breakdown"
        dimension = params.get("dimension") || ""
        return coded("Unknown dimension \"#{dimension}\"", "unknown_dimension", 400, { "dimension" => dimension }) unless Query.dimension?(dimension)

        count = limit(params.get("limit"), 10)
        page = Js.number(params.get("page"))
        page = [1, (page.is_a?(Float) && page.nan?) || page.zero? ? 1 : page].max
        rows = store.breakdown(query, dimension, whole(count), whole((page - 1) * count))
        if params.get("format") == "csv"
          return download("#{site["id"]}-#{dimension}-#{range["fromDate"]}-#{range["toDate"]}.csv",
                          rows_csv(rows, { "timezone" => site["timezone"], "dimension" => dimension }), "text/csv; charset=utf-8")
        end

        return json({ "site" => site["id"], "range" => range_out, "dimension" => dimension, "rows" => rows })
      end

      # Everything the dashboard shows for a view, as a ZIP of CSV files.
      if path == "/api/export"
        files = []
        stats = store.stats(query)
        previous = before.nil? ? nil : store.stats(before)
        now = sheet_row(stats, { "timezone" => site["timezone"] })
        from_then = previous.nil? ? nil : sheet_row(previous, { "timezone" => site["timezone"] })
        overview = now.map { |m, value| from_then.nil? ? [m.to_s, value] : [m.to_s, value, from_then[m]] }
        files << { "name" => "overview.csv", "text" => Zip.csv(from_then.nil? ? %w[metric value] : %w[metric value previous], overview) }
        points = store.series(query, Dates.buckets(range, site["timezone"]))
        files << { "name" => "over-time.csv", "text" => rows_csv(points, { "timezone" => site["timezone"], "interval" => range["interval"] }) }
        Query::DIMENSIONS.each do |dimension|
          rows = store.breakdown(query, dimension, 1000, 0)
          files << { "name" => "#{dimension}.csv", "text" => rows_csv(rows, { "timezone" => site["timezone"], "dimension" => dimension }) } unless rows.empty?
        end
        goals = store.goals(site["id"])
        unless goals.empty?
          totals = store.goal_totals_all(query, goals)
          files << {
            "name" => "goals.csv",
            "text" => Zip.csv(%w[goal conversions visitors revenue currency], goals.map do |g|
              [g["name"], totals[g["id"]]["conversions"], totals[g["id"]]["visitors"], totals[g["id"]]["revenue"], g["currency"]]
            end),
          }
        end
        return download("#{site["id"]}-#{range["fromDate"]}-#{range["toDate"]}.zip", Zip.zip(files, rl.now), "application/zip")
      end

      coded("Not found", "not_found", 404)
    end

    def route(request, path, url, context)
      rl = @rl
      base = @base
      method = request.method
      # Checked before any route, so a connected site's pass-through to its install is held to it too.
      if admin_only?(path, method) && can_read(request) == true && @members.key?(request)
        return coded("Only an owner or admin can change this", "admin_only", 403)
      end

      # Sign-in, setup, invites, and the Account and People APIs, and the dashboard sends anyone signed out to sign in.
      unless @web.nil?
        answered = @web.handle(request, path, context)
        return answered unless answered.nil?
      end
      if path == "/s.js" && method == "GET"
        script = tracker_script(url.search_params.get("site"))
        headers = {
          "content-type" => "application/javascript; charset=utf-8",
          # Short, so a new click goal reaches visitors within minutes; the etag makes rechecks cheap.
          "cache-control" => "public, max-age=300",
          "etag" => script["etag"],
        }
        return Http::Response.new("", status: 304, headers: headers) if request.headers.get("if-none-match") == script["etag"]

        return Http::Response.new(script["body"], status: 200, headers: headers)
      end

      if path == "/pick.js" && method == "GET"
        # The picker sends what it picked only to the dashboard its ticket names; without a good ticket it does nothing.
        # It also runs only on the pages of the site the ticket names.
        target = pick_target(url.search_params.get("runlight_ticket") || "")
        rl.init unless target.nil?
        hosts = target.nil? ? [] : rl.site(target["site"])&.[]("hostnames")
        script = replace_once(asset("picker.js"), PICK_TARGET_PLACEHOLDER, Json.encode(hosts.nil? || target.nil? ? "" : target["origin"]))
        script = replace_once(script, PICK_HOSTS_PLACEHOLDER, Json.encode(Json.encode(hosts || [])))
        return Http::Response.new(script, status: 200, headers: { "content-type" => "application/javascript; charset=utf-8", "cache-control" => "no-store" })
      end

      if path == "/assets/world.#{build_hash("worldHash")}.json" && method == "GET"
        return Http::Response.new(asset("world.json"), status: 200, headers: { "content-type" => "application/json; charset=utf-8", "cache-control" => "public, max-age=31536000, immutable" })
      end

      locale = path.match(%r{\A/assets/locale\.([a-z]{2,3})\.([a-f0-9]+)\.json\z})
      if locale && locale[2] == build_hash("localesHash") && Js.truthy?(locales[locale[1]]) && method == "GET"
        return Http::Response.new(locales[locale[1]], status: 200, headers: { "content-type" => "application/json; charset=utf-8", "cache-control" => "public, max-age=31536000, immutable" })
      end

      if path.start_with?("/assets/app.") && method == "GET"
        hash = build_hash("dashboardHash")
        found = if path == "/assets/app.#{hash}.js"
                  asset("dashboard.js")
                elsif path == "/assets/app.#{hash}.css"
                  asset("dashboard.css")
                end
        return coded("Not found", "not_found", 404) if found.nil?

        return Http::Response.new(found, status: 200, headers: {
          "content-type" => path.end_with?(".js") ? "application/javascript; charset=utf-8" : "text/css; charset=utf-8",
          "cache-control" => "public, max-age=31536000, immutable",
        })
      end

      if path == "/e"
        if method == "OPTIONS"
          return Http::Response.new("", status: 204, headers: { "access-control-allow-origin" => "*", "access-control-allow-methods" => "POST", "access-control-max-age" => "86400" })
        end
        return coded("Method not allowed", "method_not_allowed", 405) if method != "POST"

        begin
          rl.collect(request, context)
        rescue StandardError => e
          warn("Runlight: could not record an event #{e.full_message(highlight: false)}")
        end
        # The same answer whatever happened, so the endpoint reveals nothing.
        return Http::Response.new("", status: 202, headers: { "access-control-allow-origin" => "*" })
      end

      return api(request, path, url) if path == "/api" || path.start_with?("/api/")

      if path.start_with?("/oauth/") || oauth_document?(path)
        answer = OAuth.oauth_response(@oauth, request, path, url, context)
        return answer unless answer.nil?
      end

      if path == "/mcp"
        # No server-sent stream and no sessions: every message is one POST.
        return coded("Method not allowed", "method_not_allowed", 405, nil, { "allow" => "POST" }) if method != "POST"

        access = reader(request)
        if access == false || access == "unconfigured"
          refused = denied(access)
          # Points an OAuth client at the metadata that starts the sign-in.
          refused.headers.set("www-authenticate", "Bearer realm=\"runlight\", resource_metadata=\"#{OAuth.resource_metadata_url(url.origin, base)}\"")
          return refused
        end
        # Each tool reads the HTTP API with the caller's own headers, so it sees what they may.
        return Mcp.mcp_response(request, read_api(request, url))
      end

      if (unsubscribe = path.match(%r{\A/unsubscribe/([^/]+)/?\z})) && %w[GET POST].include?(method)
        return unsubscribe_page(request, unsubscribe[1])
      end

      # The dashboard inside a CMS's admin pages, opened with a ticket its plugin just got. Only the admin origin
      # the ticket names may frame it. A ticket used already or run out opens it with no session, so it says it
      # has expired and offers to reload the admin page; anything else is refused and never framed.
      if path == "/embed" && method == "GET"
        rl.init
        found = redeem_embed(url.search_params.get("ticket") || "")
        if found.nil?
          translator = Messages.translator(accepted_language(request))
          t = translator["t"]
          return small_page(translator["lang"], "<h1>#{escape_html(t.call("embed.goneTitle"))}</h1><p>#{escape_html(t.call("embed.gone"))}</p>", 404)
        end
        session = found["token"].nil? ? "" : embed_session(found["token"]["id"])
        page = dashboard(base, "", "", Js.truthy?(@options["geoCredit"]), false, "", { "session" => session, "origin" => found["origin"] })
        return Http::Response.new(page, status: session != "" ? 200 : 410, headers: {
          "content-type" => "text/html; charset=utf-8",
          "cache-control" => "no-store",
          "content-security-policy" => DASHBOARD_CSP.sub("frame-ancestors 'none'", "frame-ancestors #{found["origin"]}"),
          "referrer-policy" => "no-referrer",
          "x-robots-tag" => "noindex",
        })
      end

      if (share_page = path.match(%r{\A/share/([^/]+)/?\z})) && method == "GET"
        rl.init
        id = share_page[1]
        share = id.match?(SHARE_ID) ? store.share_by_id(id) : nil
        if share.nil?
          translator = Messages.translator(accepted_language(request))
          t = translator["t"]
          return small_page(translator["lang"], "<h1>#{escape_html(t.call("share.goneTitle"))}</h1><p>#{escape_html(t.call("share.gone"))}</p>", 404)
        end
        return Http::Response.new(dashboard(base, share["id"], "", Js.truthy?(@options["geoCredit"])), status: 200, headers: {
          "content-type" => "text/html; charset=utf-8",
          "cache-control" => "no-store",
          "content-security-policy" => DASHBOARD_CSP,
          "x-frame-options" => "DENY",
          # The share id is the key; never send it on to another site.
          "referrer-policy" => "no-referrer",
          "x-robots-tag" => "noindex",
        })
      end

      if (path == "/" || path == "") && method == "GET"
        given = url.search_params.get("token")
        if !given.nil? && given != "" && !@token.nil? && @token != "" && constant_time_equal(given, @token)
          query = url.search_params
          query.delete("token")
          url.search_params = query
          secure = url.protocol == "https:" ? "; Secure" : ""
          return Http::Response.new("", status: 303, headers: {
            "location" => "#{url.pathname}#{url.search}",
            "set-cookie" => "#{COOKIE}=#{cookie_value(@token)}; Path=#{base != "" ? base : "/"}; HttpOnly; SameSite=Lax; Max-Age=2592000#{secure}",
          })
        end
        # The page itself holds no data; the API it calls checks access and
        # the page explains how to sign in when it is refused.
        return Http::Response.new(dashboard(base, "", @sign_out || "", Js.truthy?(@options["geoCredit"]), !@web.nil?, @sign_in || ""), status: 200, headers: {
          "content-type" => "text/html; charset=utf-8",
          "cache-control" => "no-store",
          "content-security-policy" => DASHBOARD_CSP,
          "x-frame-options" => "DENY",
          "referrer-policy" => "same-origin",
        })
      end

      coded("Not found", "not_found", 404)
    end
  end
end
