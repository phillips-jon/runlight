# frozen_string_literal: true

require "openssl"

module Runlight
  # OAuth for the MCP server, so apps that connect only through OAuth (the
  # Claude and ChatGPT web connectors) can reach it. Runlight is both the
  # resource and the authorization server:
  #
  # - /.well-known/oauth-protected-resource names the MCP endpoint and this server.
  # - /.well-known/oauth-authorization-server lists the endpoints below.
  # - POST /oauth/register lets a client register itself (public clients, no secret).
  # - /oauth/authorize asks the signed-in owner to allow the client, every site or one.
  # - POST /oauth/token swaps the one-time code, checked with PKCE, for a token.
  #
  # The token is an ordinary API token, so it appears in Settings, API and AI,
  # beside the others, and deleting it there disconnects the app. It reads
  # stats, or with the "manage" scope (asked for by a Runlight hub) it also
  # changes one site's settings.
  #
  # The context the routes pass is a Hash: "runlight", "base", "isOwner" (callable(request) giving a bool), and
  # optionally "signIn" (String), "isReader" (callable(request) giving a bool), "accountOf" (callable(request)
  # giving an account id or nil), and "tokenMade" (callable(token, by) giving a bool).
  module OAuth
    CODE_MS = 5 * 60_000
    # An app stored before client ids were signed, which never finished connecting within a day, is removed.
    UNUSED_CLIENT_MS = 86_400_000
    # Registrations one address may make a minute.
    REGISTRATIONS_PER_MINUTE = 10
    # The longest client id, which carries the app's name and redirect addresses.
    MAX_CLIENT_ID = 2048

    # Where the per-address count of registrations is kept. TypeScript keeps it in memory per install; here it
    # lives in the install's settings, keyed by a hash of the address, so every process shares it.
    REGISTRATIONS = "oauth-registrations"

    CORS = {
      "access-control-allow-origin" => "*",
      "access-control-allow-headers" => "authorization, content-type, mcp-protocol-version",
      "access-control-allow-methods" => "GET, POST, OPTIONS",
    }.freeze

    ESCAPES = { "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", '"' => "&quot;", "'" => "&#39;" }.freeze
    private_constant :REGISTRATIONS, :CORS, :ESCAPES

    module_function

    # base64url of SHA-256, as PKCE's S256 method compares.
    def s256(verifier)
      base64url(OpenSSL::Digest::SHA256.digest(verifier))
    end

    # The URL that a 401 from the MCP endpoint points clients at, to start OAuth.
    def resource_metadata_url(origin, base)
      "#{origin}#{base}/.well-known/oauth-protected-resource"
    end

    # Answers the OAuth paths, or returns nil for anything else. `path` is
    # relative to the routes' base; the two well-known documents are also answered
    # at the site's root (`/.well-known/...`) for clients that look there.
    #
    # context: {"ip" => the connection's address}, optional.
    def oauth_response(ctx, request, path, url, context = {})
      runlight = ctx["runlight"]
      base = ctx["base"].to_s
      issuer = "#{url.origin}#{base}"
      known = path
      if request.method == "OPTIONS" &&
         (known.start_with?("/.well-known/oauth-") || known.start_with?("/.well-known/openid-configuration") || path.start_with?("/oauth/"))
        return Http::Response.new("", status: 204, headers: CORS)
      end

      if known.start_with?("/.well-known/oauth-protected-resource")
        return json({ "resource" => "#{issuer}/mcp", "authorization_servers" => [issuer], "scopes_supported" => %w[read manage], "bearer_methods_supported" => ["header"] })
      end
      if known.start_with?("/.well-known/oauth-authorization-server") || known.start_with?("/.well-known/openid-configuration")
        return json({
          "issuer" => issuer,
          "authorization_endpoint" => "#{issuer}/oauth/authorize",
          "token_endpoint" => "#{issuer}/oauth/token",
          "registration_endpoint" => "#{issuer}/oauth/register",
          "response_types_supported" => ["code"],
          "grant_types_supported" => ["authorization_code"],
          "code_challenge_methods_supported" => ["S256"],
          "token_endpoint_auth_methods_supported" => ["none"],
          "scopes_supported" => %w[read manage],
        })
      end

      if path == "/oauth/register" && request.method == "POST"
        runlight.init
        unless allow_registration(runlight, runlight.client_ip(request, context))
          return oauth_error("invalid_client_metadata", "Too many registrations from this address. Wait a minute and try again.", 429)
        end

        parsed, body = Js.parse_json(request.text)
        body = nil unless parsed
        uris = !body.nil? && Js.object?(body) ? Js.get(body, "redirect_uris") : nil
        redirects = []
        redirects = uris.map { |u| Js.string(u) }.select { |u| allowed_redirect(u) }.first(10) if uris.is_a?(Array)
        return oauth_error("invalid_redirect_uri", "Register at least one https redirect address") if redirects.empty?

        name = !body.nil? && Js.object?(body) ? Js.get(body, "client_name") : nil
        return register(runlight, Js.string(name.nil? || name.equal?(UNDEFINED) ? "An app" : name), redirects)
      end

      if path == "/oauth/authorize" && (request.method == "GET" || request.method == "POST")
        runlight.init
        form = request.method == "POST" ? Http::SearchParams.new(request.text) : url.search_params
        client_id = form.get("client_id") || ""
        client = client_for(runlight, client_id)&.fetch("client", nil)
        redirect = form.get("redirect_uri") || ""
        # Without a known client and one of its own addresses there is nowhere safe to send an answer.
        if client.nil? || !Array(client["redirects"]).include?(redirect)
          return page("This app is not registered", "<p>Start connecting again from the app.</p>", 400)
        end

        back = lambda do |params|
          to = Http::Url.new(redirect)
          query = to.search_params
          params.each { |k, v| query.set(k, v) }
          state = form.get("state")
          query.set("state", state) if !state.nil? && state != ""
          to.search_params = query
          Http::Response.new("", status: 303, headers: { "location" => to.href, "cache-control" => "no-store" })
        end
        # Anyone can register an app with any address, so until an owner has allowed it once, a request
        # it got wrong ends on a page here rather than sending a visitor who is not signed in on to it.
        refuse = lambda do |params|
          if client.key?("usedAt") && Js.truthy?(client["usedAt"])
            back.call(params)
          else
            page("This app asked in a way Runlight does not support",
                 "<p>#{esc(client["name"].to_s)} sent #{esc(params["error_description"] || params["error"])}. Start connecting again from the app.</p>", 400)
          end
        end
        return refuse.call({ "error" => "unsupported_response_type" }) if form.get("response_type") != "code"

        challenge = form.get("code_challenge") || ""
        if form.get("code_challenge_method") != "S256" || !challenge.match?(/\A[A-Za-z0-9_-]{43,128}\z/)
          return refuse.call({ "error" => "invalid_request", "error_description" => "PKCE with S256 is required" })
        end

        manage = (form.get("scope") || "").split(/[#{Js::SPACE}]+/o).include?("manage")
        name = client["name"].to_s

        unless ctx["isOwner"].call(request)
          # Someone signed in who may only read would be sent to sign in again and again.
          if ctx["isReader"]&.call(request)
            return page("Ask an owner to connect this", "<p>You are signed in as a viewer, and only an owner of this Runlight can connect #{esc(name)}.</p>", 403)
          end

          # The site stays, since on the way in it only says which one to offer first.
          kept = Http::SearchParams.new
          form.each { |k, v| kept.append(k, v) if k != "decision" }
          here = "#{url.pathname}?#{kept}"
          unless ctx["signIn"].nil?
            return Http::Response.new("", status: 303, headers: { "location" => "#{ctx["signIn"]}?next=#{Js.encode_uri_component(here)}", "cache-control" => "no-store" })
          end

          home = base == "" ? "/" : base
          return page("Sign in first", "<p>Open your Runlight dashboard at <a href=\"#{esc(home)}\">#{esc("#{url.host}#{home}")}</a> and sign in, then connect #{esc(name)} again.</p>", 401)
        end

        if request.method == "GET"
          hidden = +""
          %w[response_type client_id redirect_uri code_challenge code_challenge_method state scope resource].each do |k|
            hidden << "<input type=\"hidden\" name=\"#{k}\" value=\"#{esc(form.get(k))}\">" unless form.get(k).nil?
          end
          # The app names itself, so the page also shows where the answer goes, which it cannot fake.
          sends_to = "<p class=\"note\">Allowing sends you back to <strong>#{esc(Http::Url.new(redirect).host)}</strong>. Only allow it if you started connecting there.</p>"
          sites = runlight.sites
          if manage
            # Changing settings is for one site at a time, so there is no "every site" here.
            wanted = form.get("site") || ""
            choices = +""
            sites.each do |s|
              next unless runlight.remote(s["id"]).nil?

              choices << "<option value=\"#{esc(s["id"])}\"#{s["id"] == wanted ? " selected" : ""}>#{esc(s["name"])}</option>"
            end
            return page(
              "Connect #{esc(name)}",
              "<p><strong>#{esc(name)}</strong> wants to show this site’s stats and change its settings, so you can manage it from there.</p>\n" \
              "<p>It will be able to change goals, funnels, short links, link domains, email reports, and share links for the site you pick, along with its name, " \
              "timezone, and retention. It cannot read other sites, add people, make tokens, or change how email is sent.</p>\n" \
              "#{sends_to}\n" \
              "<form method=\"post\" action=\"#{esc(base)}/oauth/authorize\">#{hidden}\n" \
              "<label>Site<select name=\"site\">#{choices}</select></label>\n" \
              "<p class=\"note\">Its token appears in Settings, API and AI, where deleting it disconnects #{esc(name)}.</p>\n" \
              '<div class="buttons"><button type="submit" name="decision" value="deny" class="ghost">Deny</button><button type="submit" name="decision" value="allow">Allow</button></div></form>',
            )
          end
          options = +""
          sites.each { |s| options << "<option value=\"#{esc(s["id"])}\">#{esc(s["name"])} only</option>" }
          return page(
            "Connect #{esc(name)}",
            "<p><strong>#{esc(name)}</strong> wants to read your Runlight stats so it can answer questions about them. It will be able to read and never to change anything.</p>\n" \
            "#{sends_to}\n" \
            "<form method=\"post\" action=\"#{esc(base)}/oauth/authorize\">#{hidden}\n" \
            "<label>Which sites it can read<select name=\"site\"><option value=\"\">Every site</option>#{sites.length > 1 ? options : ""}</select></label>\n" \
            "<p class=\"note\">Its token appears in Settings, API and AI, where deleting it disconnects the app.</p>\n" \
            '<div class="buttons"><button type="submit" name="decision" value="deny" class="ghost">Deny</button><button type="submit" name="decision" value="allow">Allow</button></div></form>',
          )
        end
        # The consent form posts here from this page only; a form from another site is refused.
        origin = request.headers.get("origin")
        return page("This request came from another site", "<p>Start connecting again from the app.</p>", 403) if !origin.nil? && origin != "" && origin != url.origin
        return back.call({ "error" => "access_denied" }) if form.get("decision") != "allow"

        site = form.get("site") || ""
        return back.call({ "error" => "invalid_request", "error_description" => "Unknown site" }) if site != "" && runlight.site(site).nil?
        if manage && (site == "" || !runlight.remote(site).nil?)
          return back.call({ "error" => "invalid_request", "error_description" => "Pick the site to manage" })
        end

        code = Hashing.random_id(32)
        by = ctx["accountOf"]&.call(request)
        grant = { "client" => client_id, "redirect" => redirect, "challenge" => challenge, "site" => site, "scope" => manage ? "manage" : "read",
                  "expires" => runlight.now + CODE_MS }
        grant["by"] = by if !by.nil? && by != ""
        runlight.store.set_setting("oauth-code:#{Hashing.sha256(code)}", Json.encode(grant))
        return back.call({ "code" => code })
      end

      if path == "/oauth/token" && request.method == "POST"
        runlight.init
        type = (request.headers.get("content-type") || "").split(";", -1)[0].to_s.strip
        form = type == "application/json" ? json_form(request.text) : Http::SearchParams.new(request.text)
        return oauth_error("unsupported_grant_type", "Only authorization_code is supported") if form.get("grant_type") != "authorization_code"

        key = "oauth-code:#{Hashing.sha256(form.get("code") || "")}"
        stored = runlight.store.setting(key)
        # A code works once: it is gone before anything else is checked.
        runlight.store.set_setting(key, nil) if !stored.nil? && stored != ""
        grant = !stored.nil? && stored != "" ? Json.decode(stored) : nil
        return oauth_error("invalid_grant", "The code has expired or was already used") if grant.nil? || grant["expires"] < runlight.now
        if grant["client"] != form.get("client_id") || grant["redirect"] != form.get("redirect_uri")
          return oauth_error("invalid_grant", "The code was issued to another app")
        end
        return oauth_error("invalid_grant", "The code verifier does not match") if s256(form.get("code_verifier") || "") != grant["challenge"]

        # The first row an app gets here: it has connected, so a request it gets wrong may go back to it.
        found = client_for(runlight, grant["client"].to_s)
        client = found.nil? ? {} : found["client"]
        if !found.nil? && !Js.truthy?(found["client"]["usedAt"])
          stored_client = found["usedKey"].start_with?("oauth-client:")
          used = found["client"].merge("usedAt" => runlight.now)
          runlight.store.set_setting(found["usedKey"], stored_client ? Json.encode(used) : runlight.now.to_s)
        end
        secret = "rl_#{Hashing.random_id(20)}"
        scope = grant["scope"] == "manage" ? "manage" : "read"
        row = {
          "id" => Hashing.random_id,
          "name" => Js.slice("#{Js.string(client["name"].nil? ? "An app" : client["name"])} (OAuth)", 0, 100),
          "site" => grant["site"].to_s,
          "scope" => scope,
          "hash" => Hashing.sha256(secret),
          "hint" => secret[-4..],
          "createdAt" => runlight.now,
          "lastUsedAt" => nil,
        }
        runlight.store.insert_token(row)
        # Someone removed, or no longer an owner, between allowing the app and its swapping the code gets nothing.
        if !grant["by"].nil? && grant["by"] != "" && ctx["tokenMade"] && !ctx["tokenMade"].call(row, grant["by"].to_s)
          runlight.store.delete_token(row["id"])
          return oauth_error("invalid_grant", "Whoever allowed this app can no longer connect it")
        end
        # A hub's own address, from where it asked to be sent back, so the picker only ever sends choices there.
        runlight.store.set_setting("token-origin:#{row["id"]}", Http::Url.new(grant["redirect"].to_s).origin) if scope == "manage"
        # site is not part of OAuth, but a hub needs to know which site it was given.
        answer = { "access_token" => secret, "token_type" => "Bearer", "scope" => scope }
        answer["site"] = grant["site"] if grant["site"] != ""
        return json(answer)
      end

      nil
    end

    def base64url(text)
      [text].pack("m0").tr("+/", "-_").delete("=")
    end

    def from_base64url(text)
      text.tr("-_", "+/").unpack1("m")
    end

    # The key client ids are signed with, made on first use and kept in the database for every process.
    def client_key(runlight)
      saved = runlight.store.setting("oauth-key")
      return saved if !saved.nil? && saved != ""

      made = Hashing.random_id(32)
      runlight.store.set_setting("oauth-key", made)
      made
    end

    # The app a client id names, and where to note that it connected: {"client" => ..., "usedKey" => ...}, or nil.
    # A new id carries the app's name and addresses, signed, so registering stores nothing and a flood of
    # registrations fills nothing. Ids from before that were stored.
    def client_for(runlight, id)
      if id.match?(/\A[a-f0-9]{32}\z/)
        stored = runlight.store.setting("oauth-client:#{id}")
        return !stored.nil? && stored != "" ? { "client" => Json.decode(stored), "usedKey" => "oauth-client:#{id}" } : nil
      end
      parts = id.match(/\A([A-Za-z0-9_-]{1,2000})\.([a-f0-9]{64})\z/)
      return nil if parts.nil? || id.bytesize > MAX_CLIENT_ID
      return nil unless constant_time_equal(parts[2], Hashing.hmac(client_key(runlight), parts[1]))

      meta = Json.decode(Js.scrub(from_base64url(parts[1])))
      used_key = "oauth-used:#{Hashing.sha256(id)}"
      used = runlight.store.setting(used_key)
      client = { "name" => meta["n"], "redirects" => meta["r"], "createdAt" => meta["t"] }
      client["usedAt"] = Js.number(used) if !used.nil? && used != ""
      { "client" => client, "usedKey" => used_key }
    end

    def constant_time_equal(a, b)
      a.bytesize == b.bytesize && OpenSSL.fixed_length_secure_compare(a, b)
    end

    def esc(value)
      value.to_s.gsub(/[&<>"']/, ESCAPES)
    end

    def json(body, status = 200)
      Http::Response.new(Json.encode(body), status: status, headers: { "content-type" => "application/json; charset=utf-8", "cache-control" => "no-store" }.merge(CORS))
    end

    def oauth_error(error, description, status = 400)
      json({ "error" => error, "error_description" => description }, status)
    end

    # Redirect addresses a client may register: https, or a local app's own loopback address.
    def allowed_redirect(value)
      value.match?(%r{\Ahttps://[^/]+}) || value.match?(%r{\Ahttp://(localhost|127\.0\.0\.1|\[::1\])(:\d+)?/})
    end

    # `new URLSearchParams(Object.entries(await request.json() ?? {}))`, each value as String() writes it.
    def json_form(text)
      parsed, body = Js.parse_json(text)
      form = Http::SearchParams.new
      return form if !parsed || body.nil?

      case body
      when Hash then body.each { |k, v| form.append(k.to_s, Js.string(v)) }
      when Array then body.each_with_index { |v, i| form.append(i.to_s, Js.string(v)) }
      when String then body.each_char.with_index { |c, i| form.append(i.to_s, c) }
      end
      form
    end

    # Counts a registration from an address and says whether it is under the limit for this minute. The count
    # is kept in the install's settings, keyed by an HMAC of the address, so no address is ever stored.
    def allow_registration(runlight, ip)
      # No address cannot be told apart, so it is not limited.
      return true if ip == ""

      window = runlight.now.div(60_000)
      id = Hashing.hmac(client_key(runlight), "register:#{ip}")[0, 16]
      saved = Json.try_decode(runlight.store.setting(REGISTRATIONS).to_s)
      counts = saved.is_a?(Hash) && saved["window"] == window && saved["counts"].is_a?(Hash) ? saved["counts"] : {}
      counts[id] = Js.number(counts[id] || 0).to_i + 1
      runlight.store.set_setting(REGISTRATIONS, Json.encode({ "window" => window, "counts" => counts }))
      counts[id] <= REGISTRATIONS_PER_MINUTE
    end

    # Registers a client by signing its name and addresses into its id, so
    # nothing is stored until an owner allows it and the app swaps its code.
    def register(runlight, name, redirects)
      now = runlight.now
      # Apps stored before ids were signed, which never connected, and codes nobody exchanged are cleared away.
      runlight.store.settings_starting_with("oauth-client:").each do |entry|
        client = Json.decode(entry["value"])
        runlight.store.set_setting(entry["key"], nil) if !Js.truthy?(client["usedAt"]) && now - client["createdAt"] >= UNUSED_CLIENT_MS
      end
      runlight.store.settings_starting_with("oauth-code:").each do |entry|
        code = Json.try_decode(entry["value"])
        runlight.store.set_setting(entry["key"], nil) if Js.number(code.is_a?(Hash) ? (code["expires"] || 0) : 0) < now
      end
      trimmed = Js.slice(Js.trim(name), 0, 80)
      client_name = trimmed == "" ? "An app" : trimmed
      payload = base64url(Json.encode({ "n" => client_name, "r" => redirects, "t" => now }))
      id = "#{payload}.#{Hashing.hmac(client_key(runlight), payload)}"
      return oauth_error("invalid_client_metadata", "Register fewer or shorter redirect addresses") if id.bytesize > MAX_CLIENT_ID

      json({ "client_id" => id, "client_name" => client_name, "redirect_uris" => redirects, "token_endpoint_auth_method" => "none",
             "grant_types" => ["authorization_code"], "response_types" => ["code"] }, 201)
    end

    def page(title, body, status = 200)
      Http::Response.new(
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><meta name=\"robots\" content=\"noindex\"><title>#{title} | Runlight</title>\n" \
        '<style>:root{color-scheme:light dark;--page:#f4f4f5;--card:#fff;--ink:#111827;--muted:#4b5563;--line:#e5e7eb}@media (prefers-color-scheme:dark){:root{--page:#09090b;--card:#141417;--ink:#fafafa;--muted:#a1a1aa;--line:#27272a}}body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--page);color:var(--ink);font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif}main{width:min(440px,calc(100% - 32px));padding:28px;background:var(--card);border:1px solid var(--line);border-radius:14px}h1{font-size:20px;margin:0 0 12px}p{margin:0 0 16px;color:var(--muted)}p strong{color:var(--ink)}a{color:inherit}label{display:block;margin:0 0 14px;font-size:13px;font-weight:600}select{display:block;width:100%;height:40px;margin-top:6px;padding:0 36px 0 12px;border:1px solid var(--line);border-radius:8px;background:var(--card) url("data:image/svg+xml,%3Csvg xmlns=\'http://www.w3.org/2000/svg\' viewBox=\'0 0 16 16\'%3E%3Cpath d=\'M4 6l4 4 4-4\' fill=\'none\' stroke=\'%238a8a93\' stroke-width=\'1.6\' stroke-linecap=\'round\' stroke-linejoin=\'round\'/%3E%3C/svg%3E") right 12px center/14px no-repeat;color:var(--ink);font:inherit;font-weight:400;appearance:none;cursor:pointer}.note{font-size:13px}.buttons{display:flex;justify-content:flex-end;gap:8px}button{height:40px;padding:0 18px;border:0;border-radius:8px;background:var(--ink);color:var(--card);font:inherit;font-weight:600;cursor:pointer}button.ghost{background:none;color:var(--ink);border:1px solid var(--line)}</style></head><body><main><h1>' \
        "#{title}</h1>#{body}</main></body></html>",
        status: status,
        headers: {
          "content-type" => "text/html; charset=utf-8",
          "cache-control" => "no-store",
          # No form-action rule: browsers apply it to the redirect back to the app after Allow.
          "content-security-policy" => "default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; frame-ancestors 'none'",
          "x-frame-options" => "DENY",
          # same-origin, not no-referrer: under no-referrer a form post carries Origin: null, which the consent check refuses.
          "referrer-policy" => "same-origin",
        },
      )
    end

    private_class_method :base64url, :from_base64url, :client_key, :client_for, :constant_time_equal, :esc, :json, :oauth_error,
                         :allowed_redirect, :json_form, :allow_registration, :register, :page
  end
end
