defmodule Runlight.Routes do
  @moduledoc """
  The dashboard, its JSON API, the tracker's script and endpoint, short
  links' API, OAuth, and the MCP server, under one base path (the SDK's
  routes.ts). Every answer is the SDK's byte for byte.

  Make them with `Runlight.routes/2` and answer a request with `handle/2`;
  `Runlight.Plug` does both for a Phoenix router or a `Plug.Router`.

  Options, the SDK's in snake case:

    * `:base_path` - where the routes are mounted, default "/runlight".
    * `:token` - required to read stats, sent as `Authorization: Bearer
      <token>`, or once as `?token=<token>`, which moves it into a cookie.
      Left out (or nil), it is `RUNLIGHT_TOKEN`. `false` leaves the routes
      open, for routes behind the app's own authentication. Without a token
      the dashboard runs open only in development, and answers 503 elsewhere.
    * `:authorize` - your own check instead of a token, a function of the
      request answering true, "member", "read", or false.
    * `:accounts` - true for sign-in accounts, with people and roles.
    * `:cron_secret` - also taken as a bearer on /api/check; default
      `CRON_SECRET`.
    * `:observe_key` - lets CMS plugins report AI agent fetches; default
      `RUNLIGHT_OBSERVE_KEY`.
    * `:origin` - the address people open the app at, such as
      "https://example.com".
    * `:sign_in`, `:sign_out`, `:geo_credit`, `:own_hosts` - as the SDK's.
  """

  alias Runlight.Assets
  alias Runlight.Crypto
  alias Runlight.Errors
  alias Runlight.Goals
  alias Runlight.Hash
  alias Runlight.Http.Headers
  alias Runlight.Http.Request
  alias Runlight.Http.Response
  alias Runlight.JS
  alias Runlight.JS.Object
  alias Runlight.Messages
  alias Runlight.Query
  alias Runlight.SearchParams
  alias Runlight.State
  alias Runlight.Store
  alias Runlight.Time
  alias Runlight.Url
  alias Runlight.Zip

  require Logger

  defstruct [
    :rl,
    :id,
    :base,
    :token,
    :cron_secret,
    :observe_key,
    :origin,
    :web,
    :authorize,
    :sign_in,
    :sign_out,
    :geo_credit,
    :own_hosts,
    :account_of,
    :token_made
  ]

  @type t :: %__MODULE__{}

  @cookie "runlight_token"
  @implementation [library: "runlight", language: "elixir"]
  # API tokens start with this, so they are told apart from the main token.
  @token_prefix "rl_"
  # The header a shared dashboard sends its share id in.
  @share_header "x-runlight-share"
  @shared_paths MapSet.new(
                  ~w(/api/sites /api/icon /api/realtime /api/stats /api/series /api/rhythm /api/breakdown /api/goals /api/event-props /api/export /api/funnels /api/journeys)
                )
  @rules_placeholder ~s("__RUNLIGHT_RULES__")
  @pick_target_placeholder ~s("__RUNLIGHT_PICK_TARGET__")
  @pick_hosts_placeholder ~s("__RUNLIGHT_PICK_HOSTS__")
  @pick_ticket_ms 30 * 60_000
  @ask_per_hour 30
  @ask_at_once 2
  @viewer_daily 50
  @dashboard_csp "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

  @doc "A domain name, such as go.example.com."
  def domain_name?(value),
    do: is_binary(value) and Regex.match?(~r/\A(?=.{1,253}\z)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z/, value)

  defp shared_path?(path), do: MapSet.member?(@shared_paths, path) or Regex.match?(~r/\A\/api\/goals\/[a-f0-9]{24}\z/, path)

  @doc """
  What a manage token, held by a Runlight hub, may read and change: one
  site's goals, funnels, short links, link domains, email reports, and share
  links, along with its name, timezone, and retention, and tickets for the
  element picker.
  """
  def manage_path?(method, path) do
    cond do
      Regex.match?(~r/^\/api\/links\/import/, path) -> false
      Regex.match?(~r/^\/api\/(links|link-domains|reports|goals|funnels|shares)(\/|$)/, path) -> true
      path == "/api/pick" -> method == "POST"
      path == "/api/mail" -> method == "GET"
      Regex.match?(~r/\A\/api\/sites\/[^\/]+\z/, path) -> method == "PATCH"
      true -> false
    end
  end

  ## Making the routes

  @doc false
  @spec new(Runlight.t(), keyword()) :: t()
  def new(rl, opts) do
    base = normalise_base(Keyword.get(opts, :base_path, "/runlight"))

    token =
      case Keyword.fetch(opts, :token) do
        {:ok, false} -> false
        {:ok, t} when is_binary(t) -> t
        _ -> Runlight.env("RUNLIGHT_TOKEN")
      end

    cron_secret = if Keyword.has_key?(opts, :cron_secret), do: Keyword.get(opts, :cron_secret), else: Runlight.env("CRON_SECRET")
    observe_key = if Keyword.has_key?(opts, :observe_key), do: Keyword.get(opts, :observe_key), else: Runlight.env("RUNLIGHT_OBSERVE_KEY")
    origin = if Keyword.get(opts, :origin) not in [nil, ""], do: Url.origin(Url.new(Keyword.get(opts, :origin)))
    # A link domain leaves these paths to the app, so the dashboard stays reachable on every name.
    Runlight.add_route_base(rl, if(base == "", do: "/", else: base))

    # Accounts: an app turns them on with true. Sessions need a secret that outlives the process; in development
    # without one, a made-up one does, so a restart signs everyone out. An app left open on purpose (token false) is
    # treated like development here.
    open_setup = token == false or (token in [nil, ""] and development?())
    account_secret = rl.secret || if(open_setup, do: Hash.random_id(32))

    web =
      case Keyword.get(opts, :accounts) do
        true when account_secret != nil ->
          Runlight.Accounts.Web.new(
            runlight: rl,
            secret: account_secret,
            base: base,
            now: fn -> Runlight.now(rl) end,
            first_account:
              cond do
                is_binary(token) and token != "" -> {:token, token}
                open_setup -> :open
                true -> :locked
              end,
            home: if(Keyword.get(opts, :origin) not in [nil, ""], do: fn -> origin end),
            forgot: "https://runlight.sh/docs/configuration/#accounts"
          )

        %{__struct__: Runlight.Accounts.Web} = given ->
          given

        _ ->
          nil
      end

    sign_in = Keyword.get(opts, :sign_in) || if(web, do: "#{base}/login")
    sign_out = Keyword.get(opts, :sign_out) || if(web, do: "#{base}/logout")

    %__MODULE__{
      rl: rl,
      id: :erlang.unique_integer([:positive]),
      base: base,
      token: token,
      cron_secret: cron_secret,
      observe_key: observe_key,
      origin: origin,
      web: web,
      authorize: Keyword.get(opts, :authorize),
      sign_in: sign_in,
      sign_out: sign_out,
      geo_credit: Keyword.get(opts, :geo_credit, false),
      own_hosts: Keyword.get(opts, :own_hosts),
      account_of: Keyword.get(opts, :account_of) || if(web, do: &Runlight.Accounts.Web.account_of(web, &1)),
      token_made: Keyword.get(opts, :token_made) || if(web, do: &Runlight.Accounts.Web.token_made(web, &1, &2))
    }
  end

  @doc "Whether the app runs in development: NODE_ENV or RUNLIGHT_ENV is \"development\", or Mix runs in :dev."
  @spec development?() :: boolean()
  def development? do
    Runlight.env("NODE_ENV") == "development" or Runlight.env("RUNLIGHT_ENV") == "development" or
      (Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and apply(Mix, :env, []) == :dev)
  end

  defp normalise_base(path) do
    trimmed = "/" <> String.replace(path, ~r/^\/+|\/+$/, "")
    if trimmed == "/", do: "", else: trimmed
  end

  ## Answers

  @doc """
  An error the dashboard can show in its own language: `code` names it and
  `params` fill its placeholders, while `error` stays the English message.
  """
  def coded(error, code, status, params \\ nil, headers \\ []) do
    body = JS.obj(error: error, code: code)
    body = if params, do: Object.put(body, "params", JS.obj(params)), else: body
    json(body, status, headers)
  end

  # A refusal from a check elsewhere: its own code and params when the error carries them, or else `fallback` with
  # its English words as `detail`.
  defp refused(error, fallback, status \\ 400) do
    case error do
      %{code: code} when is_binary(code) -> coded(Exception.message(error), code, status, Map.get(error, :params) || %{})
      _ -> coded(Exception.message(error), fallback, status, %{"detail" => Exception.message(error)})
    end
  end

  defp json(body, status \\ 200, headers \\ []) do
    Response.new(
      JS.stringify(body),
      status,
      merge_headers(
        [{"content-type", "application/json; charset=utf-8"}, {"cache-control", "no-store"}, {"x-content-type-options", "nosniff"}],
        headers
      )
    )
  end

  # `{...defaults, ...extra}`: a name in `extra` takes the place of the same one in `defaults`.
  defp merge_headers(defaults, extra) do
    extra = Enum.map(extra, fn {k, v} -> {String.downcase(to_string(k)), v} end)

    Enum.reduce(extra, defaults, fn {k, v}, acc ->
      if List.keymember?(acc, k, 0), do: List.keyreplace(acc, k, 0, {k, v}), else: acc ++ [{k, v}]
    end)
  end

  defp escape_html(value), do: JS.escape_html(value)

  defp escape_attr(value), do: Regex.replace(~r/[&"<>]/, value, fn c -> "&##{:binary.first(c)};" end)

  # Whether a request's body is JSON by its media type.
  defp json?(request) do
    (Request.header(request, "content-type") || "") |> String.split(";") |> hd() |> JS.trim() |> JS.lower() == "application/json"
  end

  @doc "A Host or X-Forwarded-Host value as a bare name: lowercase, with no port, no final dot, and no www."
  def host_name(value) do
    first = value |> String.split(",") |> hd() |> JS.trim() |> JS.lower()

    name =
      if String.starts_with?(first, "["),
        do: JS.slice(first, 0, JS.index_of(first, "]") + 1),
        else: String.replace(first, ~r/:\d*\z/, "")

    name |> String.replace(~r/\.+\z/, "") |> String.replace(~r/^www\./, "")
  end

  # Whether a domain name is one kept for private networks or tests, or has an IPv4 address inside it.
  defp private_name?(domain) do
    Regex.match?(~r/(^|\.)\d{1,3}(\.\d{1,3}){3}(\.|$)/, domain) or
      Regex.match?(~r/\.(internal|intranet|private|local|localhost|localdomain|lan|home|corp|home\.arpa|arpa|test|invalid|example)\z/, domain)
  end

  defp small_page(lang, body, status \\ 200) do
    Response.new(
      ~s(<!doctype html><html lang="#{lang}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>Runlight</title>\n) <>
        ~s(<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#f4f4f5;font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;color:#111827}main{max-width:420px;margin:24px;padding:32px;background:#fff;border:1px solid #e5e7eb;border-radius:14px}h1{font-size:20px;margin:0 0 12px}p{margin:0 0 20px;color:#4b5563}button{height:40px;padding:0 18px;border:0;border-radius:8px;background:#111827;color:#fff;font:inherit;font-weight:600;cursor:pointer}</style></head><body><main>#{body}</main></body></html>),
      status,
      [
        {"content-type", "text/html; charset=utf-8"},
        {"cache-control", "no-store"},
        {"content-security-policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'"},
        {"referrer-policy", "no-referrer"}
      ]
    )
  end

  # The first language a browser asks for that the dashboard speaks, else English.
  defp accepted_language(request) do
    (Request.header(request, "accept-language") || "")
    |> String.split(",")
    |> Enum.find_value("en", fn part ->
      code = part |> String.split(";") |> hd() |> JS.trim() |> JS.slice(0, 2) |> JS.lower()
      if code in Messages.languages(), do: code
    end)
  end

  @path_dimensions ["page", "entry", "exit", "ai_page"]

  # Rows of objects as CSV, with a column for every key the first row has, in the units a spreadsheet reads.
  defp rows_csv(rows, sheet) do
    readable = Enum.map(rows, &sheet_row(&1, sheet))
    header = if readable == [], do: ["value"], else: Object.keys(hd(readable))
    Zip.csv(header, Enum.map(readable, fn r -> Enum.map(header, &JS.nullish(r[&1], nil)) end))
  end

  # One row for a spreadsheet: a bucket's start as the site's local date (and hour), rates as percents, durations
  # in seconds, and paths as people write them.
  defp sheet_row(row, sheet) do
    Enum.reduce(Object.to_list(row), Object.new(), fn {key, value}, out ->
      cond do
        key == "start" and is_number(value) ->
          hour =
            if sheet[:interval] == "hour",
              do: " #{JS.pad(elem(Time.local_weekday_hour(value, sheet.timezone), 1), 2)}:00",
              else: ""

          Object.put(out, "date", Time.local_date(value, sheet.timezone) <> hour)

        key == "bounceRate" and is_number(value) ->
          Object.put(out, "bounceRatePercent", JS.normalize(JS.round(value * 1000) / 10))

        key in ["visitDuration", "timeOnPage"] and is_number(value) ->
          Object.put(out, "#{key}Seconds", JS.round(value / 1000))

        key == "value" and is_binary(value) and sheet[:dimension] in @path_dimensions ->
          Object.put(out, "value", Runlight.Sources.readable_path(value))

        true ->
          Object.put(out, key, value)
      end
    end)
  end

  # A file to save, never shown in the browser or kept in a shared cache.
  defp download(name, body, type) do
    Response.new(body, 200, [
      {"content-type", type},
      {"content-disposition", ~s(attachment; filename="#{String.replace(name, ~r/[^A-Za-z0-9._-]/, "-")}")},
      {"cache-control", "private, no-store"}
    ])
  end

  defp cookie_value(token), do: Hash.sha256("runlight-cookie:#{token}")

  defp read_cookie(request, name) do
    (Request.header(request, "cookie") || "")
    |> String.split(";")
    |> Enum.find_value("", fn part ->
      [key | rest] = String.split(JS.trim(part), "=")
      if key == name, do: Enum.join(rest, "=")
    end)
  end

  defp bearer(request) do
    header = Request.header(request, "authorization") || ""
    if String.starts_with?(JS.lower(header), "bearer "), do: header |> JS.slice(7) |> JS.trim(), else: ""
  end

  defp locale_urls(base) do
    Assets.locale_codes()
    |> Enum.map(&{&1, "#{base}/assets/locale.#{&1}.#{Assets.locales_hash()}.json"})
    |> JS.obj()
    |> JS.stringify()
  end

  defp dashboard(base, share, sign_out, geo_credit, accounts, sign_in) do
    b = escape_attr(base)

    attrs =
      if(share != "", do: ~s( data-share="#{escape_attr(share)}"), else: "") <>
        if(sign_out not in [nil, ""], do: ~s( data-sign-out="#{escape_attr(sign_out)}"), else: "") <>
        if(sign_in not in [nil, ""], do: ~s( data-sign-in="#{escape_attr(sign_in)}"), else: "") <>
        if(geo_credit, do: ~s( data-geo-credit=""), else: "") <>
        if accounts, do: ~s( data-accounts=""), else: ""

    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="robots" content="noindex">
    <title>Runlight</title>
    <link rel="icon" href="#{Assets.icon()}">
    <link rel="stylesheet" href="#{b}/assets/app.#{Assets.dashboard_hash()}.css">
    </head>
    <body>
    <div id="app" data-base="#{b}"#{attrs} data-world="#{b}/assets/world.#{Assets.world_hash()}.json" data-locales="#{escape_attr(locale_urls(base))}"></div>
    <script type="module" src="#{b}/assets/app.#{Assets.dashboard_hash()}.js"></script>
    </body>
    </html>
    """
  end

  ## Per-request and per-routes state

  defp managed(request), do: Process.get({:runlight_managed, request.ref})
  defp set_managed(request, token), do: Process.put({:runlight_managed, request.ref}, token)
  defp member?(request), do: Process.get({:runlight_member, request.ref}) == true

  defp state(routes, key), do: State.get(routes.rl.table, {:routes, routes.id, key})
  defp put_state(routes, key, value), do: State.put(routes.rl.table, {:routes, routes.id, key}, value)

  # The controls a member cannot change: the mail service and its keys, the assistant's settings, and deleting a site.
  defp admin_only?(path, method) do
    (path == "/api/mail" and method in ["PUT", "DELETE"]) or
      (path == "/api/assistant" and method in ["PUT", "DELETE"]) or
      (path == "/api/assistant/limits" and method == "PUT") or
      (path == "/api/assistant/models" and method == "POST") or
      (Regex.match?(~r/\A\/api\/sites\/[^\/]+\z/, path) and method == "DELETE")
  end

  # Whether this request acts as the owner: true, "read" for someone signed in who may only read, false, or
  # "unconfigured".
  defp can_read(routes, request) do
    cond do
      managed(request) != nil ->
        true

      routes.authorize != nil or routes.web != nil ->
        given = bearer(request)

        if routes.authorize == nil and is_binary(routes.token) and routes.token != "" and given != "" and
             Crypto.constant_time_equal?(given, routes.token) do
          true
        else
          answer = if routes.authorize, do: routes.authorize.(request), else: Runlight.Accounts.Web.access(routes.web, request)
          if answer == "member", do: Process.put({:runlight_member, request.ref}, true)
          if answer == "read", do: "read", else: answer == true or answer == "member"
        end

      routes.token == false ->
        true

      routes.token in [nil, ""] ->
        # Fails closed: only a process that says it is in development runs open.
        if development?() do
          unless state(routes, :warned) do
            put_state(routes, :warned, true)

            Logger.warning(
              "Runlight: no RUNLIGHT_TOKEN set, so the dashboard is open because the app runs in development. Anywhere else it answers 503 until a token is set."
            )
          end

          true
        else
          "unconfigured"
        end

      true ->
        given = bearer(request)

        if given != "" and Crypto.constant_time_equal?(given, routes.token) do
          true
        else
          cookie = read_cookie(request, @cookie)
          cookie != "" and Crypto.constant_time_equal?(cookie, cookie_value(routes.token))
        end
    end
  end

  # An API token from the bearer header: read-only, and maybe limited to one site.
  defp api_token(routes, request) do
    given = bearer(request)

    if String.starts_with?(given, @token_prefix) do
      rl = routes.rl
      Runlight.init(rl)

      case Store.token_by_hash(rl.store, Hash.sha256(given)) do
        nil ->
          nil

        row ->
          now = Runlight.now(rl)
          # At most once a minute, so a busy assistant does not write on every call.
          if row["lastUsedAt"] == nil or now - row["lastUsedAt"] > 60_000, do: Store.touch_token(rl.store, row["id"], now)
          row
      end
    end
  end

  @empty_reader JS.obj(id: "", name: "", site: "", scope: "read", hash: "", hint: "", createdAt: 0, lastUsedAt: nil)

  # Who may read stats: the owner (true), an API token or a read-only sign-in, or nobody.
  defp reader(routes, request) do
    case api_token(routes, request) do
      nil ->
        access = can_read(routes, request)

        cond do
          routes.authorize != nil or routes.web != nil -> if access == "read", do: @empty_reader, else: access == true
          access == "read" -> false
          true -> access
        end

      token ->
        token
    end
  end

  defp origin_needed do
    coded(
      "Set this Runlight's own address first (RUNLIGHT_URL on the server, or origin in routes()), so a connected hub can add link domains and email reports.",
      "origin_needed",
      400
    )
  end

  defp denied("read"), do: coded("Only an owner can change this", "owner_only", 403)

  defp denied("unconfigured"),
    do:
      coded(
        "Set RUNLIGHT_TOKEN, or pass token or authorize to routes(). Without one, Runlight only runs open when NODE_ENV is development.",
        "token_unset",
        503
      )

  defp denied(_), do: coded("Unauthorized", "unauthorized", 401)

  defp query_site(routes, url) do
    case Runlight.site(routes.rl, SearchParams.get(Url.search_params(url), "site")) do
      nil -> {:error, coded("Unknown site", "unknown_site", 404)}
      site -> {:ok, site}
    end
  end

  defp read_query(routes, url, site) do
    q = Url.search_params(url)
    raw_filters = SearchParams.get_all(q, "filter")
    max = Query.max_filters()

    with :ok <- if(length(raw_filters) > max, do: {:error, coded("Use at most #{max} filters at once.", "filters_max", 400, %{"max" => "#{max}"})}, else: :ok),
         {:ok, filters} <- parse_filters(raw_filters) do
      rl = routes.rl
      now = Runlight.now(rl)

      first_date =
        if SearchParams.get(q, "period") == "all" do
          case Store.first_seen(rl.store, site["id"]) do
            nil -> nil
            first -> Time.local_date(first, site["timezone"])
          end
        end

      range =
        Time.resolve_range(
          %{
            period: SearchParams.get(q, "period"),
            from: SearchParams.get(q, "from"),
            to: SearchParams.get(q, "to"),
            interval: SearchParams.get(q, "interval")
          },
          site["timezone"],
          now,
          first_date
        )

      if range == nil do
        {:error, coded("Bad date range. Use period, or from and to as YYYY-MM-DD.", "range_bad", 400)}
      else
        query = %{site: site["id"], from: range.from, to: range.to, filters: filters}
        # compare=false is the older spelling of off.
        raw = SearchParams.get(q, "compare") || "previous"
        mode = if raw == "false", do: "off", else: raw

        if mode not in ["previous", "year", "custom", "off"] do
          {:error, coded(~s(Bad compare "#{raw}". Use previous, year, custom, or off.), "compare_bad", 400, %{"compare" => raw})}
        else
          compared =
            Time.compare_range(range, mode, site["timezone"], %{from: SearchParams.get(q, "compare_from"), to: SearchParams.get(q, "compare_to")})

          if mode == "custom" and compared == nil,
            do: {:error, coded("Bad comparison range. Use compare_from and compare_to as YYYY-MM-DD.", "compare_range_bad", 400)},
            else: {:ok, %{query: query, range: range, compared: compared}}
        end
      end
    end
  end

  defp parse_filters(raws) do
    Enum.reduce_while(raws, {:ok, []}, fn raw, {:ok, acc} ->
      case Query.parse_filter(raw) do
        nil ->
          {:halt, {:error, coded(~s(Bad filter "#{raw}". Use dimension:is|not|contains:value.), "filter_bad", 400, %{"filter" => raw})}}

        f ->
          {:cont, {:ok, acc ++ [f]}}
      end
    end)
  end

  defp read_json(request) do
    # A form posted from another site cannot carry this content type without CORS.
    if json?(request) do
      case Request.json(request) do
        {:ok, %Object{} = body} -> {:ok, body}
        _ -> {:error, coded("Send a JSON object", "send_object", 400)}
      end
    else
      {:error, coded("Send JSON", "send_json", 415)}
    end
  end

  defp params_of(url), do: Url.search_params(url)
  defp param(url, name), do: SearchParams.get(params_of(url), name)

  defp with_param(url, name, value), do: Url.with_params(url, SearchParams.set(params_of(url), name, value))

  ## Pass-through to a connected install

  # Answers a read for a site counted by another install by asking that install, with its token and its own id for
  # the site, and handing back what it says.
  defp pass_through(routes, remote, path, url, request \\ nil) do
    target = Url.new("#{remote["url"]}#{path}")
    params = Url.search_params(target) ++ params_of(url)
    target = Url.with_params(target, SearchParams.set(params, "site", remote["site"]))
    # A change made from the hub goes on to the install with its JSON body; reads carry none.
    write = request != nil and request.method not in ["GET", "HEAD"]
    headers = [{"authorization", "Bearer #{remote["token"]}"}]

    headers =
      if write and Request.header(request, "content-type"),
        do: headers ++ [{"content-type", Request.header(request, "content-type")}],
        else: headers

    host = Url.host(Url.new(remote["url"]))

    fetched =
      Runlight.fetch(routes.rl, Url.href(target),
        method: if(write, do: request.method, else: "GET"),
        headers: headers,
        body: if(write, do: Request.text(request)),
        # An install that answers with a redirect gets no fetch of somewhere else on its behalf.
        redirect: :manual,
        # A long report or an export is worked out in full before the install sends a byte, so reads get two minutes.
        timeout: if(write, do: 30_000, else: 120_000)
      )

    case fetched do
      {:error, :timeout} ->
        coded("#{host} took too long to answer. Try a shorter range.", "remote_slow", 504, %{"host" => host})

      {:error, _} ->
        coded("Could not reach #{host}", "unreachable", 502, %{"host" => host})

      {:ok, answer} ->
        # What comes back is shown from this server's origin, so it is never taken as a page.
        download = path == "/api/export" or (path == "/api/breakdown" and param(url, "format") == "csv")

        type =
          cond do
            not download -> "application/json; charset=utf-8"
            String.starts_with?(Response.header(answer, "content-type") || "", "text/csv") -> "text/csv; charset=utf-8"
            true -> "application/zip"
          end

        back = [
          {"cache-control", "private, no-store"},
          {"x-content-type-options", "nosniff"},
          {"content-security-policy", "default-src 'none'; frame-ancestors 'none'"},
          {"content-type", type}
        ]

        back =
          if download do
            name =
              case Regex.run(~r/filename="([A-Za-z0-9._-]+)"/, Response.header(answer, "content-disposition") || "") do
                [_, name] -> name
                nil -> "runlight-export"
              end

            back ++ [{"content-disposition", ~s(attachment; filename="#{name}")}]
          else
            back
          end

        cond do
          answer.status >= 300 and answer.status < 400 ->
            coded("#{host} answered with a redirect", "redirected", 502, %{"host" => host})

          # The install's own errors say what went wrong there; a refused token is this server's problem to report.
          answer.status == 401 ->
            coded("#{host} refused the token. Connect it again from the site's settings.", "token_refused", 502, %{"host" => host})

          answer.status >= 400 and not download ->
            text = Response.text(answer)

            body =
              if JS.len16(text) <= 65_536 do
                case JS.parse(text) do
                  {:ok, %Object{} = b} -> b
                  _ -> nil
                end
              end

            params =
              case body && body["params"] do
                %Object{} = p ->
                  p
                  |> Object.to_list()
                  |> Enum.filter(fn {_, v} -> is_binary(v) end)
                  |> Enum.take(10)
                  |> Enum.map(fn {k, v} -> {JS.slice(k, 0, 40), JS.slice(v, 0, 200)} end)

                _ ->
                  []
              end

            error = if body && is_binary(body["error"]), do: JS.slice(body["error"], 0, 300), else: "answered #{answer.status}"
            out = JS.obj(error: "#{host}: #{error}")
            code = body && body["code"]

            out =
              if is_binary(code) and Regex.match?(~r/\A[a-z_]{1,40}\z/, code),
                do: out |> Object.put("code", code) |> Object.put("params", Object.new(params)),
                else: out

            json(out, answer.status, back)

          true ->
            Response.new(answer.body, answer.status, back)
        end
    end
  end

  ## Links

  defp links_api(routes, request, path, url) do
    rl = routes.rl
    Runlight.init(rl)

    with {:ok, site} <- query_site(routes, url) do
      try do
        links_route(routes, request, path, url, site)
      rescue
        error in Runlight.LinkError -> coded(error.message, error.code, 400, error.params)
        error in Runlight.RangeError -> coded(error.message, "unknown_link", 404)
      end
    else
      {:error, response} -> response
    end
  end

  defp links_route(routes, request, path, url, site) do
    rl = routes.rl
    method = request.method
    check = Regex.run(~r/\A\/api\/link-domains\/([^\/]+)\/check\z/, path)
    domain_match = Regex.run(~r/\A\/api\/link-domains\/([^\/]+)\z/, path)
    import_match = Regex.run(~r/\A\/api\/links\/import\/([a-z]+)\z/, path)
    link_match = Regex.run(~r/\A\/api\/links\/([a-f0-9]+)\z/, path)

    cond do
      path == "/api/link-domains" and method == "GET" ->
        domains = for d <- Store.link_domains(rl.store), d["site"] == site["id"], do: d["domain"]
        json(JS.obj(domains: domains))

      path == "/api/link-domains" and method == "POST" ->
        with {:ok, body} <- read_json(request) do
          add_link_domain(routes, request, url, site, body)
        else
          {:error, response} -> response
        end

      check && method == "GET" ->
        domain = JS.decode_uri_component(Enum.at(check, 1)) || raise "URI malformed"
        check_link_domain(routes, url, site, domain)

      domain_match && method == "DELETE" ->
        domain = JS.decode_uri_component(Enum.at(domain_match, 1)) || raise "URI malformed"

        if Enum.any?(Store.link_domains(rl.store), &(&1["domain"] == domain and &1["site"] == site["id"])) do
          Store.remove_link_domain(rl.store, domain)
          Runlight.forget_link_domains(rl)
          json(JS.obj(ok: true))
        else
          coded("Unknown domain", "unknown_domain", 404)
        end

      path == "/api/links" and method == "GET" ->
        with {:ok, read} <- read_query(routes, url, site) do
          links = Store.links(rl.store, site["id"], read.range.from, read.range.to)
          # Links on a removed domain are served from the app's own path until it is added back.
          domains = for d <- Store.link_domains(rl.store), d["site"] == site["id"], do: d["domain"]
          json(JS.obj(prefix: "#{Url.origin(url)}#{rl.link_path}", domains: domains, links: links))
        else
          {:error, response} -> response
        end

      path == "/api/links" and method == "POST" ->
        with {:ok, body} <- read_json(request) do
          given = fn key -> if Object.has_key?(body, key), do: JS.string(body[key]) end

          link =
            Runlight.Links.create(rl, site["id"], %{
              "url" => body |> JS.prop("url") |> JS.nullish("") |> JS.string(),
              "name" => given.("name"),
              "slug" => given.("slug"),
              "domain" => given.("domain")
            })

          json(JS.obj(link: link), 201)
        else
          {:error, response} -> response
        end

      import_match && method == "POST" ->
        with {:ok, body} <- read_json(request) do
          credentials =
            case JS.prop(body, "credentials") do
              %Object{} = c -> Map.new(Object.to_list(c), fn {k, v} -> {k, JS.string(v)} end)
              _ -> %{}
            end

          cursor = if is_binary(body["cursor"]), do: body["cursor"]
          done = JS.or_else(JS.number(JS.prop(body, "done")), 0)
          done = if JS.finite?(done), do: done, else: 0

          try do
            json(Runlight.Importers.import_step(rl, site["id"], Enum.at(import_match, 1), credentials, cursor, done))
          rescue
            error in Runlight.ImportError -> refused(error, "import_failed")
          end
        else
          {:error, response} -> response
        end

      path == "/api/links/import" and method == "POST" ->
        with {:ok, body} <- read_json(request) do
          case body["rows"] do
            rows when is_list(rows) ->
              # Rows that are not objects (null, a number) are dropped rather than failing the import.
              rows = rows |> Enum.filter(&JS.object?/1) |> Enum.take(5000)
              json(Runlight.Links.import(rl, site["id"], rows))

            _ ->
              coded("Send rows as a list", "rows_needed", 400)
          end
        else
          {:error, response} -> response
        end

      link_match ->
        id = Enum.at(link_match, 1)
        link_by_id(routes, request, url, site, id)

      true ->
        coded("Not found", "not_found", 404)
    end
  end

  defp link_by_id(routes, request, url, site, id) do
    rl = routes.rl

    case request.method do
      "GET" ->
        link = Store.link_by_id(rl.store, id)

        if link == nil or link["site"] != site["id"] do
          coded("Unknown link", "unknown_link", 404)
        else
          with {:ok, read} <- read_query(routes, url, site) do
            range = read.range
            by = fn dimension -> Store.link_breakdown(rl.store, site["id"], id, range.from, range.to, dimension, 10) end
            series = Store.link_series(rl.store, site["id"], id, Time.buckets(range, site["timezone"]))
            clicks = Enum.reduce(series, 0, &(&1["clicks"] + &2))

            json(
              JS.obj(
                link: link,
                range: range_out(range, site),
                clicks: clicks,
                series: series,
                sources: by.("source"),
                referrers: by.("referrer"),
                countries: by.("country"),
                devices: by.("device"),
                browsers: by.("browser")
              )
            )
          else
            {:error, response} -> response
          end
        end

      method ->
        owned = Store.link_by_id(rl.store, id)

        cond do
          owned == nil or owned["site"] != site["id"] ->
            coded("Unknown link", "unknown_link", 404)

          method == "PATCH" ->
            with {:ok, body} <- read_json(request) do
              pick = fn key -> if Object.has_key?(body, key) and body[key] != :undefined, do: JS.string(body[key]) end
              changes = %{"url" => pick.("url"), "name" => pick.("name"), "slug" => pick.("slug"), "domain" => pick.("domain")}
              json(JS.obj(link: Runlight.Links.update(rl, id, changes)))
            else
              {:error, response} -> response
            end

          method == "DELETE" ->
            Runlight.Links.remove(rl, id)
            json(JS.obj(ok: true))

          true ->
            coded("Not found", "not_found", 404)
        end
    end
  end

  defp add_link_domain(routes, request, url, site, body) do
    rl = routes.rl

    domain =
      body
      |> JS.prop("domain")
      |> JS.nullish("")
      |> JS.string()
      |> JS.trim()
      |> JS.lower()
      |> String.replace(~r/^https?:\/\//, "")
      |> String.replace(~r/\/.*$/s, "")
      |> String.replace(~r/\.+\z/, "")
      |> String.replace(~r/^www\./, "")

    cond do
      not domain_name?(domain) ->
        coded("That is not a domain name", "domain_invalid", 400)

      private_name?(domain) or Runlight.Safefetch.resolves_privately?(domain) ->
        coded("#{domain} is not a public domain name. Use one that browsers anywhere can reach.", "domain_not_public", 400, %{"domain" => domain})

      # A hub cannot know every name this app answers on, so it adds none until the app knows its own address.
      managed(request) != nil and routes.origin == nil ->
        origin_needed()

      true ->
        here = Enum.filter([Request.header(request, "host"), Request.header(request, "x-forwarded-host"), Url.host(url)], &JS.truthy?/1)
        own_hosts = if routes.own_hosts, do: Enum.to_list(routes.own_hosts.()), else: []
        own = Enum.map((if routes.origin, do: [Url.host(Url.new(routes.origin))], else: []) ++ here ++ own_hosts, &host_name/1)

        taken =
          MapSet.new(
            own ++
              Enum.flat_map(Runlight.sites(rl), & &1["hostnames"]) ++
              Enum.flat_map(Runlight.sites(rl), fn s ->
                case Runlight.remote(rl, s["id"]) do
                  nil -> []
                  remote -> remote["hostnames"] || []
                end
              end)
          )

        owner = Enum.find(Store.link_domains(rl.store), &(&1["domain"] == domain))

        cond do
          MapSet.member?(taken, domain) ->
            coded(
              "#{domain} is where this dashboard or one of your sites lives. Use a separate domain or subdomain for short links, such as go.#{domain}.",
              "domain_in_use",
              400,
              %{"domain" => domain}
            )

          owner && owner["site"] != site["id"] ->
            coded("#{domain} already belongs to another site", "domain_taken", 409, %{"domain" => domain})

          true ->
            Store.add_link_domain(rl.store, domain, site["id"], Runlight.now(rl))
            Runlight.forget_link_domains(rl)
            json(JS.obj(domain: domain), 201)
        end
    end
  end

  defp check_link_domain(routes, url, site, domain) do
    rl = routes.rl

    if Enum.any?(Store.link_domains(rl.store), &(&1["domain"] == domain and &1["site"] == site["id"])) do
      # Where the domain should point, for the setup steps: this server's name, and its public addresses.
      own = if routes.origin, do: Url.new(routes.origin).hostname, else: url.hostname
      target = JS.obj(host: own, addresses: Runlight.Safefetch.public_addresses(own))

      result = fn code, reason, params ->
        out = JS.obj(domain: domain, working: code == "", reason: reason, target: target)
        out = if code != "", do: Object.put(out, "code", code), else: out
        out = if code != "" and params, do: Object.put(out, "params", JS.obj(params)), else: out
        json(out)
      end

      if not domain_name?(domain) or private_name?(domain) do
        result.("check_not_public", "is not a public domain name", nil)
      else
        # Only a public address is fetched, whatever the name resolves to now.
        case Runlight.Safefetch.public_fetch(rl, "https://#{domain}#{Runlight.link_domain_check()}", timeout: 5000) do
          {:ok, answer} ->
            body = case Response.json(answer), do: ({:ok, %Object{} = b} -> b; _ -> nil)

            cond do
              Response.ok?(answer) and body != nil and body["runlight"] == true and body["domain"] == domain -> result.("", "", nil)
              Response.ok?(answer) -> result.("check_not_runlight", "answered, but not from Runlight", nil)
              true -> result.("check_status", "answered #{answer.status}", %{"status" => "#{answer.status}"})
            end

          # A refused private address answers as a closed port does, so the check tells nothing about a private network.
          {:error, :timeout} ->
            result.("check_timeout", "timed out", nil)

          {:error, _} ->
            result.("check_https", "could not connect over HTTPS", nil)
        end
      end
    else
      coded("Unknown domain", "unknown_domain", 404)
    end
  end

  ## The tracker and the picker

  # The key picker tickets are signed with, made on first use and kept in the database for every process.
  defp pick_key(rl) do
    Runlight.init(rl)

    case Store.setting(rl.store, "pick-key") do
      nil ->
        made = Hash.random_id(32)
        Store.set_setting(rl.store, "pick-key", made)
        made

      saved ->
        saved
    end
  end

  defp hex(text), do: Base.encode16(text, case: :lower)

  # A ticket that lets the picker, on `site`'s pages, send its choice to `origin` for half an hour.
  defp pick_ticket(rl, origin, site) do
    payload = "#{Runlight.now(rl) + @pick_ticket_ms}.#{hex(site)}.#{hex(origin)}"
    "#{payload}.#{Hash.hmac(pick_key(rl), payload)}"
  end

  # The dashboard origin and site a picker ticket names, or nil when it is not one this install signed or has run out.
  defp pick_target(rl, ticket) do
    with [_, expires, site, origin, mac] <- Regex.run(~r/\A(\d+)\.([a-f0-9]{2,512})\.([a-f0-9]{2,512})\.([a-f0-9]{64})\z/, ticket),
         false <- JS.number(expires) < Runlight.now(rl),
         true <- Crypto.constant_time_equal?(mac, Hash.hmac(pick_key(rl), "#{expires}.#{site}.#{origin}")),
         origin_text = unhex(origin),
         true <- Regex.match?(~r/\Ahttps?:\/\/[^\/?#\s]+\z/, origin_text) do
      %{origin: origin_text, site: unhex(site)}
    else
      _ -> nil
    end
  end

  defp unhex(text) do
    bytes = for <<a, b <- text>>, into: <<>>, do: <<String.to_integer(<<a, b>>, 16)>>
    JS.decode_utf8(bytes)
  end

  # The tracker with click rules inside, rebuilt when goals change.
  defp tracker_script(routes, site_id) do
    rl = routes.rl
    key = site_id || ""

    case state(routes, {:tracker, key}) do
      %{at: at} = cached when is_integer(at) ->
        if Runlight.now(rl) - at < 60_000, do: cached, else: build_tracker(routes, site_id, key)

      _ ->
        build_tracker(routes, site_id, key)
    end
  end

  defp build_tracker(routes, site_id, key) do
    rl = routes.rl
    Runlight.init(rl)

    sites =
      cond do
        site_id != nil -> Enum.filter(Runlight.sites(rl), &(&1["id"] == site_id))
        rl.managed_sites -> []
        true -> Runlight.sites(rl)
      end

    rules = JS.stringify(Goals.click_rules(sites, Store.goals(rl.store)))
    # Replaced as text: "$'" or "$&" in a selector must not be read as a replacement pattern.
    body = String.replace(Assets.tracker(), @rules_placeholder, rules, global: false)
    script = %{body: body, etag: ~s("#{Assets.tracker_hash()}-#{binary_part(Hash.sha256(rules), 0, 8)}"), at: Runlight.now(rl)}
    # One entry per site at most; a query naming no real site gets the empty script without filling the table.
    if site_id == nil or sites != [], do: put_state(routes, {:tracker, key}, script)
    script
  end

  defp clear_trackers(routes), do: :ets.match_delete(routes.rl.table, {{:routes, routes.id, {:tracker, :_}}, :_})

  ## Goals

  defp goal_writes(routes, request, path, url) do
    rl = routes.rl
    Runlight.init(rl)

    with {:ok, site} <- query_site(routes, url) do
      existing = Store.goals(rl.store, site["id"])

      id =
        if path == "/api/goals",
          do: nil,
          else: JS.decode_uri_component(binary_part(path, 11, byte_size(path) - 11)) || raise("URI malformed")

      cond do
        id != nil and not Enum.any?(existing, &(&1["id"] == id)) ->
          coded("Unknown goal", "unknown_goal", 404)

        true ->
          clear_trackers(routes)

          if request.method == "DELETE" do
            Store.delete_goal(rl.store, id)
            json(JS.obj(ok: true))
          else
            with {:ok, body} <- read_json(request) do
              try do
                goal = Goals.goal_from(body, site["id"], existing, Runlight.now(rl), id)
                Store.save_goal(rl.store, goal, Enum.find(existing, &(&1["id"] == id)))
                json(JS.obj(goal: goal), if(id, do: 200, else: 201))
              rescue
                error in Runlight.GoalError -> refused(error, "goal_invalid")
              end
            else
              {:error, response} -> response
            end
          end
      end
    else
      {:error, response} -> response
    end
  end

  ## Mail and reports

  defp report_view(r),
    do:
      JS.obj(
        id: r["id"],
        site: r["site"],
        email: r["email"],
        frequency: r["frequency"],
        lang: r["lang"],
        lastSentAt: r["lastSentAt"],
        createdAt: r["createdAt"]
      )

  defp mail_api(routes, request, path, url) do
    Runlight.init(routes.rl)

    try do
      mail_route(routes, request, path, url)
    rescue
      error in Runlight.MailError -> coded(error.message, error.code, 400, error.params)
    end
  end

  defp mail_route(routes, request, path, url) do
    rl = routes.rl

    cond do
      path == "/api/mail" ->
        case request.method do
          "GET" ->
            settings = Runlight.mail_settings(rl)
            service = Enum.find(Runlight.Mail.services(), &(settings != nil and &1["id"] == settings["service"]))
            # Secret fields come back only as "saved", never as their value.
            {fields, saved} =
              Enum.reduce((service && service["fields"]) || [], {Object.new(), []}, fn f, {fields, saved} ->
                if f["secret"] do
                  {fields, if(settings && JS.truthy?(settings[f["name"]]), do: saved ++ [f["name"]], else: saved)}
                else
                  {Object.put(fields, f["name"], JS.string(JS.nullish(settings && settings[f["name"]], ""))), saved}
                end
              end)

            # A hub with a manage token learns which service sends the reports and from where, nothing more.
            via_manage = managed(request) != nil

            json(
              JS.obj(
                source: settings && settings["source"],
                service: (settings && settings["service"]) || "",
                from: JS.nullish(settings && settings["from"], ""),
                fromName: JS.nullish(settings && settings["fromName"], ""),
                fields: if(via_manage, do: Object.new(), else: fields),
                saved: if(via_manage, do: [], else: saved),
                encrypted: rl.secret != nil,
                services: Runlight.Mail.services()
              )
            )

          "PUT" ->
            with {:ok, body} <- read_json(request) do
              Runlight.save_mail_settings(rl, body)
              json(JS.obj(ok: true))
            else
              {:error, response} -> response
            end

          "DELETE" ->
            Runlight.save_mail_settings(rl, nil)
            json(JS.obj(ok: true))

          _ ->
            coded("Method not allowed", "method_not_allowed", 405)
        end

      path == "/api/mail/test" and request.method == "POST" ->
        with {:ok, body} <- read_json(request) do
          to = body |> JS.prop("to") |> JS.nullish("") |> JS.string() |> JS.trim()

          cond do
            not Runlight.email?(to) ->
              coded("Enter an email address to send the test to", "test_email", 400)

            (settings = Runlight.mail_settings(rl)) == nil ->
              coded("Set up a mail service first", "mail_unset", 400)

            true ->
              lang = Messages.code(body |> JS.prop("lang") |> JS.nullish("en") |> JS.string())
              name = Enum.find_value(Runlight.Mail.services(), "", &if(&1["id"] == settings["service"], do: &1["name"]))
              text = Messages.t(lang, "email.test.body", %{"service" => name})

              Runlight.send_mail(rl, %{
                to: to,
                subject: Messages.t(lang, "email.test.subject"),
                text: text,
                html: ~s(<p style="font-family:sans-serif;font-size:15px">#{escape_html(text)}</p>)
              })

              json(JS.obj(ok: true))
          end
        else
          {:error, response} -> response
        end

      true ->
        with {:ok, site} <- query_site(routes, url) do
          reports_route(routes, request, path, url, site)
        else
          {:error, response} -> response
        end
    end
  end

  defp reports_route(routes, request, path, url, site) do
    rl = routes.rl

    if path == "/api/reports" do
      case request.method do
        "GET" ->
          json(JS.obj(reports: Enum.map(Store.reports(rl.store, site["id"]), &report_view/1), languages: Messages.languages()))

        "POST" ->
          with {:ok, body} <- read_json(request) do
            add_report(routes, request, url, site, body)
          else
            {:error, response} -> response
          end

        _ ->
          coded("Method not allowed", "method_not_allowed", 405)
      end
    else
      match = Regex.run(~r/\A\/api\/reports\/([a-f0-9]{24})(\/send)?\z/, path)
      report = if match, do: Store.report_by(rl.store, :id, Enum.at(match, 1))
      send = match != nil and Enum.at(match, 2, "") != ""

      cond do
        report == nil or report["site"] != site["id"] ->
          coded("Unknown report", "unknown_report", 404)

        send and request.method == "POST" ->
          # A sample at most once a minute per report, so the send button cannot be used to flood an inbox. A hub sends
          # one every ten minutes for the whole site.
          hub = managed(request) != nil
          key = if hub, do: "site:#{site["id"]}", else: report["id"]
          wait = if hub, do: 600_000, else: 60_000
          last = state(routes, {:sample, key}) || 0

          if Runlight.now(rl) - last < wait do
            if hub,
              do:
                coded(
                  "A connected hub can send one sample every ten minutes. Wait a few minutes and try again.",
                  "sample_soon_hub",
                  429
                ),
              else: coded("A sample went out a moment ago. Wait a minute and try again.", "sample_soon", 429)
          else
            put_state(routes, {:sample, key}, Runlight.now(rl))
            Runlight.deliver_report(rl, report, site)
            json(JS.obj(ok: true))
          end

        not send and request.method == "DELETE" ->
          Store.delete_report(rl.store, report["id"])
          json(JS.obj(ok: true))

        true ->
          coded("Method not allowed", "method_not_allowed", 405)
      end
    end
  end

  defp add_report(routes, request, url, site, body) do
    rl = routes.rl
    email = body |> JS.prop("email") |> JS.nullish("") |> JS.string() |> JS.trim() |> JS.lower()
    frequency = if JS.prop(body, "frequency") == "monthly", do: "monthly", else: "weekly"
    existing = Store.reports(rl.store, site["id"])

    cond do
      not Runlight.email?(email) ->
        coded("Enter an email address", "email_invalid", 400)

      Enum.any?(existing, &(&1["email"] == email and &1["frequency"] == frequency)) ->
        coded("#{email} already gets the #{frequency} report", "report_exists", 400, %{"email" => email})

      length(existing) >= 50 ->
        coded("A site can send to at most 50 addresses", "report_limit", 400)

      # A report made from a hub needs the configured address, where its unsubscribe link answers.
      managed(request) != nil and routes.origin == nil ->
        origin_needed()

      true ->
        given = if routes.origin, do: "", else: body |> JS.prop("origin") |> JS.nullish("") |> JS.string()

        home =
          if Regex.match?(~r/^https?:\/\/[^\s]+$/u, given) and not String.contains?(given, "\n"),
            do: String.replace(given, ~r/\/+\z/, ""),
            else: "#{routes.origin || Url.origin(url)}#{routes.base}"

        # A period already due counts as sent, so a report added mid-week first goes out on the next Monday.
        now = Runlight.now(rl)
        due = Runlight.Reports.last_period(frequency, now, site["timezone"])
        lang = JS.string(JS.prop(body, "lang"))

        report =
          JS.obj(
            id: Hash.random_id(),
            site: site["id"],
            email: email,
            frequency: frequency,
            lang: if(lang in Messages.languages(), do: lang, else: "en"),
            token: Hash.random_id(16),
            origin: home,
            lastPeriod: if(now >= due.due_at, do: due.key, else: ""),
            lastSentAt: nil,
            createdAt: now
          )

        Store.insert_report(rl.store, report)
        json(JS.obj(report: report_view(report)), 201)
    end
  end

  # A plain page for unsubscribing: a button, so a link scanner opening the URL changes nothing.
  defp unsubscribe_page(routes, request, token) do
    rl = routes.rl
    Runlight.init(rl)
    report = if Regex.match?(~r/\A[a-f0-9]{32}\z/, token), do: Store.report_by(rl.store, :token, token)
    site = report && Runlight.site(rl, report["site"])
    lang = Messages.code(if report, do: report["lang"], else: "en")
    t = fn key, vars -> Messages.t(lang, key, vars) end

    cond do
      report == nil or site == nil ->
        small_page(lang, "<h1>#{escape_html(t.("email.unsub.goneTitle", %{}))}</h1><p>#{escape_html(t.("email.unsub.gone", %{}))}</p>", 404)

      request.method == "POST" ->
        Store.delete_report(rl.store, report["id"])

        small_page(
          lang,
          "<h1>#{escape_html(t.("email.unsub.doneTitle", %{}))}</h1><p>#{escape_html(t.("email.unsub.done", %{"site" => site["name"], "email" => report["email"]}))}</p>"
        )

      true ->
        small_page(
          lang,
          "<h1>#{escape_html(t.("email.unsub.title", %{"site" => site["name"]}))}</h1><p>#{escape_html(t.("email.unsub.body", %{"email" => report["email"]}))}</p><form method=\"post\"><button type=\"submit\">#{escape_html(t.("email.unsubscribe", %{}))}</button></form>"
        )
    end
  end

  ## Shares

  defp shares_api(routes, request, path, url) do
    rl = routes.rl
    Runlight.init(rl)

    with {:ok, site} <- query_site(routes, url) do
      view = fn share -> Object.put(share, "path", "#{routes.base}/share/#{share["id"]}") end

      if path == "/api/shares" do
        case request.method do
          "GET" ->
            json(JS.obj(shares: Enum.map(Store.shares(rl.store, site["id"]), view)))

          "POST" ->
            with {:ok, body} <- read_json(request) do
              name = body |> JS.prop("name") |> JS.nullish("") |> JS.string() |> JS.trim() |> JS.slice(0, 100)
              share = JS.obj(id: Hash.random_id(16), site: site["id"], name: name, createdAt: Runlight.now(rl))
              Store.insert_share(rl.store, share)
              json(JS.obj(share: view.(share)), 201)
            else
              {:error, response} -> response
            end

          _ ->
            coded("Method not allowed", "method_not_allowed", 405)
        end
      else
        id = JS.decode_uri_component(binary_part(path, 12, byte_size(path) - 12)) || raise("URI malformed")
        share = if Regex.match?(~r/\A[a-f0-9]{32}\z/, id), do: Store.share_by_id(rl.store, id)

        cond do
          share == nil or share["site"] != site["id"] ->
            coded("Unknown share", "unknown_share", 404)

          request.method == "PATCH" ->
            with {:ok, body} <- read_json(request) do
              name = body |> JS.prop("name") |> JS.nullish("") |> JS.string() |> JS.trim() |> JS.slice(0, 100)
              Store.rename_share(rl.store, share["id"], name)
              json(JS.obj(share: view.(Object.put(share, "name", name))))
            else
              {:error, response} -> response
            end

          request.method == "DELETE" ->
            Store.delete_share(rl.store, share["id"])
            json(JS.obj(ok: true))

          true ->
            coded("Method not allowed", "method_not_allowed", 405)
        end
      end
    else
      {:error, response} -> response
    end
  end

  ## The assistant's limits

  # How many questions each viewer may ask the assistant a day, as an owner set it.
  defp viewer_daily(rl) do
    case Store.setting(rl.store, "assistant-viewer-daily") do
      nil -> @viewer_daily
      saved -> JS.number(saved)
    end
  end

  # Counts a question to the assistant, or refuses it: past thirty an hour or two at once for anyone, and past the
  # owner's daily number for a viewer. Answers {:ok, finish} or {:error, response}.
  defp ask_turn(routes, who, owner) do
    rl = routes.rl
    now = Runlight.now(rl)
    key = {:asked, who}

    State.one_at_a_time(rl.table, {:routes, routes.id, key}, fn ->
      mine = state(routes, key) || %{at: [], open: 0}
      mine = %{mine | at: Enum.filter(mine.at, &(now - &1 < 3_600_000))}

      if length(mine.at) >= @ask_per_hour or mine.open >= @ask_at_once do
        {:error, coded("You have asked a lot in a short time. Wait a little and ask again.", "assistant_soon", 429)}
      else
        refusal =
          if owner do
            nil
          else
            limit = viewer_daily(rl)
            day = "assistant-asked:#{JS.iso_day(now)}"
            counts = JS.parse_or(Store.setting(rl.store, day) || "{}", Object.new())
            counts = if JS.object?(counts), do: counts, else: Object.new()
            asked = JS.number(JS.nullish(JS.prop(counts, who), 0))

            if asked >= limit do
              coded("Viewers can ask #{JS.string(limit)} questions a day. Ask again tomorrow.", "assistant_daily", 429, %{"limit" => JS.string(limit)})
            else
              Store.set_setting(rl.store, day, JS.stringify(Object.put(counts, who, asked + 1)))

              for %{key: k} <- Store.settings_starting_with(rl.store, "assistant-asked:"), k != day,
                  do: Store.set_setting(rl.store, k, nil)

              nil
            end
          end

        if refusal do
          {:error, refusal}
        else
          put_state(routes, key, %{at: mine.at ++ [now], open: mine.open + 1})

          {:ok,
           fn ->
             State.one_at_a_time(rl.table, {:routes, routes.id, key}, fn ->
               current = state(routes, key) || %{at: [], open: 1}
               put_state(routes, key, %{current | open: current.open - 1})
             end)
           end}
        end
      end
    end)
  end

  ## Tokens

  defp tokens_api(routes, request, path) do
    rl = routes.rl
    Runlight.init(rl)

    view = fn t ->
      JS.obj(id: t["id"], name: t["name"], site: t["site"], scope: t["scope"], hint: t["hint"], createdAt: t["createdAt"], lastUsedAt: t["lastUsedAt"])
    end

    delete = Regex.run(~r/\A\/api\/tokens\/([a-f0-9]{24})\z/, path)

    cond do
      path == "/api/tokens" and request.method == "GET" ->
        json(JS.obj(tokens: Enum.map(Store.tokens(rl.store), view)))

      path == "/api/tokens" and request.method == "POST" ->
        with {:ok, body} <- read_json(request) do
          name = body |> JS.prop("name") |> JS.nullish("") |> JS.string() |> JS.trim() |> JS.slice(0, 100)
          site = body |> JS.prop("site") |> JS.nullish("") |> JS.string()
          scope = if JS.prop(body, "scope") == "manage", do: "manage", else: "read"

          cond do
            name == "" ->
              coded("Name the token", "token_name", 400)

            site != "" and not Enum.any?(Runlight.sites(rl), &(&1["id"] == site)) ->
              coded("Unknown site", "unknown_site", 404)

            scope == "manage" and site == "" ->
              coded("A token that changes settings is for one site. Pick the site.", "token_site", 400)

            true ->
              secret = @token_prefix <> Hash.random_id(20)

              row =
                JS.obj(
                  id: Hash.random_id(),
                  name: name,
                  site: site,
                  scope: scope,
                  hash: Hash.sha256(secret),
                  hint: JS.slice(secret, -4),
                  createdAt: Runlight.now(rl),
                  lastUsedAt: nil
                )

              Store.insert_token(rl.store, row)
              by = if routes.account_of, do: routes.account_of.(request)

              if by && routes.token_made && not routes.token_made.(row, by) do
                Store.delete_token(rl.store, row["id"])
                denied("read")
              else
                # The only time the token is ever shown.
                json(JS.obj(token: view.(row), secret: secret), 201)
              end
          end
        else
          {:error, response} -> response
        end

      delete && request.method == "DELETE" ->
        if Store.delete_token(rl.store, Enum.at(delete, 1)),
          do: json(JS.obj(ok: true)),
          else: coded("Unknown token", "unknown_token", 404)

      true ->
        coded("Not found", "not_found", 404)
    end
  end

  defp range_out(range, site),
    do: JS.obj(from: range.from_date, to: range.to_date, interval: range.interval, timezone: site["timezone"])

  ## The API

  @doc false
  def api(routes, request, path, url) do
    rl = routes.rl
    method = request.method
    given_bearer = bearer(request)

    cond do
      # A write must be JSON, which a form on another page cannot send, even the writes that carry no body.
      method not in ["GET", "HEAD", "OPTIONS", "DELETE"] and given_bearer == "" and not json?(request) ->
        coded("Send JSON", "send_json", 415)

      path == "/api" and method == "GET" ->
        json(JS.obj([name: "runlight", version: Assets.version(), api: Assets.api_version()] ++ @implementation))

      # A hub asks what its token may do before offering to change anything.
      path == "/api/token" and method == "GET" ->
        case api_token(routes, request) do
          nil -> denied(false)
          token -> json(JS.obj(scope: token["scope"], site: token["site"]))
        end

      # A token can delete itself, which a hub does when it disconnects a site or gets a new token.
      path == "/api/token" and method == "DELETE" ->
        case api_token(routes, request) do
          nil ->
            denied(false)

          token ->
            Store.delete_token(rl.store, token["id"])
            json(JS.obj(ok: true))
        end

      # Connecting another Runlight through its consent page, so nobody copies a token.
      path == "/api/sites/connect" and method == "POST" ->
        connect_start(routes, request, url)

      path == "/api/sites/connect/done" and method == "GET" ->
        connect_done(routes, request, url)

      true ->
        api_scoped(routes, request, path, url)
    end
  end

  defp connect_start(routes, request, url) do
    rl = routes.rl
    access = can_read(routes, request)

    cond do
      access != true ->
        denied(access)

      Runlight.init(rl) == :ok and not rl.managed_sites ->
        coded("Sites are set in code", "sites_in_code", 400)

      true ->
        with {:ok, body} <- read_json(request) do
          try do
            site = if is_binary(body["site"]), do: body["site"], else: ""
            back = "#{Url.origin(url)}#{routes.base}/api/sites/connect/done"
            json(JS.obj(authorize: Runlight.Connect.start_connect(rl, JS.prop(body, "url"), back, site)))
          rescue
            error in Runlight.ConnectError ->
              coded(error.message, if(error.code == "unreachable", do: "unreachable", else: "connect_#{error.code}"), 400, error.params)

            error ->
              if Errors.range?(error), do: refused(error, "connect_failed"), else: reraise(error, __STACKTRACE__)
          end
        else
          {:error, response} -> response
        end
    end
  end

  defp connect_done(routes, request, url) do
    rl = routes.rl
    home = if routes.base == "", do: "/", else: routes.base

    if can_read(routes, request) != true do
      Response.new(nil, 303, [{"location", home}, {"cache-control", "no-store"}])
    else
      Runlight.init(rl)

      to =
        try do
          id = Runlight.Connect.finish_connect(rl, params_of(url))
          # The site's settings open with a word that the connection worked, which a reconnection otherwise lacks.
          "#{home}?site=#{JS.encode_uri_component(id)}&settings=general&connected=1"
        rescue
          error ->
            if Errors.range?(error) do
              # A code, never the message: the dashboard shows its own words for it, so a link cannot put text there.
              "#{home}?connect_error=#{if is_struct(error, Runlight.ConnectError), do: error.code, else: "failed"}"
            else
              reraise error, __STACKTRACE__
            end
        end

      Response.new(nil, 303, [{"location", to}, {"cache-control", "no-store"}])
    end
  end

  defp api_scoped(routes, request, path, url) do
    rl = routes.rl
    method = request.method
    token = if String.starts_with?(bearer(request), @token_prefix), do: api_token(routes, request)

    {early, url} =
      if token && token["scope"] == "manage" && manage_path?(method, path) do
        asked = param(url, "site")
        site_match = Regex.run(~r/\A\/api\/sites\/([^\/]+)\z/, path)

        cond do
          (asked != nil and asked != token["site"]) or (site_match != nil and JS.decode_uri_component(Enum.at(site_match, 1)) != token["site"]) ->
            {coded("Unknown site", "unknown_site", 404), url}

          site_match != nil and json?(request) and hub_domains?(request) ->
            # Where a site lives stays with its owner: a hub may rename it, never move it.
            {coded("A connected hub cannot change a site's domains", "hub_domains", 403), url}

          true ->
            set_managed(request, token)
            {nil, with_param(url, "site", token["site"])}
        end
      else
        {nil, url}
      end

    cond do
      early != nil ->
        early

      # A token this install made that tries a change it may not make is known, just not allowed, as for a viewer.
      token != nil and managed(request) == nil and method not in ["GET", "HEAD", "OPTIONS"] ->
        if token["scope"] == "manage",
          do: coded("A manage token changes only its own site's settings", "token_manage_only", 403),
          else: coded("API tokens can only read", "token_read_only", 403)

      # A page another site served to an AI agent, reported by a CMS plugin.
      path == "/api/observe" and method == "POST" ->
        observe_api(routes, request)

      # GET too: Vercel Cron calls with GET and the cron secret as a bearer token.
      path == "/api/check" and method in ["POST", "GET"] ->
        given = bearer(request)

        allowed =
          (is_binary(routes.cron_secret) and routes.cron_secret != "" and given != "" and Crypto.constant_time_equal?(given, routes.cron_secret)) or
            can_read(routes, request) == true

        if allowed, do: json(Runlight.check(rl)), else: coded("Unauthorized", "unauthorized", 401)

      true ->
        api_sites(routes, request, path, url)
    end
  end

  defp hub_domains?(request) do
    case Request.json(request) do
      {:ok, %Object{} = body} -> Object.has_key?(body, "hostnames")
      _ -> false
    end
  end

  defp observe_api(routes, request) do
    rl = routes.rl
    given = bearer(request)
    # The install-wide key and the owner's access can report for any site.
    any_site =
      (is_binary(routes.observe_key) and routes.observe_key != "" and given != "" and Crypto.constant_time_equal?(given, routes.observe_key)) or
        can_read(routes, request) == true

    if not any_site and given == "" do
      coded("Unauthorized", "unauthorized", 401)
    else
      with {:ok, body} <- read_json(request) do
        batch = is_list(body["fetches"])
        # One fetch as { url, userAgent, at? }, or up to 500 as { fetches: [...] } from a log reader.
        list = if batch, do: body["fetches"], else: [body]

        if length(list) > 500 do
          coded("Send at most 500 fetches at a time", "observe_many", 413)
        else
          pages =
            Enum.reduce_while(list, {:ok, []}, fn item, {:ok, pages} ->
              page = Url.parse(item |> JS.prop("url") |> JS.nullish("") |> JS.string())

              if page == nil or page.protocol not in ["https:", "http:"] do
                {:halt, :bad}
              else
                at =
                  case JS.prop(item, "at") do
                    n when is_number(n) -> n
                    s when is_binary(s) -> JS.date_parse(s)
                    _ -> nil
                  end

                user_agent = item |> JS.prop("userAgent") |> JS.nullish("") |> JS.string() |> JS.slice(0, 500)
                {:cont, {:ok, pages ++ [%{page: page, user_agent: user_agent, at: if(at != nil and JS.finite?(at), do: at)}]}}
              end
            end)

          case pages do
            :bad ->
              coded("Send the page's url", "observe_url", 400)

            {:ok, pages} ->
              Runlight.init(rl)
              observe_pages(rl, routes, given, any_site, batch, pages)
          end
        end
      else
        {:error, response} -> response
      end
    end
  end

  defp observe_pages(rl, _routes, given, any_site, batch, pages) do
    keep =
      if any_site do
        {:ok, pages}
      else
        # A site's own key reports only pages on that site's domains.
        key_site =
          Enum.reduce(Runlight.sites(rl), nil, fn site, found ->
            key = Store.setting(rl.store, "observe-key:#{site["id"]}")
            if key && Crypto.constant_time_equal?(given, key), do: site["id"], else: found
          end)

        if key_site == nil do
          :unauthorized
        else
          keep = Enum.filter(pages, &((Runlight.site_for(rl, &1.page.hostname) || %{})["id"] == key_site))
          # A single report for another site's page is a misconfigured plugin, which should hear about it.
          if not batch and keep == [], do: :unauthorized, else: {:ok, keep}
        end
      end

    case keep do
      :unauthorized ->
        coded("Unauthorized", "unauthorized", 401)

      {:ok, keep} ->
        recorded =
          Enum.count(keep, fn p ->
            Runlight.observe(rl, Request.new(Url.href(p.page), headers: [{"user-agent", p.user_agent}]), p.at)
          end)

        # A single report, as the CMS plugins send, needs no answer; a batch learns what was kept.
        if batch,
          do: json(JS.obj(recorded: recorded, skipped: length(pages_of(pages_count(keep, pages))) - recorded)),
          else: Response.new(nil, 204, [])
    end
  end

  defp pages_count(_keep, pages), do: pages
  defp pages_of(pages), do: pages

  defp api_sites(routes, request, path, url) do
    rl = routes.rl
    method = request.method
    # A site counted by another install is read there. Its settings change there too, through this server when the
    # install gave a manage token, and only by an owner here.
    asked = param(url, "site")
    connected = if asked, do: Runlight.remote(rl, asked)

    cond do
      connected && connected["scope"] == "manage" && manage_path?(method, path) && not (method == "GET" and shared_path?(path)) ->
        access = can_read(routes, request)

        if access != true do
          denied(access)
        else
          if method != "GET", do: Runlight.forget_remote_info(rl, asked)
          pass_through(routes, connected, path, url, request)
        end

      connected && not (method == "GET" and (shared_path?(path) or path == "/api/links")) ->
        coded("This site is counted by its own Runlight. Connect it again from its settings to change it from here.", "site_remote", 400)

      # Visit history from Umami: list the account's websites, then import one a step at a time.
      path in ["/api/import/umami/websites", "/api/import/umami/visits"] and method == "POST" ->
        import_umami(routes, request, path, url)

      # Visit history from a CSV file, a batch at a time.
      path == "/api/import/csv/visits" and method == "POST" ->
        access = can_read(routes, request)

        with true <- access == true || {:denied, access},
             {:ok, body} <- read_json(request),
             :ok <- Runlight.init(rl),
             {:ok, site} <- query_site(routes, url) do
          try do
            json(Runlight.Importers.Visits.import_csv_visits(rl, site["id"], JS.prop(body, "rows")))
          rescue
            error in Runlight.ImportError -> refused(error, "import_failed")
          end
        else
          {:denied, access} -> denied(access)
          {:error, response} -> response
        end

      # Each site's key for CMS plugins reporting AI agent fetches: made on first ask, replaced on request.
      (path == "/api/observe-key" and method == "GET") or (path == "/api/observe-key/new" and method == "POST") ->
        access = can_read(routes, request)

        with true <- access == true || {:denied, access},
             :ok <- Runlight.init(rl),
             {:ok, site} <- query_site(routes, url) do
          name = "observe-key:#{site["id"]}"
          key = if String.ends_with?(path, "/new"), do: nil, else: Store.setting(rl.store, name)

          key =
            if key in [nil, ""] do
              made = "rlo_" <> Hash.random_id(20)
              Store.set_setting(rl.store, name, made)
              made
            else
              key
            end

          json(JS.obj(key: key))
        else
          {:denied, access} -> denied(access)
          {:error, response} -> response
        end

      # Making, changing, and deleting funnels; reading them is with the other reports.
      (path == "/api/funnels" and method == "POST") or
          (Regex.match?(~r/\A\/api\/funnels\/[a-f0-9]{24}\z/, path) and method in ["PATCH", "DELETE"]) ->
        funnel_writes(routes, request, path, url)

      path == "/api/assistant" ->
        assistant_api(routes, request)

      # How many questions each viewer may ask a day; 0 keeps the assistant for owners.
      path == "/api/assistant/limits" and method == "PUT" ->
        access = can_read(routes, request)

        with true <- access == true || {:denied, access},
             :ok <- Runlight.init(rl),
             {:ok, body} <- read_json(request) do
          daily = JS.number(JS.prop(body, "viewerDaily"))

          if not is_integer(JS.normalize(daily)) or daily < 0 or daily > 1000 do
            coded("Use a whole number from 0 to 1,000", "assistant_limit", 400)
          else
            daily = JS.normalize(daily)
            Store.set_setting(rl.store, "assistant-viewer-daily", JS.string(daily))
            json(JS.obj(viewerDaily: daily))
          end
        else
          {:denied, access} -> denied(access)
          {:error, response} -> response
        end

      # The models a service offers, for the setup form's dropdown. The key can be the one already saved.
      path == "/api/assistant/models" and method == "POST" ->
        assistant_models(routes, request)

      path == "/api/assistant/chat" and method == "POST" ->
        assistant_chat(routes, request, url)

      # Only the owner manages tokens: an API token cannot make or revoke one.
      path == "/api/tokens" or String.starts_with?(path, "/api/tokens/") ->
        access = can_read(routes, request)
        if access != true, do: denied(access), else: tokens_api(routes, request, path)

      connected && path == "/api/links" ->
        access = reader(routes, request)

        cond do
          access in [false, "unconfigured"] -> denied(access)
          # A token limited to one site reads only that site's links, here as everywhere else.
          access != true and access["site"] != "" and access["site"] != asked -> coded("Unknown site", "unknown_site", 404)
          true -> pass_through(routes, connected, path, url)
        end

      # An API token, or someone signed in to read, may list links and see each one's clicks, but not change them.
      method == "GET" and (path == "/api/links" or Regex.match?(~r/\A\/api\/links\/[a-f0-9]+\z/, path)) and
          reader_not_owner(routes, request) != nil ->
        case reader_not_owner(routes, request) do
          {:denied, access} ->
            denied(access)

          {:reader, access} ->
            Runlight.init(rl)
            site = Runlight.site(rl, param(url, "site") || JS.or_else(access["site"], nil))

            if site == nil or (access["site"] != "" and site["id"] != access["site"]),
              do: coded("Unknown site", "unknown_site", 404),
              else: links_api(routes, request, path, with_param(url, "site", site["id"]))
        end

      path == "/api/links" or String.starts_with?(path, "/api/links/") or path == "/api/link-domains" or
          String.starts_with?(path, "/api/link-domains/") ->
        access = can_read(routes, request)
        if access != true, do: denied(access), else: links_api(routes, request, path, url)

      path in ["/api/mail", "/api/mail/test", "/api/reports"] or String.starts_with?(path, "/api/reports/") ->
        access = can_read(routes, request)
        if access != true, do: denied(access), else: mail_api(routes, request, path, url)

      # A ticket for the element picker, naming the dashboard it may send its choice to.
      path == "/api/pick" and method == "POST" ->
        pick_api(routes, request, url)

      (path == "/api/goals" and method == "POST") or
          (Regex.match?(~r/\A\/api\/goals\/[^\/]+\z/, path) and method in ["PATCH", "DELETE"]) ->
        access = can_read(routes, request)
        if access != true, do: denied(access), else: goal_writes(routes, request, path, url)

      path == "/api/shares" or String.starts_with?(path, "/api/shares/") ->
        access = can_read(routes, request)
        if access != true, do: denied(access), else: shares_api(routes, request, path, url)

      # Adding and deleting sites, when they are managed in the dashboard.
      path == "/api/sites" and method == "POST" ->
        access = can_read(routes, request)

        with true <- access == true || {:denied, access},
             {:ok, body} <- read_json(request) do
          try do
            json(JS.obj(site: Runlight.add_site(rl, body)), 201)
          rescue
            error -> if Errors.range?(error), do: refused(error, "site_invalid"), else: reraise(error, __STACKTRACE__)
          end
        else
          {:denied, access} -> denied(access)
          {:error, response} -> response
        end

      Regex.match?(~r/\A\/api\/sites\/[^\/]+\z/, path) and method == "DELETE" ->
        access = can_read(routes, request)

        if access != true do
          denied(access)
        else
          try do
            Runlight.delete_site(rl, JS.decode_uri_component(binary_part(path, 11, byte_size(path) - 11)) || raise("URI malformed"))
            json(JS.obj(ok: true))
          rescue
            error ->
              cond do
                Errors.range?(error) and Exception.message(error) == "Unknown site" -> coded("Unknown site", "unknown_site", 404)
                Errors.range?(error) -> refused(error, "site_invalid")
                true -> reraise error, __STACKTRACE__
              end
          end
        end

      Regex.match?(~r/\A\/api\/sites\/[^\/]+\z/, path) and method == "PATCH" ->
        site_patch(routes, request, path, url)

      method != "GET" ->
        coded("Method not allowed", "method_not_allowed", 405)

      true ->
        api_reads(routes, request, path, url)
    end
  end

  # For the links reads: nil when the request acts as the owner (and goes the owner's way), else who reads.
  defp reader_not_owner(routes, request) do
    case reader(routes, request) do
      true -> nil
      access when access in [false, "unconfigured"] -> {:denied, access}
      access -> {:reader, access}
    end
  end

  defp import_umami(routes, request, path, url) do
    rl = routes.rl
    access = can_read(routes, request)

    with true <- access == true || {:denied, access},
         {:ok, body} <- read_json(request) do
      credentials =
        case JS.prop(body, "credentials") do
          %Object{} = c -> Map.new(Object.to_list(c), fn {k, v} -> {k, JS.string(v)} end)
          _ -> %{}
        end

      try do
        if path == "/api/import/umami/websites" do
          json(JS.obj(websites: Runlight.Importers.Visits.umami_websites(rl, credentials)))
        else
          Runlight.init(rl)

          case query_site(routes, url) do
            {:ok, site} ->
              website = body |> JS.prop("website") |> JS.nullish("") |> JS.string()
              cursor = if is_binary(body["cursor"]), do: body["cursor"]
              json(Runlight.Importers.Visits.import_umami_visits(rl, site["id"], credentials, website, cursor))

            {:error, response} ->
              response
          end
        end
      rescue
        error in Runlight.ImportError -> refused(error, "import_failed")
      end
    else
      {:denied, access} -> denied(access)
      {:error, response} -> response
    end
  end

  defp funnel_writes(routes, request, path, url) do
    rl = routes.rl
    access = can_read(routes, request)

    with true <- access == true || {:denied, access},
         :ok <- Runlight.init(rl),
         {:ok, site} <- query_site(routes, url) do
      existing = Store.funnels(rl.store, site["id"])
      id = if path == "/api/funnels", do: nil, else: binary_part(path, 13, byte_size(path) - 13)

      cond do
        id != nil and not Enum.any?(existing, &(&1["id"] == id)) ->
          coded("Unknown funnel", "unknown_funnel", 404)

        request.method == "DELETE" ->
          Store.delete_funnel(rl.store, id)
          json(JS.obj(ok: true))

        true ->
          with {:ok, body} <- read_json(request) do
            try do
              funnel = Goals.funnel_from(body, site["id"], existing, Runlight.now(rl), id)
              Store.save_funnel(rl.store, funnel)
              json(JS.obj(funnel: funnel), if(id, do: 200, else: 201))
            rescue
              error in Runlight.FunnelError -> refused(error, "funnel_invalid")
            end
          else
            {:error, response} -> response
          end
      end
    else
      {:denied, access} -> denied(access)
      {:error, response} -> response
    end
  end

  defp assistant_api(routes, request) do
    rl = routes.rl
    me = can_read(routes, request)
    # A member uses the assistant like anyone else, but its settings are for owners and admins.
    owner = me == true and not member?(request)

    cond do
      request.method == "GET" ->
        access = reader(routes, request)

        cond do
          access in [false, "unconfigured"] ->
            denied(access)

          # Only people at the dashboard, never an API token or a share, so nobody spends the owner's AI credit from outside.
          access != true and access["id"] != "" ->
            coded("Only the dashboard can use the assistant", "assistant_dashboard", 403)

          true ->
            Runlight.init(rl)
            settings = Runlight.assistant_settings(rl)

            if owner do
              json(
                JS.obj(
                  configured: settings != nil,
                  viewerDaily: viewer_daily(rl),
                  provider: (settings && settings["provider"]) || "",
                  model: (settings && settings["model"]) || "",
                  baseUrl: (settings && settings["baseUrl"]) || "",
                  keySaved: settings != nil and JS.truthy?(settings["key"]),
                  encrypted: rl.secret != nil,
                  providers: Runlight.Assistant.providers()
                )
              )
            else
              json(JS.obj(configured: settings != nil))
            end
        end

      not owner ->
        if me == true, do: coded("Only an owner or admin can change this", "admin_only", 403), else: denied(me)

      request.method == "DELETE" ->
        Runlight.init(rl)
        Runlight.save_assistant_settings(rl, nil)
        json(JS.obj(ok: true))

      request.method == "PUT" ->
        Runlight.init(rl)

        with {:ok, body} <- read_json(request) do
          try do
            Runlight.save_assistant_settings(rl, body)
            json(JS.obj(ok: true))
          rescue
            error -> if Errors.range?(error), do: refused(error, "assistant_invalid"), else: reraise(error, __STACKTRACE__)
          end
        else
          {:error, response} -> response
        end

      true ->
        coded("Method not allowed", "method_not_allowed", 405)
    end
  end

  defp assistant_models(routes, request) do
    rl = routes.rl
    access = can_read(routes, request)

    with true <- access == true || {:denied, access},
         :ok <- Runlight.init(rl),
         {:ok, body} <- read_json(request) do
      provider = body |> JS.prop("provider") |> JS.nullish("") |> JS.string()
      saved = Runlight.assistant_settings(rl)
      base_url = body |> JS.prop("baseUrl") |> JS.nullish("") |> JS.string() |> JS.trim() |> String.replace(~r/\/+\z/, "")
      # The saved key only for the address it was saved with.
      same = saved != nil and saved["provider"] == provider and (saved["baseUrl"] || "") == base_url
      key = body |> JS.prop("key") |> JS.nullish("") |> JS.string() |> JS.trim()
      key = if key == "" and same, do: saved["key"], else: key

      try do
        models =
          Runlight.Assistant.list_models(
            rl,
            JS.obj(provider: provider, baseUrl: body |> JS.prop("baseUrl") |> JS.nullish("") |> JS.string() |> JS.trim(), key: key)
          )

        json(JS.obj(models: models))
      rescue
        error in Runlight.AssistantError -> refused(error, "assistant_failed")
      end
    else
      {:denied, access} -> denied(access)
      {:error, response} -> response
    end
  end

  defp assistant_chat(routes, request, url) do
    rl = routes.rl
    access = reader(routes, request)

    cond do
      access in [false, "unconfigured"] ->
        denied(access)

      access != true and access["id"] != "" ->
        coded("Only the dashboard can use the assistant", "assistant_dashboard", 403)

      Request.header(request, @share_header) != nil ->
        coded("Not available on a shared dashboard", "share_not_available", 403)

      true ->
        Runlight.init(rl)
        settings = Runlight.assistant_settings(rl)

        if settings == nil do
          coded("The assistant is not set up yet. An owner can set it up in Settings, AI Assistant.", "assistant_unset", 400)
        else
          with {:ok, body} <- read_json(request) do
            site = Runlight.site(rl, JS.or_else(body |> JS.prop("site") |> JS.nullish("") |> JS.string(), nil))

            messages =
              case body["messages"] do
                list when is_list(list) ->
                  for m <- list, JS.object?(m), m["role"] in ["user", "assistant"], is_binary(m["content"]),
                      do: %{role: m["role"], content: m["content"]}

                _ ->
                  []
              end

            cond do
              site == nil ->
                coded("Unknown site", "unknown_site", 404)

              messages == [] or List.last(messages).role != "user" ->
                coded("Ask a question", "question_needed", 400)

              true ->
                owner = access == true
                who = (routes.account_of && routes.account_of.(request)) || if(owner, do: "owner", else: "viewer")

                case ask_turn(routes, who, owner) do
                  {:error, response} ->
                    response

                  {:ok, finish} ->
                    try do
                      read_api = tool_reader(routes, request, url, site["id"])
                      view = body |> JS.prop("view") |> JS.nullish("the last 30 days") |> JS.string() |> JS.slice(0, 200)
                      lang = JS.string(JS.prop(body, "language"))

                      context = %{
                        site: %{id: site["id"], name: site["name"], timezone: site["timezone"]},
                        today: Time.local_date(Runlight.now(rl), site["timezone"]),
                        view: view,
                        language: if(Regex.match?(~r/\A[a-z]{2}\z/, lang), do: lang, else: "en")
                      }

                      json(Runlight.Assistant.chat(rl, settings, messages, context, read_api))
                    rescue
                      error in Runlight.AssistantError -> refused(error, "assistant_failed", 502)
                    after
                      finish.()
                    end
                end
            end
          else
            {:error, response} -> response
          end
        end
    end
  end

  # Each tool reads the HTTP API with the asker's own headers, as the MCP server does. A tool that names no site
  # reads `site` (the one on screen), when given.
  defp tool_reader(routes, request, url, site \\ nil) do
    headers = Enum.reject(request.headers, fn {k, _} -> k in ["content-type", "content-length", @share_header] end)

    fn api_path, params ->
      target = Url.new("#{routes.base}#{api_path}", Url.origin(url))
      target = Url.with_params(target, Url.search_params(target) ++ params)

      target =
        if site && api_path != "/api/sites" and not SearchParams.has?(Url.search_params(target), "site"),
          do: with_param(target, "site", site),
          else: target

      inner = %Request{url: Url.href(target), method: "GET", headers: headers, body: "", remote_address: request.remote_address, ref: make_ref()}
      api(routes, inner, api_path, target)
    end
  end

  defp pick_api(routes, request, url) do
    rl = routes.rl
    access = can_read(routes, request)

    with true <- access == true || {:denied, access},
         :ok <- Runlight.init(rl),
         {:ok, site} <- query_site(routes, url),
         {:ok, body} <- read_json(request) do
      origin = body |> JS.prop("origin") |> JS.nullish("") |> JS.string()
      hub = managed(request)

      cond do
        not Regex.match?(~r/\Ahttps?:\/\/[^\/?#\s]+\z/, origin) ->
          coded("Send the dashboard's origin, such as https://stats.example.com", "pick_origin", 400)

        # A hub's ticket only ever sends to the hub it connected from, never to an origin it names now.
        hub != nil and Store.setting(rl.store, "token-origin:#{hub["id"]}") != origin ->
          coded("This hub's address is not the one it connected from. Connect the site again from here.", "pick_hub", 403)

        true ->
          json(JS.obj(ticket: pick_ticket(rl, origin, site["id"])))
      end
    else
      {:denied, access} -> denied(access)
      {:error, response} -> response
    end
  end

  defp site_patch(routes, request, path, url) do
    rl = routes.rl
    access = can_read(routes, request)

    with true <- access == true || {:denied, access},
         {:ok, body} <- read_json(request) do
      Runlight.init(rl)
      name = JS.prop(body, "name")
      timezone = JS.prop(body, "timezone")
      retention = JS.prop(body, "retentionMonths")
      choices = Enum.join(Runlight.retention_months(), ", ")

      cond do
        # Every field is checked before any changes, since a shorter retention deletes visits at once.
        name != :undefined and not (JS.trim(JS.string(name)) != "" and JS.len16(JS.trim(JS.string(name))) <= 80) ->
          coded("A site name is 1 to 80 characters", "site_name", 400)

        timezone != :undefined and not Time.timezone?(JS.string(timezone)) ->
          coded(~s(Unknown timezone "#{JS.string(timezone)}"), "unknown_timezone", 400, %{"timezone" => JS.string(timezone)})

        retention not in [:undefined, nil] and JS.number(retention) not in Runlight.retention_months() ->
          coded("Keep visits for #{choices} months, or forever", "retention_bad", 400, %{"months" => choices})

        true ->
          try do
            id = JS.decode_uri_component(binary_part(path, 11, byte_size(path) - 11)) || raise("URI malformed")
            remote = Runlight.remote(rl, id)
            current_zone = (Runlight.site(rl, id) || %{})["timezone"]
            # How long a connected site keeps visits, and the timezone its days follow, are the install's settings:
            # this server passes them on, and changes its own row only once the install took them.
            forward = Object.new()
            forward = if retention != :undefined, do: Object.put(forward, "retentionMonths", retention), else: forward

            forward =
              if timezone != :undefined and JS.string(timezone) != current_zone,
                do: Object.put(forward, "timezone", JS.string(timezone)),
                else: forward

            early =
              cond do
                remote != nil and Object.size(forward) > 0 ->
                  if remote["scope"] != "manage" do
                    coded("Connect this site again to change it from here", "connect_again", 400)
                  else
                    inner = %Request{
                      url: request.url,
                      method: "PATCH",
                      headers: [{"content-type", "application/json"}],
                      body: JS.stringify(forward),
                      remote_address: request.remote_address,
                      ref: make_ref()
                    }

                    answer = pass_through(routes, remote, "/api/sites/#{JS.encode_uri_component(remote["site"])}", url, inner)

                    if Response.ok?(answer) do
                      Runlight.forget_remote_info(rl, id)
                      nil
                    else
                      answer
                    end
                  end

                remote == nil and retention != :undefined ->
                  Runlight.set_retention(rl, id, if(retention == nil, do: nil, else: JS.normalize(JS.number(retention))))
                  nil

                true ->
                  nil
              end

            if early do
              early
            else
              patch = Object.new()
              patch = if name != :undefined, do: Object.put(patch, "name", JS.string(name)), else: patch
              patch = if timezone != :undefined, do: Object.put(patch, "timezone", JS.string(timezone)), else: patch

              patch =
                if Object.has_key?(body, "hostnames") and rl.managed_sites,
                  do: Object.put(patch, "hostnames", body["hostnames"]),
                  else: patch

              site = Runlight.update_site(rl, id, patch)

              # A connected site answers as the list shows it, so the dashboard keeps its install and domains.
              site =
                if remote,
                  do:
                    site
                    |> Object.put("remote", remote["url"])
                    |> Object.put("remoteSite", remote["site"])
                    |> Object.put("manage", remote["scope"] == "manage")
                    |> Object.put("hostnames", remote["hostnames"]),
                  else: site

              json(JS.obj(site: site))
            end
          rescue
            error ->
              cond do
                Errors.range?(error) and Exception.message(error) == "Unknown site" -> coded("Unknown site", "unknown_site", 404)
                Errors.range?(error) -> refused(error, "site_invalid")
                true -> reraise error, __STACKTRACE__
              end
          end
      end
    else
      {:denied, access} -> denied(access)
      {:error, response} -> response
    end
  end

  ## Reading stats

  defp api_reads(routes, request, path, url) do
    rl = routes.rl
    Runlight.init(rl)
    # A shared dashboard sees exactly what its visitors see, even for someone signed in.
    share_id = Request.header(request, @share_header)

    gate =
      if share_id != nil do
        shared = if Regex.match?(~r/\A[a-f0-9]{32}\z/, share_id), do: Store.share_by_id(rl.store, share_id)

        cond do
          shared == nil -> {:error, coded("This share link no longer works", "share_gone", 404)}
          not shared_path?(path) -> {:error, coded("Not available on a shared dashboard", "share_not_available", 403)}
          true -> {:ok, shared, shared["site"]}
        end
      else
        case reader(routes, request) do
          access when access in [false, "unconfigured"] ->
            {:error, denied(access)}

          true ->
            {:ok, nil, nil}

          access ->
            if shared_path?(path),
              do: {:ok, nil, JS.or_else(access["site"], nil)},
              else: {:error, coded("API tokens can only read", "token_read_only", 403)}
        end
      end

    case gate do
      {:error, response} -> response
      {:ok, shared, only} -> reads(routes, request, path, url, shared, only)
    end
  end

  defp reads(routes, request, path, url, shared, only) do
    rl = routes.rl

    if path == "/api/sites" do
      visible = if only, do: Enum.filter(Runlight.sites(rl), &(&1["id"] == only)), else: Runlight.sites(rl)

      sites =
        Enum.map(visible, fn site ->
          remote = Runlight.remote(rl, site["id"])

          out =
            if remote && shared == nil,
              do:
                site
                |> Object.put("remote", remote["url"])
                |> Object.put("remoteSite", remote["site"])
                |> Object.put("manage", remote["scope"] == "manage")
                |> Object.put("hostnames", remote["hostnames"]),
              else: site

          # Hostnames say where the site lives; a share shows only its name.
          out = if shared, do: Object.put(out, "hostnames", []), else: out

          out =
            Object.put(out, "lastSeen", if(remote, do: Runlight.remote_last_seen(rl, site["id"]), else: Store.last_seen(rl.store, site["id"])))

          # Left out for a connected install that cannot be reached, so nobody reads "forever" by mistake.
          out =
            if shared do
              out
            else
              Object.put(
                out,
                "retentionMonths",
                if(remote, do: Runlight.remote_info(rl, site["id"]).retention_months, else: Runlight.retention(rl, site["id"]))
              )
            end

          if remote && shared == nil, do: Object.put(out, "connection", Runlight.remote_info(rl, site["id"]).connection), else: out
        end)

      # A share never learns how the install is run.
      json(if(shared, do: JS.obj(sites: sites), else: JS.obj(sites: sites, managed: rl.managed_sites)))
    else
      site =
        cond do
          shared -> {:ok, Runlight.site(rl, shared["site"])}
          only -> {:ok, Runlight.site(rl, param(url, "site") || only)}
          true -> query_site(routes, url)
        end

      case site do
        {:error, response} ->
          response

        {:ok, site} when site == nil ->
          coded("Unknown site", "unknown_site", 404)

        {:ok, site} ->
          cond do
            only != nil and site["id"] != only -> coded("Unknown site", "unknown_site", 404)
            (remote = Runlight.remote(rl, site["id"])) != nil -> pass_through(routes, remote, path, url, request)
            true -> site_reads(routes, path, url, site)
          end
      end
    end
  end

  defp site_reads(routes, path, url, site) do
    rl = routes.rl

    cond do
      path == "/api/icon" ->
        host = List.first(site["hostnames"])
        # Only a site's own domain, never the request's Host header, which a caller can write.
        icon = if host, do: Runlight.Icon.fetch_icon(rl, "https://#{host}")

        if icon == nil do
          coded("No icon", "icon_none", 404, nil, [{"cache-control", "private, max-age=3600"}])
        else
          Response.new(icon.body, 200, [
            {"content-type", icon.type},
            {"cache-control", "private, max-age=86400"},
            # An SVG served from this origin must never run script.
            {"content-security-policy", "default-src 'none'; style-src 'unsafe-inline'; sandbox"},
            {"x-content-type-options", "nosniff"}
          ])
        end

      path == "/api/realtime" ->
        json(Store.realtime(rl.store, site["id"], Runlight.now(rl)))

      true ->
        case read_query(routes, url, site) do
          {:error, response} -> response
          {:ok, read} -> report_reads(routes, path, url, site, read)
        end
    end
  end

  defp report_reads(routes, path, url, site, %{query: query, range: range, compared: compared}) do
    rl = routes.rl
    store = rl.store
    range_out = range_out(range, site)
    compare_out = if compared, do: JS.obj(from: compared.from_date, to: compared.to_date), else: :undefined
    before = fn -> %{query | from: compared.from, to: compared.to} end
    goal_match = Regex.run(~r/\A\/api\/goals\/([a-f0-9]{24})\z/, path)
    q = params_of(url)

    cond do
      path == "/api/stats" ->
        stats = Store.stats(store, query)
        previous = if compared, do: Store.stats(store, before.()), else: :undefined
        json(JS.obj(site: site["id"], range: range_out, compare: compare_out, stats: stats, previous: previous))

      path == "/api/goals" ->
        goals = Store.goals(store, site["id"])
        visitors = Store.visitors(store, query)
        previous_visitors = if compared, do: Store.visitors(store, before.()), else: 0
        # Every goal in one pass for the range, and one more for the comparison.
        now_all = Store.goal_totals_all(store, query, goals)
        before_all = if compared, do: Store.goal_totals_all(store, before.(), goals)

        rows =
          Enum.map(goals, fn goal ->
            now = now_all[goal["id"]]
            earlier = before_all && before_all[goal["id"]]

            goal
            |> Object.merge(now)
            |> Object.put("rate", if(visitors != 0, do: JS.divide(now["visitors"], visitors), else: 0))
            |> Object.put(
              "previous",
              if(earlier,
                do: Object.put(earlier, "rate", if(previous_visitors != 0, do: JS.divide(earlier["visitors"], previous_visitors), else: 0)),
                else: :undefined
              )
            )
          end)

        json(JS.obj(site: site["id"], range: range_out, compare: compare_out, visitors: visitors, goals: rows))

      goal_match ->
        goal = Store.goal_by_id(store, Enum.at(goal_match, 1))

        if goal == nil or goal["site"] != site["id"] do
          coded("Unknown goal", "unknown_goal", 404)
        else
          visitors = Store.visitors(store, query)
          totals = Store.goal_totals(store, query, goal)
          series = Store.goal_series(store, query, goal, Time.buckets(range, site["timezone"]))

          json(
            JS.obj(
              site: site["id"],
              range: range_out,
              goal: goal,
              totals: Object.put(totals, "rate", if(visitors != 0, do: JS.divide(totals["visitors"], visitors), else: 0)),
              series: series,
              sources: Store.goal_breakdown(store, query, goal, "source"),
              channels: Store.goal_breakdown(store, query, goal, "channel"),
              pages: Store.goal_breakdown(store, query, goal, "path")
            )
          )
        end

      path == "/api/series" ->
        points = Store.series(store, query, Time.buckets(range, site["timezone"]))
        # Comparison points line up with the main ones by position.
        previous =
          if compared,
            do: store |> Store.series(query, Time.buckets(compared, site["timezone"])) |> Enum.take(length(points)),
            else: :undefined

        json(JS.obj(site: site["id"], range: range_out, compare: compare_out, points: points, previous: previous))

      path == "/api/rhythm" ->
        rhythm(store, query, site, range_out)

      path == "/api/journeys" ->
        through =
          case Regex.run(~r/\A(\d+):(.+)\z/s, SearchParams.get(q, "through") || "") do
            [_, step, value] -> {JS.number(step), value}
            nil -> nil
          end

        # Journeys reads the newest visits up to a cap; say when it was reached.
        %{rows: rows, sampled: sampled} = Store.journey_pages(store, query, Runlight.Journeys.pages_per_visit())
        start = SearchParams.get(q, "start")
        finish = SearchParams.get(q, "end")

        options =
          %{steps: JS.number(SearchParams.get(q, "steps") || 5)}
          |> then(&if(start not in [nil, ""], do: Map.put(&1, :start, start), else: &1))
          |> then(&if(finish not in [nil, ""], do: Map.put(&1, :end, finish), else: &1))
          |> then(&if(through, do: Map.put(&1, :through, through), else: &1))

        answer = Runlight.Journeys.journeys(rows, options)
        out = JS.obj(site: site["id"], range: range_out) |> Object.merge(answer)
        out = if sampled, do: Object.put(out, "sampled", Runlight.Store.Sql.journey_visits()), else: out
        json(out)

      path == "/api/funnels" ->
        funnels = Store.funnels(store, site["id"])

        # One funnel at a time, so a page of funnels never takes every database connection at once.
        rows =
          Enum.map(funnels, fn funnel ->
            counts = Store.funnel_counts(store, query, funnel)
            steps = funnel["steps"] |> Enum.zip(counts) |> Enum.map(fn {step, n} -> Object.put(step, "visits", n) end)
            Object.put(funnel, "steps", steps)
          end)

        json(JS.obj(site: site["id"], range: range_out, funnels: rows))

      path == "/api/event-props" ->
        event = SearchParams.get(q, "event") || ""

        if event == "" do
          coded("Name the event", "event_needed", 400)
        else
          keys = Store.event_prop_keys(store, query, event)
          asked = SearchParams.get(q, "key")

          # A property name goes into a JSON path on SQLite, so quotes and backslashes are refused.
          if asked != nil and not Regex.match?(~r/\A[^"\\]{1,64}\z/u, asked) and true do
            coded("Bad property name", "property_bad", 400)
          else
            if asked != nil and JS.len16(asked) > 64 do
              coded("Bad property name", "property_bad", 400)
            else
              key = asked || (List.first(keys) && List.first(keys)["key"])
              limit = page_number(SearchParams.get(q, "limit"), 100, 1000)
              rows = if key, do: Store.event_prop_values(store, query, event, key, limit), else: []
              json(JS.obj(site: site["id"], range: range_out, event: event, keys: keys, key: key, rows: rows))
            end
          end
        end

      path == "/api/breakdown" ->
        dimension = SearchParams.get(q, "dimension") || ""

        if not Query.dimension?(dimension) do
          coded(~s(Unknown dimension "#{dimension}"), "unknown_dimension", 400, %{"dimension" => dimension})
        else
          limit = page_number(SearchParams.get(q, "limit"), 10, 1000)
          page = max(1, JS.or_else(JS.number(SearchParams.get(q, "page")), 1) |> finite_or(1))
          rows = Store.breakdown(store, query, dimension, limit, JS.floor((page - 1) * limit) |> trunc_int())

          if SearchParams.get(q, "format") == "csv" do
            download(
              "#{site["id"]}-#{dimension}-#{range.from_date}-#{range.to_date}.csv",
              rows_csv(rows, %{timezone: site["timezone"], dimension: dimension}),
              "text/csv; charset=utf-8"
            )
          else
            json(JS.obj(site: site["id"], range: range_out, dimension: dimension, rows: rows))
          end
        end

      # Everything the dashboard shows for a view, as a ZIP of CSV files.
      path == "/api/export" ->
        export(rl, query, range, compared, site)

      true ->
        coded("Not found", "not_found", 404)
    end
  end

  defp finite_or(n, fallback), do: if(JS.finite?(n), do: n, else: fallback)
  defp trunc_int(n) when is_float(n), do: trunc(n)
  defp trunc_int(n), do: n

  # `Math.min(max, Math.max(1, Number(value) || fallback))`, as a whole number for SQL.
  defp page_number(value, fallback, max) do
    n = JS.number(value)
    n = if JS.truthy?(n), do: n, else: fallback

    n =
      case n do
        :infinity -> max
        :neg_infinity -> 1
        n -> n
      end

    n = n |> max(1) |> min(max)
    if is_float(n), do: n, else: n
  end

  defp rhythm(store, query, site, range_out) do
    # Visits per weekday and hour, plus each cell's details for its tooltip.
    empty = for _ <- 0..6, do: for(_ <- 0..23, do: %{visits: 0, visitors: 0, pageviews: 0, bounced: 0})

    cells =
      Enum.reduce(Store.hourly(store, query), empty, fn row, cells ->
        {weekday, h} = Time.local_weekday_hour(row.quarter * 900_000, site["timezone"])

        List.update_at(cells, weekday, fn day ->
          List.update_at(day, h, fn c ->
            %{
              visits: c.visits + row.visits,
              visitors: c.visitors + row.visitors,
              pageviews: c.pageviews + row.pageviews,
              bounced: c.bounced + row.bounced
            }
          end)
        end)
      end)

    grid = Enum.map(cells, fn day -> Enum.map(day, & &1.visits) end)

    details =
      Enum.map(cells, fn day ->
        Enum.map(day, fn c ->
          JS.obj(visits: c.visits, visitors: c.visitors, pageviews: c.pageviews, bounceRate: if(c.visits != 0, do: c.bounced / c.visits, else: 0))
        end)
      end)

    json(JS.obj(site: site["id"], range: range_out, grid: grid, cells: details))
  end

  defp export(rl, query, range, compared, site) do
    store = rl.store
    tz = site["timezone"]
    stats = Store.stats(store, query)
    previous = if compared, do: Store.stats(store, %{query | from: compared.from, to: compared.to})
    now = sheet_row(stats, %{timezone: tz})
    before = previous && sheet_row(previous, %{timezone: tz})

    overview =
      Zip.csv(
        ["metric", "value"] ++ if(before, do: ["previous"], else: []),
        Enum.map(Object.keys(now), fn m -> [m, now[m]] ++ if(before, do: [before[m]], else: []) end)
      )

    points = Store.series(store, query, Time.buckets(range, tz))
    files = [%{name: "overview.csv", text: overview}, %{name: "over-time.csv", text: rows_csv(points, %{timezone: tz, interval: range.interval})}]

    files =
      files ++
        Enum.flat_map(Query.dimensions(), fn dimension ->
          rows = Store.breakdown(store, query, dimension, 1000, 0)
          if rows == [], do: [], else: [%{name: "#{dimension}.csv", text: rows_csv(rows, %{timezone: tz, dimension: dimension})}]
        end)

    goals = Store.goals(store, site["id"])

    files =
      if goals == [] do
        files
      else
        totals = Store.goal_totals_all(store, query, goals)

        files ++
          [
            %{
              name: "goals.csv",
              text:
                Zip.csv(
                  ["goal", "conversions", "visitors", "revenue", "currency"],
                  Enum.map(goals, fn g ->
                    t = totals[g["id"]]
                    [g["name"], t["conversions"], t["visitors"], t["revenue"], g["currency"]]
                  end)
                )
            }
          ]
      end

    download("#{site["id"]}-#{range.from_date}-#{range.to_date}.zip", Zip.zip(files, Runlight.now(rl)), "application/zip")
  end

  ## Answering a request

  @doc """
  Answers one request: a `%Runlight.Http.Request{}` whose URL is absolute,
  under the base path. Anything outside it answers a JSON 404.
  """
  @spec handle(t(), Request.t()) :: Response.t()
  def handle(%__MODULE__{} = routes, %Request{} = request) do
    request = if request.ref == nil, do: %{request | ref: make_ref()}, else: request

    try do
      answer(routes, request)
    after
      Process.delete({:runlight_managed, request.ref})
      Process.delete({:runlight_member, request.ref})
    end
  end

  defp oauth_ctx(routes) do
    %{
      rl: routes.rl,
      base: routes.base,
      is_owner: fn request -> can_read(routes, request) == true end,
      is_reader: fn request ->
        cond do
          routes.authorize -> routes.authorize.(request) == "read"
          routes.web -> Runlight.Accounts.Web.access(routes.web, request) == "read"
          true -> false
        end
      end,
      sign_in: routes.sign_in,
      account_of: routes.account_of,
      token_made: routes.token_made
    }
  end

  defp oauth_document?(path),
    do: String.starts_with?(path, "/.well-known/oauth-") or String.starts_with?(path, "/.well-known/openid-configuration")

  defp answer(routes, request) do
    url = Url.new(request.url)
    base = routes.base

    cond do
      # OAuth clients look for these at the site's root; an app routes them here when it wants OAuth.
      base != "" and oauth_document?(url.pathname) ->
        Runlight.OAuth.response(oauth_ctx(routes), request, url.pathname, url) || coded("Not found", "not_found", 404)

      base != "" and url.pathname != base and not String.starts_with?(url.pathname, base <> "/") ->
        coded("Not found", "not_found", 404)

      true ->
        path = binary_part(url.pathname, byte_size(base), byte_size(url.pathname) - byte_size(base))
        path = if path == "", do: "/", else: path

        try do
          route(routes, request, path, url)
        rescue
          error ->
            Logger.error("Runlight: " <> Exception.format(:error, error, __STACKTRACE__))
            coded("Internal error", "internal", 500)
        end
    end
  end

  defp route(routes, request, path, url) do
    rl = routes.rl
    method = request.method

    cond do
      # Checked before any route, so a connected site's pass-through to its install is held to it too.
      admin_only?(path, method) and can_read(routes, request) == true and member?(request) ->
        coded("Only an owner or admin can change this", "admin_only", 403)

      routes.web != nil and (web_answer = Runlight.Accounts.Web.handle(routes.web, request, path)) != nil ->
        web_answer

      path == "/s.js" and method == "GET" ->
        script = tracker_script(routes, param(url, "site"))

        headers = [
          {"content-type", "application/javascript; charset=utf-8"},
          # Short, so a new click goal reaches visitors within minutes; the etag makes rechecks cheap.
          {"cache-control", "public, max-age=300"},
          {"etag", script.etag}
        ]

        if Request.header(request, "if-none-match") == script.etag,
          do: Response.new(nil, 304, headers),
          else: Response.new(script.body, 200, headers)

      path == "/pick.js" and method == "GET" ->
        # The picker sends what it picked only to the dashboard its ticket names, and runs only on that site's pages.
        target = pick_target(rl, param(url, "runlight_ticket") || "")
        if target, do: Runlight.init(rl)
        hosts = if target, do: (Runlight.site(rl, target.site) || %{})["hostnames"], else: []

        script =
          Assets.picker()
          |> String.replace(@pick_target_placeholder, JS.stringify(if(hosts, do: (target && target.origin) || "", else: "")), global: false)
          |> String.replace(@pick_hosts_placeholder, JS.stringify(JS.stringify(hosts || [])), global: false)

        Response.new(script, 200, [{"content-type", "application/javascript; charset=utf-8"}, {"cache-control", "no-store"}])

      path == "/assets/world.#{Assets.world_hash()}.json" and method == "GET" ->
        Response.new(Assets.world_json(), 200, [
          {"content-type", "application/json; charset=utf-8"},
          {"cache-control", "public, max-age=31536000, immutable"}
        ])

      (locale = Regex.run(~r/\A\/assets\/locale\.([a-z]{2,3})\.([a-f0-9]+)\.json\z/, path)) != nil and
        Enum.at(locale, 2) == Assets.locales_hash() and Enum.at(locale, 1) in Assets.locale_codes() and method == "GET" ->
        Response.new(Map.fetch!(Assets.locales(), Enum.at(locale, 1)), 200, [
          {"content-type", "application/json; charset=utf-8"},
          {"cache-control", "public, max-age=31536000, immutable"}
        ])

      String.starts_with?(path, "/assets/app.") and method == "GET" ->
        asset =
          cond do
            path == "/assets/app.#{Assets.dashboard_hash()}.js" -> Assets.dashboard_js()
            path == "/assets/app.#{Assets.dashboard_hash()}.css" -> Assets.dashboard_css()
            true -> nil
          end

        if asset == nil do
          coded("Not found", "not_found", 404)
        else
          Response.new(asset, 200, [
            {"content-type", if(String.ends_with?(path, ".js"), do: "application/javascript; charset=utf-8", else: "text/css; charset=utf-8")},
            {"cache-control", "public, max-age=31536000, immutable"}
          ])
        end

      path == "/e" ->
        cond do
          method == "OPTIONS" ->
            Response.new(nil, 204, [
              {"access-control-allow-origin", "*"},
              {"access-control-allow-methods", "POST"},
              {"access-control-max-age", "86400"}
            ])

          method != "POST" ->
            coded("Method not allowed", "method_not_allowed", 405)

          true ->
            try do
              Runlight.collect(rl, request)
            rescue
              error -> Logger.error("Runlight: could not record an event #{Exception.message(error)}")
            end

            # The same answer whatever happened, so the endpoint reveals nothing.
            Response.new(nil, 202, [{"access-control-allow-origin", "*"}])
        end

      path == "/api" or String.starts_with?(path, "/api/") ->
        api(routes, request, path, url)

      (String.starts_with?(path, "/oauth/") or oauth_document?(path)) and
          (oauth = Runlight.OAuth.response(oauth_ctx(routes), request, path, url)) != nil ->
        oauth

      path == "/mcp" ->
        mcp(routes, request, url)

      (unsubscribe = Regex.run(~r/\A\/unsubscribe\/([^\/]+)\/?\z/, path)) != nil and method in ["GET", "POST"] ->
        unsubscribe_page(routes, request, Enum.at(unsubscribe, 1))

      (share = Regex.run(~r/\A\/share\/([^\/]+)\/?\z/, path)) != nil and method == "GET" ->
        Runlight.init(rl)
        id = Enum.at(share, 1)
        found = if Regex.match?(~r/\A[a-f0-9]{32}\z/, id), do: Store.share_by_id(rl.store, id)

        if found == nil do
          lang = accepted_language(request)

          small_page(
            lang,
            "<h1>#{escape_html(Messages.t(lang, "share.goneTitle"))}</h1><p>#{escape_html(Messages.t(lang, "share.gone"))}</p>",
            404
          )
        else
          Response.new(dashboard(routes.base, found["id"], "", routes.geo_credit, false, ""), 200, [
            {"content-type", "text/html; charset=utf-8"},
            {"cache-control", "no-store"},
            {"content-security-policy", @dashboard_csp},
            {"x-frame-options", "DENY"},
            # The share id is the key; never send it on to another site.
            {"referrer-policy", "no-referrer"},
            {"x-robots-tag", "noindex"}
          ])
        end

      path in ["/", ""] and method == "GET" ->
        given = param(url, "token")

        if given not in [nil, ""] and is_binary(routes.token) and routes.token != "" and Crypto.constant_time_equal?(given, routes.token) do
          cleaned = Url.with_params(url, SearchParams.delete(params_of(url), "token"))
          secure = if url.protocol == "https:", do: "; Secure", else: ""

          Response.new(nil, 303, [
            {"location", cleaned.pathname <> cleaned.search},
            {"set-cookie", "#{@cookie}=#{cookie_value(routes.token)}; Path=#{if routes.base == "", do: "/", else: routes.base}; HttpOnly; SameSite=Lax; Max-Age=2592000#{secure}"}
          ])
        else
          # The page itself holds no data; the API it calls checks access and the page explains how to sign in.
          Response.new(dashboard(routes.base, "", routes.sign_out, routes.geo_credit, routes.web != nil, routes.sign_in), 200, [
            {"content-type", "text/html; charset=utf-8"},
            {"cache-control", "no-store"},
            {"content-security-policy", @dashboard_csp},
            {"x-frame-options", "DENY"},
            {"referrer-policy", "same-origin"}
          ])
        end

      true ->
        coded("Not found", "not_found", 404)
    end
  end

  defp mcp(routes, request, url) do
    if request.method != "POST" do
      # No server-sent stream and no sessions: every message is one POST.
      coded("Method not allowed", "method_not_allowed", 405, nil, [{"allow", "POST"}])
    else
      case reader(routes, request) do
        access when access in [false, "unconfigured"] ->
          refused = denied(access)
          # Points an OAuth client at the metadata that starts the sign-in.
          Response.put_header(
            refused,
            "www-authenticate",
            ~s(Bearer realm="runlight", resource_metadata="#{Runlight.OAuth.resource_metadata_url(Url.origin(url), routes.base)}")
          )

        _ ->
          # Each tool reads the HTTP API with the caller's own headers, so it sees what they may.
          Runlight.Mcp.response(request, tool_reader(routes, request, url))
      end
    end
  end
end
