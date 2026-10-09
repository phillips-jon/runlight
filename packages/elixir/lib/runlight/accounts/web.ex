defmodule Runlight.Accounts.Web do
  @moduledoc """
  Accounts on the web: sign-in, the code step, invites, first-run setup, and
  the Account and People APIs, under the base path the routes answer at (the
  SDK's accounts/web.ts). `Runlight.routes(rl, accounts: true)` makes one.
  """

  alias Runlight.AccountError
  alias Runlight.Accounts
  alias Runlight.Accounts.Pages
  alias Runlight.Accounts.Throttle
  alias Runlight.Crypto
  alias Runlight.Http.Request
  alias Runlight.Http.Response
  alias Runlight.JS
  alias Runlight.JS.Object
  alias Runlight.SearchParams
  alias Runlight.State
  alias Runlight.Store
  alias Runlight.Url

  require Logger

  defstruct [:rl, :accounts, :id, :base, :now, :first, :home, :forgot, :throttles]

  @type t :: %__MODULE__{}

  @html [
    {"content-type", "text/html; charset=utf-8"},
    {"cache-control", "no-store"},
    {"content-security-policy",
     "default-src 'none'; script-src 'self'; style-src 'self'; img-src data:; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"},
    {"x-frame-options", "DENY"},
    {"referrer-policy", "same-origin"}
  ]

  @device_cookie "runlight_device"
  # Who made each token, kept beside it as a setting, so removing someone or making them a viewer deletes them.
  @made_by "token-by:"

  @doc """
  Accounts on the web. Options: `runlight`, `secret` (signs sessions and seals
  two-factor secrets; keep it stable across restarts), `base`, `now`,
  `first_account` (who may create the first account: `{:code, code}`,
  `{:token, token}`, `:open`, or `:locked`), `home` (a function answering the
  install's public address, or nil), and `forgot` (where the sign-in page
  sends someone who forgot their password).
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    rl = Keyword.fetch!(opts, :runlight)
    id = :erlang.unique_integer([:positive])
    table = rl.table

    # Wrong passwords are counted twice. Per account and address, ten tries; per account from anywhere, fifty, so a
    # caller who invents a new address for every try still cannot guess on and on. Six-digit codes: five wrong tries
    # an account every fifteen minutes, and five to confirm the first one. Password re-checks in Account: ten.
    throttles = %{
      per_address: Throttle.new(table, {:web, id, :per_address}, 10),
      per_account: Throttle.new(table, {:web, id, :per_account}, 50),
      code_tries: Throttle.new(table, {:web, id, :code_tries}, 5),
      confirm_tries: Throttle.new(table, {:web, id, :confirm_tries}, 5),
      rechecks: Throttle.new(table, {:web, id, :rechecks}, 10)
    }

    %__MODULE__{
      rl: rl,
      accounts: Accounts.new(rl, Keyword.fetch!(opts, :secret)),
      id: id,
      base: Keyword.get(opts, :base, ""),
      now: Keyword.get(opts, :now) || fn -> Runlight.now(rl) end,
      first: Keyword.get(opts, :first_account, :locked),
      home: Keyword.get(opts, :home),
      forgot: Keyword.get(opts, :forgot, "https://runlight.sh/docs/configuration/#accounts"),
      throttles: throttles
    }
  end

  @doc "A random one-time code, such as the one a server prints to unlock its first account."
  def setup_code, do: Crypto.base64url(Crypto.random_bytes(9))

  defp now(web), do: web.now.()
  defp home_path(web), do: "#{web.base}/"
  defp cookie_path(web), do: if(web.base == "", do: "/", else: web.base)
  defp table(web), do: web.rl.table
  defp home_origin(web), do: if(web.home, do: web.home.())

  @doc "Whether there is any account yet."
  def has_account(web) do
    key = {:web, web.id, :existing}

    if State.get(table(web), key) do
      true
    else
      found = Accounts.count(web.accounts) > 0
      if found, do: State.put(table(web), key, true)
      found
    end
  end

  defp read_cookie(request, name) do
    (Request.header(request, "cookie") || "")
    |> String.split(";")
    |> Enum.find_value("", fn part ->
      [key | rest] = String.split(JS.trim(part), "=")
      if key == name, do: Enum.join(rest, "=")
    end)
  end

  defp secure?(request),
    do: Url.new(request.url).protocol == "https:" or Request.header(request, "x-forwarded-proto") == "https"

  # An error the dashboard words in its own language, as the routes send them.
  defp coded(error, code, status, params \\ nil) do
    body = JS.obj(error: error, code: code)
    body = if params, do: Object.put(body, "params", JS.obj(params)), else: body

    Response.new(JS.stringify(body), status, [
      {"content-type", "application/json; charset=utf-8"},
      {"cache-control", "no-store"},
      {"x-content-type-options", "nosniff"}
    ])
  end

  defp esc(s), do: JS.escape_html(s)

  # Only a path on this install, so a sign-in can never send someone elsewhere.
  defp safe_next(web, value) do
    cond do
      value in [nil, ""] or not String.starts_with?(value, "/") or Regex.match?(~r/[\x00-\x1f\x7f\\]/, value) ->
        home_path(web)

      true ->
        case Url.parse(value, "http://runlight.invalid") do
          %Url{} = url ->
            if Url.origin(url) == "http://runlight.invalid",
              do: url.pathname <> url.search <> url.hash,
              else: home_path(web)

          nil ->
            home_path(web)
        end
    end
  end

  @doc "The signed-in account for a request, or nil."
  def signed_in(web, request) do
    case read_cookie(request, Accounts.session_cookie()) do
      "" ->
        nil

      value ->
        case JS.decode_uri_component(value) do
          nil -> raise "URI malformed"
          decoded -> Accounts.from_session(web.accounts, decoded, now(web))
        end
    end
  end

  defp drop_tokens_of(web, id) do
    store = web.rl.store

    for %{key: key, value: value} <- Store.settings_starting_with(store, @made_by), value == id do
      Store.delete_token(store, String.replace_prefix(key, @made_by, ""))
      Store.set_setting(store, key, nil)
    end

    :ok
  end

  defp session_cookie(web, request, value, max_age) do
    "#{Accounts.session_cookie()}=#{JS.encode_uri_component(value)}; Path=#{cookie_path(web)}; HttpOnly; SameSite=Lax; Max-Age=#{max_age}#{if secure?(request), do: "; Secure", else: ""}"
  end

  # The redirect after signing in: a session, and the mark that this browser has signed in to the account.
  defp signed_in_to(web, request, user, next) do
    Response.new(nil, 303, [
      {"location", next},
      {"cache-control", "no-store"},
      {"set-cookie",
       session_cookie(
         web,
         request,
         Accounts.session_for(web.accounts, user, now(web)),
         div(Accounts.session_ms(), 1000)
       )},
      {"set-cookie",
       "#{@device_cookie}=#{JS.encode_uri_component(Accounts.device_for(web.accounts, user))}; Path=#{cookie_path(web)}; HttpOnly; SameSite=Lax; Max-Age=#{365 * 86_400}#{if secure?(request), do: "; Secure", else: ""}"}
    ])
  end

  defp html(body, status \\ 200), do: Response.new(body, status, @html)

  defp redirect(location, extra \\ []),
    do: Response.new(nil, 303, [{"location", location}, {"cache-control", "no-store"}] ++ extra)

  defp reply(body, status \\ 200, extra \\ []) do
    Response.new(
      JS.stringify(body),
      status,
      [{"content-type", "application/json; charset=utf-8"}, {"cache-control", "no-store"}] ++ extra
    )
  end

  defp person(u),
    do:
      JS.obj(
        id: u["id"],
        email: u["email"],
        role: u["role"],
        createdAt: u["createdAt"],
        twoFactor: u["twoFactor"],
        recoveryLeft: u["recoveryLeft"]
      )

  defp invite_view(i),
    do:
      JS.obj(
        id: i["id"],
        email: i["email"],
        role: i["role"],
        invitedBy: i["invitedBy"],
        createdAt: i["createdAt"],
        expiresAt: i["expiresAt"]
      )

  # A JSON body by its media type, which a cross-site form cannot send.
  defp body(request) do
    type = (Request.header(request, "content-type") || "") |> String.split(";") |> hd() |> JS.trim() |> JS.lower()

    if type == "application/json" do
      case Request.json(request) do
        {:ok, %Object{} = parsed} -> parsed
        _ -> nil
      end
    end
  end

  defp form(request), do: SearchParams.parse(Request.text(request))
  defp field(form, name), do: SearchParams.get(form, name) || ""

  # The first account's gate: what the setup form must carry, or why there is no form.
  defp setup_ok?(web, given) do
    case web.first do
      :open -> true
      :locked -> false
      {:code, code} -> Crypto.same_text?(given, code)
      {:token, token} -> Crypto.same_text?(given, token)
    end
  end

  defp asks_for_token?(web), do: match?({:token, _}, web.first)

  defp setup_locked(web) do
    html(
      if(web.first == :locked, do: Pages.setup_needs_token_page(web.base), else: Pages.setup_locked_page(web.base)),
      403
    )
  end

  # Emails an invite through the mail service when there is one. The link always comes back too.
  defp send_invite(web, request, invite, code) do
    origin = home_origin(web) || Url.origin(Url.new(request.url))
    link = "#{origin}#{web.base}/invite?code=#{code}"
    host = Url.host(Url.new(origin))
    what = Pages.role_text(invite["role"])

    if Runlight.mail_settings(web.rl) == nil do
      [link: link, emailed: false]
    else
      try do
        Runlight.send_mail(web.rl, %{
          to: invite["email"],
          subject: "#{invite["invitedBy"]} invited you to Runlight",
          text:
            "#{invite["invitedBy"]} invited you to the Runlight at #{host} as #{what}.\n\nChoose a password to join:\n#{link}\n\nThe link works for seven days.\n",
          html:
            ~s(<div style="font:15px/1.6 -apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;color:#111827;max-width:480px"><p>#{esc(invite["invitedBy"])} invited you to the Runlight at #{esc(host)} as #{what}.</p><p><a href="#{esc(link)}" style="display:inline-block;padding:10px 18px;border-radius:8px;background:#111827;color:#ffffff;text-decoration:none;font-weight:600">Choose a password and join</a></p><p style="color:#6b7280;font-size:13px">The link works for seven days. If you were not expecting this, you can ignore it.</p></div>)
        })

        [link: link, emailed: true]
      rescue
        # The mail service's code and its details too, so the dashboard can say what went wrong in its own language.
        error ->
          base = [link: link, emailed: false, mailError: Exception.message(error)]

          case error do
            %{code: code} when is_binary(code) ->
              base ++ [mailCode: code, mailParams: JS.obj(Map.get(error, :params) || %{})]

            _ ->
              base
          end
      end
    end
  end

  # Emails a sign-in link to an account held up by others' failed tries, at most once a minute. Only to the
  # install's own address, never the Host of the request, so without one known there is no link.
  defp send_link(web, user, next) do
    origin = home_origin(web)
    key = {:web, web.id, :link_sent, user["id"]}

    cond do
      origin == nil ->
        false

      now(web) - (State.get(table(web), key) || 0) < 60_000 ->
        true

      true ->
        State.put(table(web), key, now(web))
        params = SearchParams.to_string([{"ticket", Accounts.link_for(web.accounts, user, now(web))}, {"next", next}])
        link = "#{origin}#{web.base}/login/link?#{params}"
        host = Url.host(Url.new(origin))

        Runlight.send_mail(web.rl, %{
          to: user["email"],
          subject: "Sign in to Runlight",
          text:
            "Someone, most likely you, signed in to Runlight at #{host} with your password while your account was held up by too many failed tries.\n\nSign in with this link within fifteen minutes:\n#{link}\n\nIf this was not you, change your password, since someone knows it.\n",
          html:
            ~s(<div style="font:15px/1.6 -apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;color:#111827;max-width:480px"><p>Someone, most likely you, signed in to Runlight at #{esc(host)} with your password while your account was held up by too many failed tries.</p><p><a href="#{esc(link)}" style="display:inline-block;padding:10px 18px;border-radius:8px;background:#111827;color:#ffffff;text-decoration:none;font-weight:600">Sign in</a></p><p style="color:#6b7280;font-size:13px">The link works for fifteen minutes. If this was not you, change your password, since someone knows it.</p></div>)
        })

        true
    end
  end

  defp pages(web, request, path) do
    url = Url.new(request.url)
    method = request.method
    base = web.base
    acc = web.accounts

    cond do
      path == "/auth.css" ->
        Response.new(Pages.auth_css(), 200, [
          {"content-type", "text/css; charset=utf-8"},
          {"cache-control", "public, max-age=3600"}
        ])

      path == "/auth.js" ->
        Response.new(Pages.auth_js(), 200, [
          {"content-type", "application/javascript; charset=utf-8"},
          {"cache-control", "public, max-age=3600"}
        ])

      path == "/setup" ->
        setup(web, request, url, method)

      path == "/login" ->
        login(web, request, url, method)

      # The link a locked account's owner is emailed: the code step with two-factor on, else straight in.
      path == "/login/link" and method == "GET" ->
        q = Url.search_params(url)
        next = safe_next(web, SearchParams.get(q, "next"))

        case Accounts.from_link(acc, SearchParams.get(q, "ticket") || "", now(web)) do
          nil ->
            html(
              Pages.login_page(base, %{
                error: "That sign-in link has run out. Sign in again.",
                next: next,
                forgot: web.forgot
              }),
              410
            )

          user ->
            if user["twoFactor"],
              do: html(Pages.code_page(base, %{pending: Accounts.pending_for(acc, user, now(web)), next: next})),
              else: signed_in_to(web, request, user, next)
        end

      path == "/login/code" and method == "POST" ->
        form = form(request)
        next = safe_next(web, SearchParams.get(form, "next"))
        pending_text = field(form, "pending")

        case Accounts.from_pending(acc, pending_text, now(web)) do
          nil ->
            redirect("#{base}/login?next=#{JS.encode_uri_component(next)}")

          %{user: user, real: real} ->
            # Counted before the check, so a burst cannot get past five.
            cond do
              not Throttle.take(web.throttles.code_tries, user["id"], now(web)) ->
                html(
                  Pages.code_page(base, %{
                    pending: pending_text,
                    next: next,
                    error: "Too many tries. Wait fifteen minutes and try again."
                  }),
                  429
                )

              not real or not Accounts.check_second_factor(acc, user["id"], field(form, "code"), now(web)) ->
                html(
                  Pages.code_page(base, %{
                    pending: pending_text,
                    next: next,
                    error: "That code is not right. Check the time on your phone, or use a recovery code."
                  }),
                  401
                )

              true ->
                Throttle.clear(web.throttles.code_tries, user["id"])
                signed_in_to(web, request, user, next)
            end
        end

      path == "/logout" ->
        redirect("#{base}/login", [{"set-cookie", session_cookie(web, request, "", 0)}])

      path == "/invite" ->
        invite_page(web, request, url, method)

      true ->
        nil
    end
  end

  defp setup(web, request, url, method) do
    base = web.base
    acc = web.accounts
    asks = asks_for_token?(web)

    cond do
      has_account(web) ->
        redirect("#{base}/login")

      method == "GET" ->
        code = SearchParams.get(Url.search_params(url), "code") || ""

        cond do
          web.first == :locked -> setup_locked(web)
          # The app's token is typed in; the server's code comes in the link it printed.
          asks or web.first == :open -> html(Pages.setup_page(base, %{code: "", ask_code: asks}))
          setup_ok?(web, code) -> html(Pages.setup_page(base, %{code: code}))
          true -> setup_locked(web)
        end

      method == "POST" ->
        form = form(request)
        code = field(form, "code")
        email = field(form, "email")

        cond do
          not setup_ok?(web, code) ->
            if asks,
              do:
                html(
                  Pages.setup_page(base, %{
                    code: "",
                    ask_code: true,
                    error: "That is not this app's RUNLIGHT_TOKEN.",
                    email: email
                  }),
                  403
                ),
              else: setup_locked(web)

          # Asked twice, since a typo here would lock the first owner out.
          field(form, "password") != field(form, "again") ->
            html(
              Pages.setup_page(base, %{
                code: if(asks, do: "", else: code),
                ask_code: asks,
                error: "The two passwords are not the same.",
                email: email
              }),
              400
            )

          true ->
            try do
              user = Accounts.set_password(acc, email, field(form, "password"), now(web))
              State.put(table(web), {:web, web.id, :existing}, true)

              redirect(home_path(web), [
                {"set-cookie",
                 session_cookie(
                   web,
                   request,
                   Accounts.session_for(acc, user, now(web)),
                   div(Accounts.session_ms(), 1000)
                 )}
              ])
            rescue
              error in AccountError ->
                html(
                  Pages.setup_page(base, %{
                    code: if(asks, do: "", else: code),
                    ask_code: asks,
                    error: error.message,
                    email: email
                  }),
                  400
                )
            end
        end

      true ->
        nil
    end
  end

  defp login(web, request, url, method) do
    base = web.base
    acc = web.accounts

    cond do
      not has_account(web) ->
        cond do
          web.first == :locked -> setup_locked(web)
          web.first == :open or asks_for_token?(web) -> redirect("#{base}/setup")
          true -> setup_locked(web)
        end

      method == "GET" ->
        html(
          Pages.login_page(base, %{
            next: safe_next(web, SearchParams.get(Url.search_params(url), "next")),
            forgot: web.forgot
          })
        )

      method == "POST" ->
        form = form(request)
        email = field(form, "email")
        password = field(form, "password")
        next = safe_next(web, SearchParams.get(form, "next"))
        account = email |> JS.trim() |> JS.lower()
        ip = Runlight.client_ip(web.rl, request)
        pair = "#{account}\n#{if ip == "", do: "unknown", else: ip}"
        login_page = fn opts -> Pages.login_page(base, Map.merge(opts, %{next: next, forgot: web.forgot})) end

        too_many = fn ->
          html(login_page.(%{error: "Too many tries. Wait fifteen minutes and try again.", email: email}), 429)
        end

        if not Throttle.take(web.throttles.per_address, pair, now(web)) do
          too_many.()
        else
          # A browser that signed in to the account before is never held up by others' failures.
          known = Accounts.by_email(acc, account)
          trusted = known != nil and Accounts.trusts_device(acc, read_cookie(request, @device_cookie), known)
          over = not trusted and not Throttle.take(web.throttles.per_account, account, now(web))

          # Past the account's limit, a right password and a wrong one get the same answer. With two-factor on, both
          # reach the code step, where a wrong password's ticket never passes. Without it, a right password emails a
          # sign-in link.
          if over and not (known != nil and known["twoFactor"]) do
            if Runlight.mail_settings(web.rl) == nil or home_origin(web) == nil do
              too_many.()
            else
              user = Accounts.sign_in(acc, email, password)

              if user do
                # Sent after the answer, so a right password is no slower than a wrong one.
                State.later(table(web), fn ->
                  try do
                    send_link(web, user, next)
                  rescue
                    error -> Logger.error("Runlight: could not send a sign-in link #{Exception.message(error)}")
                  end
                end)
              end

              html(
                login_page.(%{
                  error:
                    "Too many tries for this account. If the password was right, a link to sign in is on its way to its email address.",
                  email: email
                }),
                429
              )
            end
          else
            case Accounts.sign_in(acc, email, password) do
              nil ->
                if over and known,
                  do: html(Pages.code_page(base, %{pending: Accounts.decoy_for(acc, known, now(web)), next: next})),
                  else:
                    html(login_page.(%{error: "That email and password do not match an account.", email: email}), 401)

              user ->
                Throttle.clear(web.throttles.per_address, pair)
                if not over and not trusted, do: Throttle.forgive(web.throttles.per_account, account)

                # With two-factor on, the password only earns the second step.
                if user["twoFactor"],
                  do: html(Pages.code_page(base, %{pending: Accounts.pending_for(acc, user, now(web)), next: next})),
                  else: signed_in_to(web, request, user, next)
            end
          end
        end

      true ->
        nil
    end
  end

  defp invite_page(web, request, url, method) do
    base = web.base
    acc = web.accounts

    case method do
      "GET" ->
        code = SearchParams.get(Url.search_params(url), "code") || ""

        case Accounts.invite_by_code(acc, code, now(web)) do
          nil ->
            html(Pages.invite_gone_page(base), 410)

          invite ->
            html(
              Pages.invite_page(base, %{code: code, email: invite["email"], role: invite["role"], host: Url.host(url)})
            )
        end

      "POST" ->
        form = form(request)
        code = field(form, "code")

        case Accounts.invite_by_code(acc, code, now(web)) do
          nil ->
            html(Pages.invite_gone_page(base), 410)

          invite ->
            again = fn error ->
              html(
                Pages.invite_page(base, %{
                  code: code,
                  email: invite["email"],
                  role: invite["role"],
                  host: Url.host(url),
                  error: error
                }),
                400
              )
            end

            if field(form, "password") != field(form, "again") do
              again.("The two passwords are not the same.")
            else
              try do
                user = Accounts.accept_invite(acc, code, field(form, "password"), now(web))
                State.put(table(web), {:web, web.id, :existing}, true)

                redirect(home_path(web), [
                  {"set-cookie",
                   session_cookie(
                     web,
                     request,
                     Accounts.session_for(acc, user, now(web)),
                     div(Accounts.session_ms(), 1000)
                   )}
                ])
              rescue
                error in AccountError -> again.(error.message)
              end
            end
        end

      _ ->
        nil
    end
  end

  # Your own account, and for the owner and admins, everyone else's.
  defp api(web, request, path) do
    case signed_in(web, request) do
      nil -> coded("Sign in first", "sign_in", 401)
      user -> api_for(web, request, path, user)
    end
  end

  defp api_for(web, request, path, user) do
    acc = web.accounts
    method = request.method
    type = (Request.header(request, "content-type") || "") |> String.split(";") |> hd() |> JS.trim() |> JS.lower()

    recheck = fn input, name, {message, code} ->
      cond do
        not Throttle.take(web.throttles.rechecks, user["id"], now(web)) ->
          coded("Too many tries. Wait fifteen minutes and try again.", "too_many_tries", 429)

        Accounts.sign_in(acc, user["email"], input |> JS.prop(name) |> JS.nullish("") |> JS.string()) == nil ->
          coded(message, code, 400)

        true ->
          Throttle.forgive(web.throttles.rechecks, user["id"])
          nil
      end
    end

    reset = Regex.run(~r/\A\/api\/people\/([a-f0-9]{24})\/2fa\z/, path)
    hand_over = Regex.run(~r/\A\/api\/people\/([a-f0-9]{24})\/owner\z/, path)
    invite_match = Regex.run(~r/\A\/api\/invites\/([a-f0-9]{24})(\/resend)?\z/, path)
    match = Regex.run(~r/\A\/api\/people\/([a-f0-9]{24})\z/, path)

    cond do
      # Writes must be JSON, which a form on another page cannot send, even those with no body.
      method == "POST" and type != "application/json" ->
        coded("Send JSON", "send_json", 415)

      path == "/api/account" and method == "GET" ->
        reply(JS.obj(account: person(user)))

      path == "/api/account/password" and method == "POST" ->
        case body(request) do
          nil ->
            coded("Send JSON", "send_json", 415)

          input ->
            case recheck.(input, "current", {"Your current password is not right", "password_current_wrong"}) do
              nil ->
                try do
                  updated =
                    Accounts.set_password(
                      acc,
                      user["email"],
                      input |> JS.prop("next") |> JS.nullish("") |> JS.string(),
                      now(web)
                    )

                  # The new password ends every other sign-in; this browser gets a fresh one.
                  reply(JS.obj(ok: true), 200, [{"set-cookie", fresh_session(web, request, updated)}])
                rescue
                  error in AccountError -> coded(error.message, error.code, 400, error.params)
                end

              refused ->
                refused
            end
        end

      # Two-factor: turning it on, confirming the first code, new recovery codes, and turning it off. Each change asks
      # for the password again, so a browser left signed in cannot quietly change it.
      String.starts_with?(path, "/api/account/2fa") and method == "POST" ->
        case body(request) do
          nil -> coded("Send JSON", "send_json", 415)
          input -> two_factor(web, request, user, input, String.replace_prefix(path, "/api/account/2fa", ""), recheck)
        end

      user["role"] not in ["owner", "admin"] ->
        coded("Only the owner or an admin can manage people", "people_owner", 403)

      # The owner or an admin can turn off someone else's two-factor, though never the owner's.
      reset && method == "DELETE" ->
        target_id = Enum.at(reset, 1)

        if target_id == user["id"] do
          coded("Turn off your own two-factor sign-in under Account", "twofactor_self", 400)
        else
          case body(request) do
            nil ->
              coded("Send JSON", "send_json", 415)

            input ->
              case recheck.(input, "password", {"Your password is not right", "password_wrong"}) do
                nil ->
                  case Accounts.by_id(acc, target_id) do
                    nil ->
                      coded("Unknown account", "unknown_account", 404)

                    %{} = target ->
                      if target["role"] == "owner" do
                        coded("Only the owner can change the owner's account", "owner_protected", 403)
                      else
                        Accounts.disable_two_factor(acc, target_id)
                        reply(JS.obj(ok: true))
                      end
                  end

                refused ->
                  refused
              end
          end
        end

      # The owner hands ownership to an admin and becomes an admin, after typing their password again.
      hand_over && method == "POST" ->
        if user["role"] != "owner" do
          coded("Only the owner can hand over ownership", "owner_hand_over", 403)
        else
          case body(request) do
            nil ->
              coded("Send JSON", "send_json", 415)

            input ->
              case recheck.(input, "password", {"Your password is not right", "password_wrong"}) do
                nil ->
                  try do
                    Accounts.hand_over(acc, user["id"], Enum.at(hand_over, 1))
                    reply(JS.obj(people: Enum.map(Accounts.list(acc), &person/1)))
                  rescue
                    error in AccountError ->
                      coded(
                        error.message,
                        error.code,
                        if(error.code == "unknown_account", do: 404, else: 400),
                        error.params
                      )
                  end

                refused ->
                  refused
              end
          end
        end

      path == "/api/people" and method == "GET" ->
        reply(
          JS.obj(
            people: Enum.map(Accounts.list(acc), &person/1),
            invites: Enum.map(Accounts.invites(acc, now(web)), &invite_view/1)
          )
        )

      path == "/api/people" and method == "POST" ->
        case body(request) do
          nil ->
            coded("Send JSON", "send_json", 415)

          input ->
            role = role_of(JS.prop(input, "role"))
            email = input |> JS.prop("email") |> JS.nullish("") |> JS.string() |> JS.trim() |> JS.lower()

            cond do
              role == nil ->
                coded("Pick admin, member, or viewer", "role_needed", 400)

              Accounts.by_email(acc, email) != nil ->
                coded("#{email} already has an account", "account_exists", 409, email: email)

              true ->
                try do
                  %{invite: invite, code: code} = Accounts.invite(acc, email, role, user["email"], now(web))
                  reply(JS.obj([invite: invite_view(invite)] ++ send_invite(web, request, invite, code)), 201)
                rescue
                  error in AccountError -> coded(error.message, error.code, 400, error.params)
                end
            end
        end

      invite_match && method == "DELETE" && Enum.at(invite_match, 2, "") == "" ->
        if Accounts.cancel_invite(acc, Enum.at(invite_match, 1)),
          do: reply(JS.obj(ok: true)),
          else: coded("Unknown invite", "unknown_invite", 404)

      invite_match && method == "POST" && Enum.at(invite_match, 2, "") != "" ->
        case Enum.find(Accounts.invites(acc, now(web)), &(&1["id"] == Enum.at(invite_match, 1))) do
          nil ->
            coded("Unknown invite", "unknown_invite", 404)

          old ->
            # A new link replaces the old one, which stops working.
            %{invite: invite, code: code} = Accounts.invite(acc, old["email"], old["role"], user["email"], now(web))
            reply(JS.obj([invite: invite_view(invite)] ++ send_invite(web, request, invite, code)))
        end

      match && method in ["PATCH", "DELETE"] ->
        id = Enum.at(match, 1)

        try do
          if method == "DELETE" do
            if id == user["id"] do
              coded("You cannot remove yourself", "remove_self", 400)
            else
              Accounts.remove(acc, id)
              # The tokens they made, and the apps they connected, stop working with them.
              drop_tokens_of(web, id)
              reply(JS.obj(ok: true))
            end
          else
            case body(request) do
              nil ->
                coded("Send JSON", "send_json", 415)

              input ->
                case role_of(JS.prop(input, "role")) do
                  nil ->
                    coded("Pick admin, member, or viewer", "role_needed", 400)

                  role ->
                    changed = Accounts.set_role(acc, id, role)
                    # A viewer changes nothing, so the tokens they made before go too.
                    if role == "viewer", do: drop_tokens_of(web, id)
                    reply(JS.obj(person: person(changed)))
                end
            end
          end
        rescue
          error in AccountError ->
            status =
              case error.code do
                "unknown_account" -> 404
                "owner_protected" -> 403
                _ -> 400
              end

            coded(error.message, error.code, status, error.params)
        end

      true ->
        coded("Not found", "not_found", 404)
    end
  end

  # Nobody is invited as, or made, the owner: there is one, and they hand it over themselves.
  defp role_of(value) when value in ["admin", "member", "viewer"], do: value
  defp role_of(_), do: nil

  defp fresh_session(web, request, user) do
    session_cookie(web, request, Accounts.session_for(web.accounts, user, now(web)), div(Accounts.session_ms(), 1000))
  end

  defp two_factor(web, request, user, input, action, recheck) do
    acc = web.accounts

    if action == "/confirm" do
      # Confirming asks for no password, so it has its own few tries, after which the set-up starts again.
      if not Throttle.take(web.throttles.confirm_tries, user["id"], now(web)) do
        Accounts.cancel_two_factor_setup(acc, user["id"])
        coded("Too many wrong codes. Start turning on two-factor sign-in again.", "twofactor_restart", 429)
      else
        code = input |> JS.prop("code") |> JS.nullish("") |> JS.string() |> String.replace(~r/\s/u, "")

        case Accounts.confirm_two_factor(acc, user["id"], code, now(web)) do
          nil ->
            coded("That code is not right. Check the time on your phone and try the next one.", "code_wrong", 400)

          codes ->
            Throttle.clear(web.throttles.confirm_tries, user["id"])
            # Turning it on signs out every other browser; this one gets a new session.
            updated = Accounts.by_id(acc, user["id"])
            reply(JS.obj(recovery: codes), 200, [{"set-cookie", fresh_session(web, request, updated)}])
        end
      end
    else
      case recheck.(input, "password", {"Your password is not right", "password_wrong"}) do
        nil ->
          case action do
            "/start" ->
              Throttle.clear(web.throttles.confirm_tries, user["id"])
              secret = Accounts.start_two_factor(acc, user["id"])

              reply(
                JS.obj(secret: secret, uri: Crypto.otpauth_uri(secret, user["email"], Url.host(Url.new(request.url))))
              )

            "/recovery" ->
              if user["twoFactor"],
                do: reply(JS.obj(recovery: Accounts.new_recovery_codes(acc, user["id"]))),
                else: coded("Turn on two-factor sign-in first", "twofactor_off", 400)

            "/disable" ->
              Accounts.disable_two_factor(acc, user["id"])
              # Sessions follow two-factor's state, so this browser gets a new one and stays signed in.
              updated = Accounts.by_id(acc, user["id"])
              reply(JS.obj(ok: true), 200, [{"set-cookie", fresh_session(web, request, updated)}])

            _ ->
              coded("Not found", "not_found", 404)
          end

        refused ->
          refused
      end
    end
  end

  @doc "What a signed-in person may do: everything (owner and admin), \"member\", \"read\" (viewer), or nothing."
  @spec access(t(), Request.t()) :: true | false | String.t()
  def access(web, request) do
    case signed_in(web, request) do
      nil -> false
      %{} = user -> access_of(user["role"])
    end
  end

  # A member changes everything but the install-wide controls; a viewer reads every site and changes nothing.
  defp access_of(role) when role in ["owner", "admin"], do: true
  defp access_of("member"), do: "member"
  defp access_of(_), do: "read"

  @doc "The account a request comes from, or nil."
  def account_of(web, request) do
    case signed_in(web, request) do
      nil -> nil
      user -> user["id"]
    end
  end

  @doc "Notes who made a token. False when they can no longer make one (a viewer, or gone), which takes it back."
  def token_made(web, token, by) do
    case Accounts.by_id(web.accounts, by) do
      nil ->
        false

      user ->
        if user["role"] == "viewer" do
          false
        else
          Store.set_setting(web.rl.store, "#{@made_by}#{token["id"]}", by)
          true
        end
    end
  end

  @doc "Answers an account page or API request at a path under the base, or nil for anything else."
  @spec handle(t(), Request.t(), String.t()) :: Response.t() | nil
  def handle(web, request, path) do
    cond do
      path in ["/api/account", "/api/people"] or String.starts_with?(path, "/api/account/") or
        String.starts_with?(path, "/api/people/") or
          String.starts_with?(path, "/api/invites/") ->
        api(web, request, path)

      true ->
        case pages(web, request, path) do
          nil -> dashboard(web, request, path)
          page -> page
        end
    end
  end

  defp dashboard(web, request, path) do
    cond do
      # The dashboard itself: straight to sign-in, or to setting up the first account.
      path in ["/", ""] and request.method == "GET" and signed_in(web, request) == nil ->
        if has_account(web) do
          search = Url.new(request.url).search
          next = if search != "", do: "?next=#{JS.encode_uri_component("#{home_path(web)}#{search}")}", else: ""
          redirect("#{web.base}/login#{next}")
        else
          if web.first == :open or asks_for_token?(web), do: redirect("#{web.base}/setup"), else: setup_locked(web)
        end

      true ->
        nil
    end
  end
end
