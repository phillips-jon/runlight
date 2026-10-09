# frozen_string_literal: true

module Runlight
  module Accounts
    # Accounts on the web: sign-in, the code step, invites, first-run setup, and the Account and People APIs, under
    # the base path the routes answer at. The standalone server and an app with routes(accounts: true) share it.
    #
    # Who may create the first account ("firstAccount"): the server's printed one-time code ({"code" => ...}), the
    # app's token ({"token" => ...}), anyone ("open", for development), or nobody yet ("locked").
    class Web
      HTML = {
        "content-type" => "text/html; charset=utf-8",
        "cache-control" => "no-store",
        "content-security-policy" => "default-src 'none'; script-src 'self'; style-src 'self'; img-src data:; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
        "x-frame-options" => "DENY",
        "referrer-policy" => "same-origin",
      }.freeze

      DEVICE_COOKIE = "runlight_device"
      # Who made each token, kept beside it as a setting, so removing someone or making them a viewer deletes them.
      MADE_BY = "token-by:"
      # When each account was last sent a sign-in link, at most one a minute; a setting, so every process sees it.
      LINK_SENT = "login-link-sent:"
      ESCAPES = { "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", '"' => "&quot;", "'" => "&#39;" }.freeze
      private_constant :HTML, :DEVICE_COOKIE, :MADE_BY, :LINK_SENT, :ESCAPES

      attr_reader :accounts

      # options: "runlight" (the Core, or anything with store, mail_settings, send_mail, and client_ip), "secret",
      # "base", "now" (a callable giving milliseconds), "firstAccount", "home" (optional, a callable giving the
      # install's own origin or nil), "forgot", and "setupWhere" (optional), which says where to find the setup
      # link with the one-time code, when it is not in a log (HTML).
      def initialize(options)
        @rl = options["runlight"]
        @store = @rl.store
        @base = options["base"]
        @now = options["now"]
        @first = options["firstAccount"]
        @home = options["home"]
        @forgot = options["forgot"]
        @setup_where = options["setupWhere"]
        @accounts = Accounts.new(@store, options["secret"])
        @cookie_path = @base == "" ? "/" : @base
        @home_path = "#{@base}/"
        @asks_for_token = @first.is_a?(Hash) && @first.key?("token")
        @existing = false
        # Wrong passwords are counted twice. Per account and address, ten tries;
        # per account from anywhere, fifty, so a caller who invents a new address
        # for every try still cannot guess on and on. Addresses come from
        # forwarding headers a client can write, so they never stand alone.
        # Each try counts before the password is checked, and a right one is taken back.
        @per_address = Throttle.new(@store, "address", 10)
        @per_account = Throttle.new(@store, "account", 50)
        # Six-digit codes: five wrong tries an account every fifteen minutes, and five to confirm the first one.
        # Password re-checks in Account: ten.
        @code_tries = Throttle.new(@store, "code", 5)
        @confirm_tries = Throttle.new(@store, "confirm", 5)
        @rechecks = Throttle.new(@store, "recheck", 10)
      end

      # A random one-time code, such as the one a server prints to unlock its first account.
      def self.setup_code
        Crypto.base64url(Crypto.random_bytes(9))
      end

      def has_account?
        @existing = @existing || @accounts.count.positive?
      end

      # Only a path on this install, so a sign-in can never send someone elsewhere.
      # Browsers drop tabs and newlines from a URL and read a backslash as a slash,
      # so "/\t/evil.example" would leave; anything with those is refused outright,
      # and what is left must resolve to this origin.
      def safe_next(value)
        return @home_path if value.nil? || value == "" || !value.start_with?("/") || value.match?(/[\x00-\x1f\x7f\\]/)

        url = Http::Url.parse(value, "http://runlight.invalid")
        !url.nil? && url.origin == "http://runlight.invalid" ? "#{url.pathname}#{url.search}#{url.hash}" : @home_path
      end

      def signed_in(request)
        value = read_cookie(request, Accounts::SESSION_COOKIE)
        return nil if value == ""

        decoded = Js.decode_uri_component(value)
        # decodeURIComponent throws a URIError here in TypeScript.
        raise ArgumentError, "URI malformed" if decoded.nil?

        @accounts.from_session(decoded, now)
      end

      # What a signed-in person may do: everything (owner and admin, true), "member", "read" (viewer), or nothing (false).
      def access(request)
        user = signed_in(request)
        return false if user.nil?

        # A member changes everything but the install-wide controls; a viewer reads every site and changes nothing.
        if user["role"] == "owner" || user["role"] == "admin"
          true
        else
          user["role"] == "member" ? "member" : "read"
        end
      end

      def account_of(request)
        signed_in(request)&.fetch("id", nil)
      end

      # Notes who made a token. A viewer makes no tokens; someone removed or made a viewer since allowing an app
      # gets none for it, and false takes the token back.
      def token_made(token, by)
        role = @accounts.by_id(by)&.fetch("role", nil)
        return false if role.nil? || role == "viewer"

        @store.set_setting("#{MADE_BY}#{token["id"]}", by)
        true
      end

      # Answers an account page or API request at a path under the base, or nil for anything else.
      # context: {"ip" => the connection's address}, optional.
      def handle(request, path, context = {})
        if path == "/api/account" || path.start_with?("/api/account/") || path == "/api/people" || path.start_with?("/api/people/") ||
           path.start_with?("/api/invites/")
          return api(request, path)
        end

        page = pages(request, path, context)
        return page unless page.nil?

        # The dashboard itself: straight to sign-in, or to setting up the first account.
        if (path == "/" || path == "") && request.method == "GET" && signed_in(request).nil?
          return @first == "open" || @asks_for_token ? redirect("#{@base}/setup") : setup_locked unless has_account?

          search = Http::Url.new(request.url).search
          return redirect("#{@base}/login#{search == "" ? "" : "?next=#{Js.encode_uri_component("#{@home_path}#{search}")}"}")
        end
        nil
      end

      private

      def now
        @now.call
      end

      def home_origin
        @home&.call
      end

      def read_cookie(request, name)
        (request.headers.get("cookie") || "").split(";", -1).each do |part|
          pieces = Js.trim(part).split("=", -1)
          key = pieces.shift || ""
          return pieces.join("=") if key == name
        end
        ""
      end

      def secure?(request)
        Http::Url.new(request.url).protocol == "https:" || request.headers.get("x-forwarded-proto") == "https"
      end

      # An error the dashboard words in its own language, as the routes send them.
      def coded(error, code, status, params = nil)
        body = { "error" => error, "code" => code }
        body["params"] = params unless params.nil?
        headers = { "content-type" => "application/json; charset=utf-8", "cache-control" => "no-store", "x-content-type-options" => "nosniff" }
        Http::Response.new(Json.encode(body), status: status, headers: headers)
      end

      def esc(text)
        text.to_s.gsub(/[&<>"']/, ESCAPES)
      end

      def html(body, status = 200, extra = {})
        Http::Response.new(body, status: status, headers: HTML.merge(extra))
      end

      def redirect(location, extra = {})
        Http::Response.new("", status: 303, headers: { "location" => location, "cache-control" => "no-store" }.merge(extra))
      end

      def reply(body, status = 200, extra = {})
        Http::Response.new(Json.encode(body), status: status, headers: { "content-type" => "application/json; charset=utf-8", "cache-control" => "no-store" }.merge(extra))
      end

      def person(u)
        { "id" => u["id"], "email" => u["email"], "role" => u["role"], "createdAt" => u["createdAt"], "twoFactor" => u["twoFactor"], "recoveryLeft" => u["recoveryLeft"] }
      end

      def invite_view(i)
        { "id" => i["id"], "email" => i["email"], "role" => i["role"], "invitedBy" => i["invitedBy"], "createdAt" => i["createdAt"], "expiresAt" => i["expiresAt"] }
      end

      # The media type of a request's body, as a cross-site form cannot send application/json.
      def media_type(request)
        Js.lower(Js.trim((request.headers.get("content-type") || "").split(";", -1)[0] || ""))
      end

      # A JSON body by its media type, which a cross-site form cannot send.
      def body(request)
        return nil if media_type(request) != "application/json"

        parsed, value = Js.parse_json(request.text)
        parsed && value.is_a?(Hash) ? value : nil
      end

      # `String(input[field] ?? "")`.
      def field(input, name)
        value = Js.get(input, name)
        value.nil? || value.equal?(UNDEFINED) ? "" : Js.string(value)
      end

      def drop_tokens_of(id)
        @store.settings_starting_with(MADE_BY).each do |row|
          next if row["value"] != id

          @store.delete_token(row["key"][MADE_BY.length..])
          @store.set_setting(row["key"], nil)
        end
      end

      def session_cookie(request, value, max_age)
        "#{Accounts::SESSION_COOKIE}=#{Js.encode_uri_component(value)}; Path=#{@cookie_path}; HttpOnly; SameSite=Lax; Max-Age=#{max_age}" \
          "#{secure?(request) ? "; Secure" : ""}"
      end

      # The redirect after signing in: a session, and the mark that this browser has signed in to the account.
      def signed_in_to(request, user, next_path)
        headers = Http::Headers.new({ "location" => next_path, "cache-control" => "no-store" })
        headers.append("set-cookie", session_cookie(request, @accounts.session_for(user, now), Accounts::SESSION_MS / 1000))
        headers.append("set-cookie", "#{DEVICE_COOKIE}=#{Js.encode_uri_component(@accounts.device_for(user))}; Path=#{@cookie_path}; HttpOnly; SameSite=Lax; " \
                                     "Max-Age=#{365 * 86_400}#{secure?(request) ? "; Secure" : ""}")
        Http::Response.new("", status: 303, headers: headers)
      end

      # The first account's gate: what the setup form must carry.
      def setup_ok(given)
        return true if @first == "open"
        return false if @first == "locked"

        Crypto.same_text(given, (@first["code"] || @first["token"]).to_s)
      end

      # Why there is no setup form.
      def setup_locked
        html(@first == "locked" ? Pages.setup_needs_token_page(@base) : Pages.setup_locked_page(@base, @setup_where), 403)
      end

      # Emails an invite through the mail service when there is one. The link
      # always comes back too, for the inviter to pass on another way.
      def send_invite(request, invite, code)
        origin = home_origin || Http::Url.new(request.url).origin
        link = "#{origin}#{@base}/invite?code=#{code}"
        host = Http::Url.new(origin).host
        what = Pages.role_text(invite["role"])
        return { "link" => link, "emailed" => false } unless @rl.mail_settings

        begin
          @rl.send_mail({
            "to" => invite["email"],
            "subject" => "#{invite["invitedBy"]} invited you to Runlight",
            "text" => "#{invite["invitedBy"]} invited you to the Runlight at #{host} as #{what}.\n\nChoose a password to join:\n#{link}\n\nThe link works for seven days.\n",
            "html" => "<div style=\"font:15px/1.6 -apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;color:#111827;max-width:480px\"><p>" \
                      "#{esc(invite["invitedBy"])} invited you to the Runlight at #{esc(host)} as #{what}.</p><p><a href=\"#{esc(link)}\" " \
                      "style=\"display:inline-block;padding:10px 18px;border-radius:8px;background:#111827;color:#ffffff;text-decoration:none;font-weight:600\">" \
                      "Choose a password and join</a></p><p style=\"color:#6b7280;font-size:13px\">The link works for seven days. If you were not expecting this, " \
                      "you can ignore it.</p></div>",
          })
          { "link" => link, "emailed" => true }
        rescue StandardError => e
          # The mail service's code and its details too, so the dashboard can say what went wrong in its own language.
          # Only a String `code` counts, as TypeScript reads `typeof failed.code === "string"`.
          out = { "link" => link, "emailed" => false, "mailError" => e.message }
          if e.respond_to?(:code) && e.code.is_a?(String)
            out["mailCode"] = e.code
            params = e.respond_to?(:params) ? e.params : nil
            out["mailParams"] = params.is_a?(Hash) ? params : {}
          end
          out
        end
      end

      # Emails a sign-in link to an account held up by others' failed tries, at
      # most once a minute. Only to the install's own address, never the Host of
      # the request, so without one known there is no link.
      def send_link(user, next_path)
        origin = home_origin
        return false if origin.nil? || origin == ""

        key = "#{LINK_SENT}#{user["id"]}"
        return true if now - Js.number(@store.setting(key) || 0) < 60_000

        @store.set_setting(key, now.to_s)
        link = "#{origin}#{@base}/login/link?#{Http::SearchParams.new({ "ticket" => @accounts.link_for(user, now), "next" => next_path })}"
        host = Http::Url.new(origin).host
        @rl.send_mail({
          "to" => user["email"],
          "subject" => "Sign in to Runlight",
          "text" => "Someone, most likely you, signed in to Runlight at #{host} with your password while your account was held up by too many failed tries.\n\n" \
                    "Sign in with this link within fifteen minutes:\n#{link}\n\nIf this was not you, change your password, since someone knows it.\n",
          "html" => "<div style=\"font:15px/1.6 -apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;color:#111827;max-width:480px\">" \
                    "<p>Someone, most likely you, signed in to Runlight at #{esc(host)} with your password while your account was held up by too many failed tries.</p>" \
                    "<p><a href=\"#{esc(link)}\" style=\"display:inline-block;padding:10px 18px;border-radius:8px;background:#111827;color:#ffffff;" \
                    "text-decoration:none;font-weight:600\">Sign in</a></p><p style=\"color:#6b7280;font-size:13px\">The link works for fifteen minutes. " \
                    "If this was not you, change your password, since someone knows it.</p></div>",
        })
        true
      end

      def pages(request, path, context)
        url = Http::Url.new(request.url)
        query = url.search_params
        method = request.method
        base = @base
        if path == "/auth.css"
          return Http::Response.new(Pages::AUTH_CSS, status: 200, headers: { "content-type" => "text/css; charset=utf-8", "cache-control" => "public, max-age=3600" })
        end
        if path == "/auth.js"
          return Http::Response.new(Pages::AUTH_JS, status: 200, headers: { "content-type" => "application/javascript; charset=utf-8", "cache-control" => "public, max-age=3600" })
        end

        if path == "/setup"
          return redirect("#{base}/login") if has_account?

          if method == "GET"
            code = query.get("code") || ""
            return setup_locked if @first == "locked"
            # The app's token is typed in; the server's code comes in the link it printed.
            return html(Pages.setup_page(base, { "code" => "", "askCode" => @asks_for_token })) if @asks_for_token || @first == "open"

            return setup_ok(code) ? html(Pages.setup_page(base, { "code" => code })) : setup_locked
          end
          if method == "POST"
            form = Http::SearchParams.new(request.text)
            code = form.get("code") || ""
            unless setup_ok(code)
              if @asks_for_token
                return html(Pages.setup_page(base, { "code" => "", "askCode" => true, "error" => "That is not this app's RUNLIGHT_TOKEN.", "email" => form.get("email") || "" }), 403)
              end

              return setup_locked
            end
            again = ->(error) { { "code" => @asks_for_token ? "" : code, "askCode" => @asks_for_token, "error" => error, "email" => form.get("email") || "" } }
            # Asked twice, since a typo here would lock the first owner out.
            return html(Pages.setup_page(base, again.call("The two passwords are not the same.")), 400) if (form.get("password") || "") != (form.get("again") || "")

            begin
              user = @accounts.set_password(form.get("email") || "", form.get("password") || "", now)
              @existing = true
              return redirect(@home_path, { "set-cookie" => session_cookie(request, @accounts.session_for(user, now), Accounts::SESSION_MS / 1000) })
            rescue RangeError => e
              return html(Pages.setup_page(base, again.call(e.message)), 400)
            end
          end
        end

        if path == "/login"
          unless has_account?
            return setup_locked if @first == "locked"

            return @first == "open" || @asks_for_token ? redirect("#{base}/setup") : setup_locked
          end
          return html(Pages.login_page(base, { "next" => safe_next(query.get("next")), "forgot" => @forgot })) if method == "GET"
          return login(request, context) if method == "POST"
        end

        # The link a locked account's owner is emailed: the code step with two-factor on, else straight in.
        if path == "/login/link" && method == "GET"
          next_path = safe_next(query.get("next"))
          user = @accounts.from_link(query.get("ticket") || "", now)
          if user.nil?
            return html(Pages.login_page(base, { "error" => "That sign-in link has run out. Sign in again.", "next" => next_path, "forgot" => @forgot }), 410)
          end
          return html(Pages.code_page(base, { "pending" => @accounts.pending_for(user, now), "next" => next_path })) if user["twoFactor"]

          return signed_in_to(request, user, next_path)
        end

        if path == "/login/code" && method == "POST"
          form = Http::SearchParams.new(request.text)
          next_path = safe_next(form.get("next"))
          pending = @accounts.from_pending(form.get("pending") || "", now)
          return redirect("#{base}/login?next=#{Js.encode_uri_component(next_path)}") if pending.nil?

          user = pending["user"]
          real = pending["real"]
          # Counted before the check, so a burst cannot get past five.
          unless @code_tries.take(user["id"], now)
            return html(Pages.code_page(base, { "pending" => form.get("pending") || "", "next" => next_path, "error" => "Too many tries. Wait fifteen minutes and try again." }), 429)
          end
          if !real || !@accounts.check_second_factor(user["id"], form.get("code") || "", now)
            return html(Pages.code_page(base, { "pending" => form.get("pending") || "", "next" => next_path,
                                                "error" => "That code is not right. Check the time on your phone, or use a recovery code." }), 401)
          end

          @code_tries.clear(user["id"])
          return signed_in_to(request, user, next_path)
        end

        return redirect("#{base}/login", { "set-cookie" => session_cookie(request, "", 0) }) if path == "/logout"

        if path == "/invite"
          if method == "GET"
            code = query.get("code") || ""
            invite = @accounts.invite_by_code(code, now)
            return html(Pages.invite_gone_page(base), 410) if invite.nil?

            return html(Pages.invite_page(base, { "code" => code, "email" => invite["email"], "role" => invite["role"], "host" => url.host }))
          end
          if method == "POST"
            form = Http::SearchParams.new(request.text)
            code = form.get("code") || ""
            invite = @accounts.invite_by_code(code, now)
            return html(Pages.invite_gone_page(base), 410) if invite.nil?

            again = lambda do |error|
              html(Pages.invite_page(base, { "code" => code, "email" => invite["email"], "role" => invite["role"], "host" => url.host, "error" => error }), 400)
            end
            return again.call("The two passwords are not the same.") if (form.get("password") || "") != (form.get("again") || "")

            begin
              user = @accounts.accept_invite(code, form.get("password") || "", now)
              @existing = true
              return redirect(@home_path, { "set-cookie" => session_cookie(request, @accounts.session_for(user, now), Accounts::SESSION_MS / 1000) })
            rescue RangeError => e
              return again.call(e.message)
            end
          end
        end
        nil
      end

      def login(request, context)
        base = @base
        form = Http::SearchParams.new(request.text)
        email = form.get("email") || ""
        password = form.get("password") || ""
        next_path = safe_next(form.get("next"))
        account = Js.lower(Js.trim(email))
        ip = @rl.client_ip(request, context)
        pair = "#{account}\n#{ip == "" ? "unknown" : ip}"
        login_page = ->(opts) { Pages.login_page(base, opts.merge("next" => next_path, "forgot" => @forgot) { |_k, mine, _theirs| mine }) }
        too_many = -> { html(login_page.call({ "error" => "Too many tries. Wait fifteen minutes and try again.", "email" => email }), 429) }
        return too_many.call unless @per_address.take(pair, now)

        # A browser that signed in to the account before is never held up by others' failures.
        known = @accounts.by_email(account)
        trusted = !known.nil? && @accounts.trusts_device(read_cookie(request, DEVICE_COOKIE), known)
        over = !trusted && !@per_account.take(account, now)
        # Past the account's limit, a right password and a wrong one get the same answer, so guessing from many
        # addresses learns nothing, and the owner still gets in. With two-factor on, both reach the code step,
        # where a wrong password's ticket never passes. Without it, a right password emails a sign-in link.
        if over && !(known && known["twoFactor"])
          home = home_origin
          return too_many.call if !@rl.mail_settings || home.nil? || home == ""

          user = @accounts.sign_in(email, password)
          unless user.nil?
            # Sent once the answer is out, as TypeScript does, so a right password takes no longer to answer than a
            # wrong one.
            @rl.later do
              send_link(user, next_path)
            rescue StandardError => e
              warn "Runlight: could not send a sign-in link #{e.message}"
            end
          end
          return html(login_page.call({ "error" => "Too many tries for this account. If the password was right, a link to sign in is on its way to its email address.",
                                        "email" => email }), 429)
        end
        user = @accounts.sign_in(email, password)
        if user.nil?
          return html(Pages.code_page(base, { "pending" => @accounts.decoy_for(known, now), "next" => next_path })) if over && !known.nil?

          return html(login_page.call({ "error" => "That email and password do not match an account.", "email" => email }), 401)
        end
        @per_address.clear(pair)
        @per_account.forgive(account) if !over && !trusted
        # With two-factor on, the password only earns the second step.
        return html(Pages.code_page(base, { "pending" => @accounts.pending_for(user, now), "next" => next_path })) if user["twoFactor"]

        signed_in_to(request, user, next_path)
      end

      # Your own account, and for the owner and admins, everyone else's.
      def api(request, path)
        user = signed_in(request)
        return coded("Sign in first", "sign_in", 401) if user.nil?

        now = self.now
        method = request.method
        # Writes must be JSON, which a form on another page cannot send, even those with no body.
        return coded("Send JSON", "send_json", 415) if method == "POST" && media_type(request) != "application/json"
        return reply({ "account" => person(user) }) if path == "/api/account" && method == "GET"

        recheck = lambda do |input, name, wrong|
          return coded("Too many tries. Wait fifteen minutes and try again.", "too_many_tries", 429) unless @rechecks.take(user["id"], now)
          return coded(wrong[0], wrong[1], 400) if @accounts.sign_in(user["email"], field(input, name)).nil?

          @rechecks.forgive(user["id"])
          nil
        end
        fresh = ->(updated) { { "set-cookie" => session_cookie(request, @accounts.session_for(updated, now), Accounts::SESSION_MS / 1000) } }
        if path == "/api/account/password" && method == "POST"
          input = body(request)
          return coded("Send JSON", "send_json", 415) if input.nil?

          refused = recheck.call(input, "current", ["Your current password is not right", "password_current_wrong"])
          return refused unless refused.nil?

          begin
            updated = @accounts.set_password(user["email"], field(input, "next"), now)
            # The new password ends every other sign-in; this browser gets a fresh one.
            return reply({ "ok" => true }, 200, fresh.call(updated))
          rescue AccountError => e
            return coded(e.message, e.code, 400, e.params)
          end
        end
        # Two-factor: turning it on, confirming the first code, new recovery codes, and turning it off.
        # Each change asks for the password again, so a browser left signed in cannot quietly change it.
        if path.start_with?("/api/account/2fa") && method == "POST"
          input = body(request)
          return coded("Send JSON", "send_json", 415) if input.nil?

          action = path["/api/account/2fa".length..]
          # Confirming asks for no password, so it has its own few tries, after which the set-up starts again.
          if action == "/confirm"
            unless @confirm_tries.take(user["id"], now)
              @accounts.cancel_two_factor_setup(user["id"])
              return coded("Too many wrong codes. Start turning on two-factor sign-in again.", "twofactor_restart", 429)
            end
            codes = @accounts.confirm_two_factor(user["id"], field(input, "code").gsub(/[#{Js::SPACE}]/o, ""), now)
            return coded("That code is not right. Check the time on your phone and try the next one.", "code_wrong", 400) if codes.nil?

            @confirm_tries.clear(user["id"])
            # Turning it on signs out every other browser; this one gets a new session.
            updated = @accounts.by_id(user["id"])
            return reply({ "recovery" => codes }, 200, fresh.call(updated))
          end
          refused = recheck.call(input, "password", ["Your password is not right", "password_wrong"])
          return refused unless refused.nil?

          if action == "/start"
            @confirm_tries.clear(user["id"])
            secret = @accounts.start_two_factor(user["id"])
            return reply({ "secret" => secret, "uri" => Crypto.otpauth_uri(secret, user["email"], Http::Url.new(request.url).host) })
          end
          if action == "/recovery"
            return coded("Turn on two-factor sign-in first", "twofactor_off", 400) unless user["twoFactor"]

            return reply({ "recovery" => @accounts.new_recovery_codes(user["id"]) })
          end
          if action == "/disable"
            @accounts.disable_two_factor(user["id"])
            # Sessions follow two-factor's state, so this browser gets a new one and stays signed in.
            updated = @accounts.by_id(user["id"])
            return reply({ "ok" => true }, 200, fresh.call(updated))
          end
          return coded("Not found", "not_found", 404)
        end
        return coded("Only the owner or an admin can manage people", "people_owner", 403) if user["role"] != "owner" && user["role"] != "admin"

        # The owner or an admin can turn off someone else's two-factor, for a coworker who lost both phone and recovery
        # codes, though never the owner's. It asks for their password like every other two-factor change, and their own
        # goes through Account.
        if (reset = path.match(%r{\A/api/people/([a-f0-9]{24})/2fa\z})) && method == "DELETE"
          return coded("Turn off your own two-factor sign-in under Account", "twofactor_self", 400) if reset[1] == user["id"]

          input = body(request)
          return coded("Send JSON", "send_json", 415) if input.nil?

          refused = recheck.call(input, "password", ["Your password is not right", "password_wrong"])
          return refused unless refused.nil?

          target = @accounts.by_id(reset[1])
          return coded("Unknown account", "unknown_account", 404) if target.nil?
          return coded("Only the owner can change the owner's account", "owner_protected", 403) if target["role"] == "owner"

          @accounts.disable_two_factor(reset[1])
          return reply({ "ok" => true })
        end
        # The owner hands ownership to an admin and becomes an admin, after typing their password again.
        if (hand_over = path.match(%r{\A/api/people/([a-f0-9]{24})/owner\z})) && method == "POST"
          return coded("Only the owner can hand over ownership", "owner_hand_over", 403) if user["role"] != "owner"

          input = body(request)
          return coded("Send JSON", "send_json", 415) if input.nil?

          refused = recheck.call(input, "password", ["Your password is not right", "password_wrong"])
          return refused unless refused.nil?

          begin
            @accounts.hand_over(user["id"], hand_over[1])
            return reply({ "people" => @accounts.list.map { |u| person(u) } })
          rescue AccountError => e
            return coded(e.message, e.code, e.code == "unknown_account" ? 404 : 400, e.params)
          end
        end
        # Nobody is invited as, or made, the owner: there is one, and they hand it over themselves.
        role_of = ->(value) { %w[admin member viewer].include?(value) ? value : nil }
        if path == "/api/people" && method == "GET"
          return reply({ "people" => @accounts.list.map { |u| person(u) }, "invites" => @accounts.invites(now).map { |i| invite_view(i) } })
        end
        if path == "/api/people" && method == "POST"
          input = body(request)
          return coded("Send JSON", "send_json", 415) if input.nil?

          role = role_of.call(Js.get(input, "role"))
          return coded("Pick admin, member, or viewer", "role_needed", 400) if role.nil?

          email = Js.lower(Js.trim(field(input, "email")))
          return coded("#{email} already has an account", "account_exists", 409, { "email" => email }) unless @accounts.by_email(email).nil?

          begin
            made = @accounts.invite(email, role, user["email"], now)
            return reply({ "invite" => invite_view(made["invite"]) }.merge(send_invite(request, made["invite"], made["code"])), 201)
          rescue AccountError => e
            return coded(e.message, e.code, 400, e.params)
          end
        end
        if (invite_match = path.match(%r{\A/api/invites/([a-f0-9]{24})(/resend)?\z}))
          resend = !invite_match[2].nil? && invite_match[2] != ""
          if method == "DELETE" && !resend
            return @accounts.cancel_invite(invite_match[1]) ? reply({ "ok" => true }) : coded("Unknown invite", "unknown_invite", 404)
          end
          if method == "POST" && resend
            old = @accounts.invites(now).find { |one| one["id"] == invite_match[1] }
            return coded("Unknown invite", "unknown_invite", 404) if old.nil?

            # A new link replaces the old one, which stops working.
            made = @accounts.invite(old["email"], old["role"], user["email"], now)
            return reply({ "invite" => invite_view(made["invite"]) }.merge(send_invite(request, made["invite"], made["code"])))
          end
        end
        if (match = path.match(%r{\A/api/people/([a-f0-9]{24})\z})) && (method == "PATCH" || method == "DELETE")
          begin
            if method == "DELETE"
              return coded("You cannot remove yourself", "remove_self", 400) if match[1] == user["id"]

              @accounts.remove(match[1])
              # The tokens they made, and the apps they connected, stop working with them.
              drop_tokens_of(match[1])
              return reply({ "ok" => true })
            end
            input = body(request)
            return coded("Send JSON", "send_json", 415) if input.nil?

            role = role_of.call(Js.get(input, "role"))
            return coded("Pick admin, member, or viewer", "role_needed", 400) if role.nil?

            changed = @accounts.set_role(match[1], role)
            # A viewer changes nothing, so the tokens they made before go too.
            drop_tokens_of(match[1]) if role == "viewer"
            return reply({ "person" => person(changed) })
          rescue AccountError => e
            status = if e.code == "unknown_account" then 404
                     elsif e.code == "owner_protected" then 403
                     else 400
                     end
            return coded(e.message, e.code, status, e.params)
          end
        end
        coded("Not found", "not_found", 404)
      end

    end
  end
end
