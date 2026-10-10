defmodule Runlight do
  @moduledoc """
  Privacy friendly web analytics that lives inside your Elixir app: the same
  library as `@runlight/sdk`, the same tables, and the same answers, so an
  Elixir app and a Node or PHP one can share a database.

  An instance is a child of your application's supervision tree:

      children = [
        MyApp.Repo,
        {Runlight,
         store: {Runlight.Store, repo: MyApp.Repo},
         site: [name: "Example", hostnames: ["example.com"], timezone: "Europe/London"]}
      ]

  and the dashboard, the API, and the tracker are a Plug, mounted in a
  Phoenix router or a `Plug.Router` (see `Runlight.Plug`):

      forward "/runlight", Runlight.Plug

  Then add `<script defer src="/runlight/s.js"></script>` to your pages.

  ## Options

  The options are the SDK's, in snake case:

    * `:store` - `{Runlight.Store, repo: MyApp.Repo}`, or a `Runlight.Store`.
    * `:site` - the site this install counts: `id` (default "default"),
      `name`, `hostnames` (without www; empty means any host), and `timezone`
      (an IANA name, default "UTC").
    * `:sites` - several sites, told apart by hostname; each needs its
      hostnames.
    * `:managed_sites` - sites are added, changed, and deleted in the
      dashboard and kept in the database, as the standalone server does.
    * `:geo` - a lookup for an IP when the platform sends no location headers,
      such as `Runlight.Geo.file_lookup("GeoLite2-City.mmdb")`.
    * `:trust_proxy` - read the client's address from forwarding headers:
      `true` (the default: the last X-Forwarded-For entry, then X-Real-IP,
      then CF-Connecting-IP), one header's name, or `false` for the
      connection's own address. Left unset, it warns once when a request
      comes straight from a public address with none of those headers.
    * `:link_path` - where short links on the app's own domain live, default
      "/go".
    * `:mail` - the mail service for email reports, set in code.
    * `:secret` - encrypts the keys kept in the database; default
      `RUNLIGHT_SECRET`, then `RUNLIGHT_TOKEN`.
    * `:rate_limit` - tracker requests per address per minute, default 120;
      `false` for none.
    * `:fetcher` - every outgoing request goes through it (see
      `Runlight.Fetch`); default `&Runlight.Fetch.httpc/2`.
    * `:local_installs` - lets a connected install be at http://localhost or
      http://127.0.0.1, for trying a hub and an app on one machine. Default
      false: otherwise anyone who can add a site could have this server ask
      services on its own machine, so other installs must be public https
      addresses.
    * `:now` - a function answering epoch milliseconds, for tests.
    * `:name` - the instance's name, default `Runlight`.
  """

  alias Runlight.Crypto
  alias Runlight.Hash
  alias Runlight.Http.Headers
  alias Runlight.Http.Request
  alias Runlight.Http.Response
  alias Runlight.JS
  alias Runlight.JS.Object
  alias Runlight.Payload
  alias Runlight.RateLimit
  alias Runlight.Safefetch
  alias Runlight.SettingsError
  alias Runlight.Sources
  alias Runlight.State
  alias Runlight.Store
  alias Runlight.Time
  alias Runlight.Ua
  alias Runlight.Url

  require Logger

  defstruct [
    :name,
    :store,
    :managed_sites,
    :geo,
    :trust_proxy,
    :warn_direct,
    :limit,
    :now,
    :link_path,
    :mail,
    :secret,
    :fetcher,
    :local_installs,
    :table
  ]

  @type t :: %__MODULE__{}

  @doc "A path on every link domain that answers when the domain reaches this Runlight."
  def link_domain_check, do: "/.well-known/runlight-link-domain"

  # Raised whenever what a rolled-up day holds changes.
  @rollup_version 3
  @rollup_batch 10
  @metered_rollup_batch 4
  @rollup_delay_ms 2 * 3_600_000
  # The most a connected install's list of sites may weigh; a real one is a few kilobytes.
  @remote_max_bytes 2 * 1024 * 1024

  @doc "The choices for how long a site keeps its visits, in months."
  def retention_months, do: [6, 12, 24, 36, 60]

  @doc "Thirty minutes without a request ends a session."
  def session_idle_ms, do: 30 * 60 * 1000

  @doc "What passes for an email address: something@somewhere.tld, with no spaces, quotes, or angle brackets."
  def email?(value), do: is_binary(value) and Regex.match?(~r/\A[^\s@<>"]+@[^\s@<>"]+\.[^\s@<>"]+\z/u, value)

  @doc "An environment variable, trimmed, or nil when it is empty."
  @spec env(String.t()) :: String.t() | nil
  def env(name) do
    case System.get_env(name) do
      nil -> nil
      value -> if JS.trim(value) == "", do: nil, else: JS.trim(value)
    end
  end

  ## Making an instance

  @doc """
  An instance from its options, with its state in a table owned by the
  calling process. In an app, start one under the supervision tree instead
  (`{Runlight, opts}`); this is for tests and scripts.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    store =
      case Keyword.get(opts, :store) do
        %Store{} = store -> store
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        {Store, store_opts} -> apply(Store, :ecto, [store_opts])
        nil -> raise ArgumentError, ~s(Runlight: pass a store, such as {Runlight.Store, repo: MyApp.Repo})
        other -> raise ArgumentError, "Runlight: unknown store #{inspect(other)}"
      end

    managed = Keyword.get(opts, :managed_sites, false) == true

    configured =
      cond do
        managed -> []
        Keyword.get(opts, :sites) not in [nil, []] -> Keyword.get(opts, :sites)
        true -> [Keyword.get(opts, :site) || []]
      end

    configured = configured |> Enum.with_index() |> Enum.map(fn {site, i} -> site_row(site, i) end)

    if length(configured) > 1 and Enum.any?(configured, &(&1["hostnames"] == [])),
      do: raise(ArgumentError, "Runlight: with several sites, give each one its hostnames")

    if length(Enum.uniq_by(configured, & &1["id"])) != length(configured),
      do: raise(ArgumentError, "Runlight: two sites share an id")

    per_minute = Keyword.get(opts, :rate_limit, 120)
    table = State.new()
    State.put(table, :configured, configured)

    # false, 0, or anything that is not a positive number means no limit, never a limit of nothing.
    limit =
      case JS.number(per_minute) do
        n when per_minute != false and is_number(n) and n > 0 -> RateLimit.new(table, :tracker, n)
        _ -> nil
      end

    link_path = "/" <> String.replace(Keyword.get(opts, :link_path, "/go"), ~r/^\/+|\/+$/, "")

    %__MODULE__{
      name: Keyword.get(opts, :name, __MODULE__),
      store: store,
      managed_sites: managed,
      geo: Keyword.get(opts, :geo),
      trust_proxy: if(is_nil(opts[:trust_proxy]), do: true, else: opts[:trust_proxy]),
      # Warned about once, when trust_proxy was left at its default and answers a public address directly.
      warn_direct: is_nil(opts[:trust_proxy]),
      limit: limit,
      now: Keyword.get(opts, :now) || fn -> System.os_time(:millisecond) end,
      link_path: link_path,
      mail: Keyword.get(opts, :mail),
      secret: Keyword.get(opts, :secret) || env("RUNLIGHT_SECRET") || env("RUNLIGHT_TOKEN"),
      fetcher: Keyword.get(opts, :fetcher) || (&Runlight.Fetch.httpc/2),
      local_installs: Keyword.get(opts, :local_installs, false) == true,
      table: table
    }
  end

  @doc false
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {Runlight.Server, :start_link, [opts]}, type: :worker}
  end

  @doc "The instance started under `name` in a supervision tree."
  @spec instance(atom()) :: t()
  def instance(name \\ __MODULE__) do
    case :persistent_term.get({__MODULE__, name}, nil) do
      nil ->
        raise ArgumentError,
              "Runlight: no instance named #{inspect(name)} is running; start {Runlight, opts} in your supervision tree"

      rl ->
        rl
    end
  end

  defp site_row(options, index) do
    options = Map.new(options, fn {k, v} -> {to_string(k), v} end)
    timezone = Map.get(options, "timezone") || "UTC"
    unless Time.timezone?(timezone), do: raise(ArgumentError, ~s(Runlight: unknown timezone "#{timezone}"))
    id = Map.get(options, "id") || if(index == 0, do: "default", else: "")

    if id == "" or not Regex.match?(~r/\A[a-z0-9][a-z0-9._-]{0,63}\z/i, id),
      do: raise(ArgumentError, ~s(Runlight: site id "#{id}" must be letters, digits, dots, dashes, or underscores))

    hostnames = Map.get(options, "hostnames") || []

    JS.obj(
      id: id,
      name: Map.get(options, "name") || List.first(hostnames) || "My site",
      hostnames: Enum.map(hostnames, &Sources.strip_www/1),
      timezone: timezone
    )
  end

  @doc "The clock, in epoch milliseconds."
  @spec now(t()) :: integer()
  def now(%__MODULE__{now: now}), do: now.()

  @doc "An outgoing request through the instance's fetcher (see `Runlight.Fetch`)."
  @spec fetch(t(), String.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  def fetch(%__MODULE__{fetcher: fetcher}, url, opts \\ []) do
    fetcher.(url, opts)
  rescue
    error -> {:error, error}
  end

  defp configured(rl), do: State.get(rl.table, :configured, [])
  defp set_configured(rl, sites), do: State.put(rl.table, :configured, sites)
  defp overrides(rl), do: State.get(rl.table, :overrides, %{})
  defp remotes(rl), do: State.get(rl.table, :remotes, %{})

  ## Mail

  @doc "The mail service: from code, or as saved in the dashboard. Nil when there is none."
  @spec mail_settings(t()) :: Object.t() | nil
  def mail_settings(rl) do
    if rl.mail do
      rl.mail |> Object.new() |> Object.put("source", "code")
    else
      init(rl)

      with sealed when is_binary(sealed) <- Store.setting(rl.store, "mail"),
           opened when is_binary(opened) <- Crypto.unseal(sealed, rl.secret),
           {:ok, %Object{} = settings} <- JS.parse(opened) do
        Object.put(settings, "source", "dashboard")
      else
        _ -> nil
      end
    end
  end

  @doc """
  Saves the mail service from the dashboard. A secret field left blank keeps
  the saved value, so the browser never needs to see it.
  """
  @spec save_mail_settings(t(), Object.t() | nil) :: :ok
  def save_mail_settings(rl, input) do
    if rl.mail,
      do: raise(Runlight.MailError, message: "The mail service is set in code", code: "mail_in_code", params: %{})

    if input == nil do
      Store.set_setting(rl.store, "mail", nil)
    else
      before = mail_settings(rl)
      service = Enum.find(Runlight.Mail.services(), &(&1["id"] == input["service"]))

      if service == nil,
        do: raise(Runlight.MailError, message: "Pick a mail service", code: "mail_service", params: %{})

      fields = service["fields"]
      text = fn name -> input |> JS.prop(name) |> JS.nullish("") |> JS.string() |> JS.trim() end

      settings =
        Enum.reduce(fields, JS.obj(service: service["id"]), fn f, acc ->
          if f["secret"], do: acc, else: Object.put(acc, f["name"], text.(f["name"]))
        end)

      # A blank secret keeps the saved one only while the connection is the same,
      # so changing the host cannot send a saved password somewhere new.
      same =
        before != nil and before["service"] == service["id"] and
          Enum.all?(fields, fn f ->
            f["secret"] == true or JS.string(JS.nullish(before[f["name"]], "")) == settings[f["name"]]
          end)

      settings =
        Enum.reduce(fields, settings, fn f, acc ->
          if f["secret"] do
            given = text.(f["name"])

            Object.put(
              acc,
              f["name"],
              if(given == "" and same, do: JS.string(JS.nullish(before[f["name"]], "")), else: given)
            )
          else
            acc
          end
        end)

      from = text.("from")

      unless email?(from),
        do:
          raise(Runlight.MailError,
            message: "Enter the address reports come from, like reports@example.com",
            code: "mail_from",
            params: %{}
          )

      from_name = input |> JS.prop("fromName") |> JS.nullish("") |> JS.string() |> JS.trim() |> JS.slice(0, 80)
      config = settings |> Object.put("from", from)
      config = if from_name != "", do: Object.put(config, "fromName", from_name), else: config
      Runlight.Mail.check_config(config)
      Store.set_setting(rl.store, "mail", Crypto.seal(JS.stringify(config), rl.secret))
    end
  end

  @doc "Sends one email through the mail service: `%{to, subject, html, text, headers}`."
  @spec send_mail(t(), map()) :: :ok
  def send_mail(rl, message) do
    settings = mail_settings(rl)

    if settings == nil,
      do: raise(Runlight.MailError, message: "Set up a mail service first", code: "mail_unset", params: %{})

    Runlight.Mail.send(rl, settings, Map.merge(message, %{from: settings["from"], from_name: settings["fromName"]}))
  end

  @doc """
  Sends every report that is due: last week's on Monday from 8am, last
  month's on the 1st, in each site's timezone. Safe to run often; each
  period goes out once.
  """
  @spec send_reports(t()) :: %{sent: non_neg_integer(), failed: non_neg_integer()}
  def send_reports(rl) do
    init(rl)
    reports = Store.reports(rl.store)

    if reports == [] or mail_settings(rl) == nil do
      %{sent: 0, failed: 0}
    else
      now = now(rl)

      Enum.reduce(reports, %{sent: 0, failed: 0}, fn r, result ->
        site = site(rl, r["site"])
        period = site && Runlight.Reports.last_period(r["frequency"], now, site["timezone"])

        cond do
          site == nil -> result
          now < period.due_at or r["lastPeriod"] == period.key -> result
          not Store.claim_report(rl.store, r["id"], period.key, now) -> result
          true -> deliver_claimed(rl, r, site, period, result)
        end
      end)
    end
  end

  defp deliver_claimed(rl, r, site, period, result) do
    deliver_report(rl, r, site, period)
    %{result | sent: result.sent + 1}
  rescue
    error ->
      Store.release_report(rl.store, r["id"], period.key, r["lastPeriod"])

      Logger.error(
        "Runlight: could not send the #{r["frequency"]} report for #{site["name"]} to #{r["email"]}: #{Exception.message(error)}"
      )

      %{result | failed: result.failed + 1}
  end

  @doc "Builds and sends one report. Also used by \"Send a sample now\"."
  @spec deliver_report(t(), Object.t(), Object.t(), map() | nil) :: :ok
  def deliver_report(rl, r, site, period \\ nil) do
    period = period || Runlight.Reports.last_period(r["frequency"], now(rl), site["timezone"])
    unsubscribe = "#{r["origin"]}/unsubscribe/#{r["token"]}"
    dashboard = "#{r["origin"]}/?site=#{JS.encode_uri_component(site["id"])}"

    report =
      Runlight.Reports.build_report(rl, site, r["frequency"], period, r["lang"], %{
        dashboard: dashboard,
        unsubscribe: unsubscribe
      })

    send_mail(rl, %{
      to: r["email"],
      subject: report.subject,
      html: report.html,
      text: report.text,
      headers: [{"List-Unsubscribe", "<#{unsubscribe}>"}, {"List-Unsubscribe-Post", "List-Unsubscribe=One-Click"}]
    })
  end

  ## Starting

  @doc "Creates tables and records the configured sites. Runs once."
  @spec init(t()) :: :ok
  def init(%__MODULE__{table: table} = rl) do
    if State.get(table, :ready) do
      :ok
    else
      State.one_at_a_time(table, :init, fn ->
        unless State.get(table, :ready) do
          start(rl)
          State.put(table, :ready, true)
        end
      end)

      :ok
    end
  end

  defp start(rl) do
    Store.migrate(rl.store)
    # A database that never had its statistics gathered gets them now, before any report is read.
    Store.optimize(rl.store, true)

    if rl.managed_sites do
      set_configured(rl, Store.sites(rl.store))
      load_remotes(rl)
    end

    for site <- configured(rl), do: Store.upsert_site(rl.store, site, now(rl))
    State.put(rl.table, :overrides, Store.site_overrides(rl.store))

    # A process starting with a timezone set in code is the newest word on it: if the code changed it,
    # the days built in the old one are cleared here, once, and never by a process still running.
    for site <- sites(rl), not Map.has_key?(remotes(rl), site["id"]) do
      stored = Store.setting(rl.store, "rollup-zone:#{site["id"]}")
      zone = if stored, do: JS.parse!(stored)["zone"]

      cond do
        zone == nil ->
          Store.set_setting(
            rl.store,
            "rollup-zone:#{site["id"]}",
            JS.stringify(JS.obj(zone: site["timezone"], since: 0))
          )

        zone != site["timezone"] ->
          zone_changed(rl, site["id"], site["timezone"])

        true ->
          :ok
      end
    end

    :ok
  end

  @doc "The routes: the dashboard, the API, and the tracker (see `Runlight.Routes`)."
  @spec routes(t(), keyword()) :: Runlight.Routes.t()
  def routes(rl, opts \\ []), do: Runlight.Routes.new(rl, opts)

  ## Sites

  @doc "The sites, with any settings changed in the dashboard applied."
  @spec sites(t()) :: [Object.t()]
  def sites(rl) do
    overrides = overrides(rl)
    Enum.map(configured(rl), fn site -> Object.merge(site, Map.get(overrides, site["id"], Object.new())) end)
  end

  # Checks a list of hostnames for a managed site: at least one, each a domain, none taken.
  defp hostnames_for(rl, input, except \\ nil) do
    list = if is_list(input), do: input, else: input |> JS.nullish("") |> JS.string() |> String.split(~r/[\s,]+/u)

    hostnames =
      list
      |> Enum.map(fn h ->
        h
        |> JS.string()
        |> JS.trim()
        |> String.replace(~r/^https?:\/\//, "")
        |> String.replace(~r/[\/:].*$/s, "")
        |> Sources.strip_www()
      end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if hostnames == [],
      do: raise(SettingsError, message: "Add the site's domain, like example.com", code: "site_domain_needed")

    for host <- hostnames do
      unless Regex.match?(~r/\A(?=.{1,253}\z)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z/, host) or
               host == "localhost",
             do:
               raise(SettingsError,
                 message: ~s("#{host}" is not a domain name),
                 code: "site_domain_invalid",
                 params: %{"host" => host}
               )

      owner = Enum.find(configured(rl), &(&1["id"] != except and host in &1["hostnames"]))

      if owner,
        do:
          raise(SettingsError,
            message: "#{host} already belongs to #{owner["name"]}",
            code: "site_domain_taken",
            params: %{"host" => host, "site" => owner["name"]}
          )
    end

    hostnames
  end

  defp load_remotes(rl) do
    remotes =
      for %{key: key, value: value} <- Store.settings_starting_with(rl.store, "remote:"),
          opened = Crypto.unseal(value, rl.secret),
          opened != nil,
          into: %{} do
        {String.replace_prefix(key, "remote:", ""), JS.parse!(opened)}
      end

    State.put(rl.table, :remotes, remotes)
  end

  @doc "The install a site is read from, when it is counted elsewhere: `url`, `token`, `site`, `hostnames`, `scope`."
  @spec remote(t(), String.t() | nil) :: Object.t() | nil
  def remote(rl, id), do: Map.get(remotes(rl), id)

  @doc "When a connected install's site last had a visit, asked at most once a minute."
  def remote_last_seen(rl, id) do
    case remote_info(rl, id) do
      nil -> nil
      info -> info.last_seen
    end
  end

  @doc """
  What a connected install says about its site: its last visit and how long
  it keeps visits, asked at most once a minute, and whether it answered.
  """
  @spec remote_info(t(), String.t()) :: map() | nil
  def remote_info(rl, id) do
    remote = remote(rl, id)
    cached = State.get(rl.table, {:remote_seen, id})

    cond do
      remote == nil ->
        nil

      cached && now(rl) - cached.at < 60_000 ->
        cached

      true ->
        info = %{last_seen: if(cached, do: cached.last_seen), retention_months: :undefined, connection: "unreachable"}

        info =
          case Safefetch.install_fetch(rl, "#{remote["url"]}/api/sites",
                 headers: [{"authorization", "Bearer #{remote["token"]}"}],
                 timeout: 8000
               ) do
            {:ok, answer} ->
              info = if answer.status in [401, 403], do: %{info | connection: "refused"}, else: info

              with true <- byte_size(answer.body) <= @remote_max_bytes,
                   {:ok, %Object{} = body} <- Response.json(answer),
                   sites when is_list(sites) <- body["sites"],
                   %Object{} = there <- Enum.find(sites, &(JS.object?(&1) and &1["id"] == remote["site"])) do
                %{
                  last_seen: JS.nullish(JS.prop(there, "lastSeen"), nil),
                  retention_months: JS.nullish(JS.prop(there, "retentionMonths"), nil),
                  connection: "ok"
                }
              else
                _ -> info
              end

            {:error, _} ->
              info
          end

        State.put(rl.table, {:remote_seen, id}, Map.put(info, :at, now(rl)))
    end
  end

  @doc "Forgets what a connected install said, after a change made through it."
  def forget_remote_info(rl, id), do: State.delete(rl.table, {:remote_seen, id})

  # Asks a connected install to delete the token this server holds for it. A failure leaves it listed there.
  defp revoke_remote_token(rl, remote) do
    _ =
      Safefetch.install_fetch(rl, "#{remote["url"]}/api/token",
        method: "DELETE",
        headers: [{"authorization", "Bearer #{remote["token"]}"}],
        timeout: 5000
      )

    :ok
  end

  defp by_name(sites), do: Enum.sort(sites, fn a, b -> Runlight.Collate.compare(a["name"], b["name"]) <= 0 end)

  # Connects a site counted by another Runlight (an app's own install) so this server shows it too.
  defp add_remote_site(rl, input) do
    url = input |> JS.prop("url") |> JS.nullish("") |> JS.string() |> JS.trim() |> String.replace(~r/\/+\z/, "")

    unless Safefetch.install_address?(url, rl.local_installs),
      do:
        raise(SettingsError,
          message: "Enter the install's address, like https://example.com/runlight",
          code: "connect_url"
        )

    token = input |> JS.prop("token") |> JS.nullish("") |> JS.string() |> JS.trim()
    if token == "", do: raise(SettingsError, message: "Enter an API token from that install", code: "install_token")
    auth = [{"authorization", "Bearer #{token}"}]

    answer =
      case Safefetch.install_fetch(rl, "#{url}/api/sites", headers: auth, timeout: 10_000) do
        {:ok, answer} ->
          answer

        {:error, _} ->
          raise SettingsError,
            message: "Could not reach #{url}",
            code: "unreachable",
            params: %{"host" => Url.host(Url.new(url))}
      end

    if answer.status in [401, 403],
      do: raise(SettingsError, message: "That install refused the token", code: "install_refused")

    body =
      with true <- byte_size(answer.body) <= @remote_max_bytes,
           {:ok, %Object{} = body} <- Response.json(answer),
           do: body,
           else: (_ -> nil)

    sites = body && body["sites"]

    unless Response.ok?(answer) and is_list(sites) and sites != [],
      do:
        raise(SettingsError,
          message: "#{url} did not answer like a Runlight install",
          code: "connect_not_runlight",
          params: %{"url" => url}
        )

    # What the token may do there; an install from before manage tokens has no /api/token and reads only.
    {scope, token_site} =
      case Safefetch.install_fetch(rl, "#{url}/api/token", headers: auth, timeout: 10_000) do
        {:ok, about} ->
          info =
            if Response.ok?(about) do
              with true <- byte_size(about.body) <= @remote_max_bytes,
                   {:ok, %Object{} = i} <- Response.json(about),
                   do: i,
                   else: (_ -> nil)
            end

          {if(info && info["scope"] == "manage", do: "manage", else: "read"),
           JS.string(JS.nullish(info && JS.prop(info, "site"), ""))}

        {:error, _} ->
          {"read", ""}
      end

    wanted = if token_site != "", do: token_site, else: JS.prop(input, "site")
    there = Enum.find(sites, &(JS.object?(&1) and &1["id"] == wanted)) || hd(sites)
    # An install's answer is read as given: a site without a list of hostnames has none.
    hostnames = if is_list(there["hostnames"]), do: Enum.filter(there["hostnames"], &is_binary/1), else: []

    # Connecting the same site again (to allow changes, or with a new token) updates it in place.
    existing = Enum.find(remotes(rl), fn {_, known} -> known["url"] == url and known["site"] == there["id"] end)

    case existing do
      {existing, known} ->
        updated =
          known |> Object.put("token", token) |> Object.put("scope", scope) |> Object.put("hostnames", hostnames)

        if known["token"] != token, do: revoke_remote_token(rl, known)
        Store.set_setting(rl.store, "remote:#{existing}", Crypto.seal(JS.stringify(updated), rl.secret))
        State.put(rl.table, :remotes, Map.put(remotes(rl), existing, updated))
        forget_remote_info(rl, existing)
        site(rl, existing)

      nil ->
        host = (List.first(hostnames) || Url.host(Url.new(url))) |> String.replace(~r/[^a-z0-9._-]/i, "-") |> JS.lower()
        stem = JS.slice(host, 0, 56)
        id = free_id(rl, stem)
        name = input |> JS.prop("name") |> JS.nullish("") |> JS.string() |> JS.trim() |> JS.slice(0, 80)
        name = if name == "", do: there["name"], else: name
        timezone = if Time.timezone?(there["timezone"]), do: there["timezone"], else: "UTC"
        # No hostnames: tracker hits never land on a site that is counted elsewhere.
        site = JS.obj(id: id, name: name, hostnames: [], timezone: timezone)
        remote = JS.obj(url: url, token: token, site: there["id"], hostnames: hostnames, scope: scope)
        Store.upsert_site(rl.store, site, now(rl))
        Store.set_setting(rl.store, "remote:#{id}", Crypto.seal(JS.stringify(remote), rl.secret))
        State.put(rl.table, :remotes, Map.put(remotes(rl), id, remote))
        set_configured(rl, by_name(configured(rl) ++ [site]))
        site
    end
  end

  defp free_id(rl, stem) do
    taken = MapSet.new(configured(rl), & &1["id"])

    if MapSet.member?(taken, stem),
      do:
        Enum.find_value(Stream.iterate(2, &(&1 + 1)), fn n ->
          if !MapSet.member?(taken, "#{stem}-#{n}"), do: "#{stem}-#{n}"
        end),
      else: stem
  end

  @doc "Adds a site, when sites are managed in the dashboard: one counted here, or one connected from another install."
  @spec add_site(t(), Object.t()) :: Object.t()
  def add_site(rl, input) do
    init(rl)
    unless rl.managed_sites, do: raise(SettingsError, message: "Sites are set in code", code: "sites_in_code")
    remote_input = JS.prop(input, "remote")

    if JS.truthy?(remote_input) and JS.objectish?(remote_input) do
      add_remote_site(
        rl,
        Object.put(if(is_list(remote_input), do: Object.new(), else: remote_input), "name", JS.prop(input, "name"))
      )
    else
      hostnames = hostnames_for(rl, JS.prop(input, "hostnames"))
      name = input |> JS.prop("name") |> JS.nullish("") |> JS.string() |> JS.trim()
      name = if name == "", do: hd(hostnames), else: name
      if JS.len16(name) > 80, do: raise(SettingsError, message: "A site name is 1 to 80 characters", code: "site_name")
      timezone = input |> JS.prop("timezone") |> JS.nullish("UTC") |> JS.string()

      unless Time.timezone?(timezone),
        do:
          raise(SettingsError,
            message: ~s(Unknown timezone "#{timezone}"),
            code: "unknown_timezone",
            params: %{"timezone" => timezone}
          )

      stem = hostnames |> hd() |> String.replace(~r/[^a-z0-9._-]/, "-") |> JS.slice(0, 56)
      id = free_id(rl, stem)
      site = JS.obj(id: id, name: name, hostnames: hostnames, timezone: timezone)
      Store.upsert_site(rl.store, site, now(rl))
      set_configured(rl, by_name(configured(rl) ++ [site]))
      site
    end
  end

  @doc "Deletes a site and everything recorded for it, when sites are managed in the dashboard."
  @spec delete_site(t(), String.t()) :: :ok
  def delete_site(rl, id) do
    init(rl)
    unless rl.managed_sites, do: raise(SettingsError, message: "Sites are set in code", code: "sites_in_code")

    unless Enum.any?(configured(rl), &(&1["id"] == id)),
      do: raise(SettingsError, message: "Unknown site", code: "unknown_site")

    Store.delete_site(rl.store, id)

    for key <- ["retention:#{id}", "observe-key:#{id}", "rollup-zone:#{id}", "orphans-swept:#{id}"],
        do: Store.set_setting(rl.store, key, nil)

    # A site made again with the same id starts its Umami import from the beginning.
    for %{key: key} <- Store.settings_starting_with(rl.store, "import:umami-visits:#{id}:"),
        do: Store.set_setting(rl.store, key, nil)

    # A connected install keeps its own data; only the connection goes, and its token there with it.
    case remote(rl, id) do
      nil ->
        :ok

      remote ->
        revoke_remote_token(rl, remote)
        State.put(rl.table, :remotes, Map.delete(remotes(rl), id))
        Store.set_setting(rl.store, "remote:#{id}", nil)
    end

    set_configured(rl, Enum.reject(configured(rl), &(&1["id"] == id)))
    State.put(rl.table, :overrides, Map.delete(overrides(rl), id))
    :ok
  end

  @doc """
  Changes a site's name or timezone from the dashboard, kept apart from the
  settings in code. A managed site has no settings in code, so its changes,
  hostnames too, go to its row.
  """
  @spec update_site(t(), String.t(), Object.t() | map()) :: Object.t()
  def update_site(rl, id, patch) do
    init(rl)
    current = Enum.find(configured(rl), &(&1["id"] == id))
    if current == nil, do: raise(SettingsError, message: "Unknown site", code: "unknown_site")
    patch = Object.new(patch)

    check_name = fn ->
      name = patch["name"] |> JS.string() |> JS.trim()

      if name == "" or JS.len16(name) > 80,
        do: raise(SettingsError, message: "A site name is 1 to 80 characters", code: "site_name")

      name
    end

    check_zone = fn ->
      zone = JS.string(patch["timezone"])

      unless Time.timezone?(zone),
        do:
          raise(SettingsError,
            message: ~s(Unknown timezone "#{zone}"),
            code: "unknown_timezone",
            params: %{"timezone" => zone}
          )

      zone
    end

    if rl.managed_sites do
      next = current
      next = if Object.has_key?(patch, "name"), do: Object.put(next, "name", check_name.()), else: next

      next =
        if Object.has_key?(patch, "timezone") do
          zone = check_zone.()
          if zone != (site(rl, id) || %{})["timezone"], do: zone_changed(rl, id, zone)
          Object.put(next, "timezone", zone)
        else
          next
        end

      next =
        if Object.has_key?(patch, "hostnames") and remote(rl, id) == nil,
          do: Object.put(next, "hostnames", hostnames_for(rl, patch["hostnames"], id)),
          else: next

      Store.upsert_site(rl.store, next, now(rl))
      set_configured(rl, Enum.map(configured(rl), &if(&1["id"] == id, do: next, else: &1)))
      site(rl, id)
    else
      next = Map.get(overrides(rl), id, Object.new())
      next = if Object.has_key?(patch, "name"), do: Object.put(next, "name", check_name.()), else: next

      next =
        if Object.has_key?(patch, "timezone") do
          zone = check_zone.()
          if zone != site(rl, id)["timezone"], do: zone_changed(rl, id, zone)
          Object.put(next, "timezone", zone)
        else
          next
        end

      Store.set_site_overrides(rl.store, id, next)
      State.put(rl.table, :overrides, Map.put(overrides(rl), id, next))
      site(rl, id)
    end
  end

  @doc "How many months of visits a site keeps, or nil to keep everything (the default)."
  @spec retention(t(), String.t()) :: integer() | nil
  def retention(rl, site) do
    value = JS.number(Store.setting(rl.store, "retention:#{site}"))
    if value in retention_months(), do: value
  end

  @doc "Sets how long a site keeps its visits, in months, or nil for ever; a shorter time deletes visits after the answer."
  @spec set_retention(t(), String.t(), integer() | nil) :: :ok
  def set_retention(rl, site, months) do
    if site(rl, site) == nil or remote(rl, site) != nil,
      do: raise(SettingsError, message: "Unknown site", code: "unknown_site")

    choices = Enum.join(retention_months(), ", ")

    if months != nil and months not in retention_months(),
      do:
        raise(SettingsError,
          message: "Keep visits for #{choices} months, or forever",
          code: "retention_bad",
          params: %{"months" => choices}
        )

    Store.set_setting(rl.store, "retention:#{site}", if(months == nil, do: nil, else: JS.string(months)))
    # Deleting a long history takes a while, so it runs in pieces after the answer.
    State.later(rl.table, fn -> safely_apply_retention(rl, site) end)
  end

  defp safely_apply_retention(rl, only) do
    apply_retention(rl, only)
  rescue
    error -> Logger.error("Runlight: could not apply retention #{Exception.message(error)}")
  end

  @doc "Retention work still running; the scheduled check and tests wait for it."
  @spec idle(t()) :: :ok
  def idle(rl), do: State.idle(rl.table)

  # Days are the site's local days, so a new timezone clears the built ones.
  defp zone_changed(rl, id, timezone) do
    since = now(rl)
    Store.clear_rollups(rl.store, id)
    Store.set_setting(rl.store, "rollup-zone:#{id}", JS.stringify(JS.obj(zone: timezone, since: since)))
    since
  end

  # Since when a site's days may be built: 0 for always, or when its timezone last changed. Nil when this
  # process holds a different timezone than the one on record.
  defp rollup_since(rl, site) do
    case Store.setting(rl.store, "rollup-zone:#{site["id"]}") do
      nil ->
        Store.set_setting(rl.store, "rollup-zone:#{site["id"]}", JS.stringify(JS.obj(zone: site["timezone"], since: 0)))
        0

      stored ->
        zone = JS.parse!(stored)
        if zone["zone"] == site["timezone"], do: zone["since"]
    end
  end

  @doc """
  Adds up each site's finished days, so long ranges read a row a day instead
  of every visit. A day is built two hours after it ends in the site's
  timezone, and at most ten days a run.
  """
  @spec build_rollups(t()) :: non_neg_integer()
  def build_rollups(rl) do
    # Days rolled up by an earlier way of counting are cleared once, and built again below.
    if Store.setting(rl.store, "rollup-version") != Integer.to_string(@rollup_version) do
      for site <- sites(rl), do: Store.clear_rollups(rl.store, site["id"])
      Store.set_setting(rl.store, "rollup-version", Integer.to_string(@rollup_version))
    end

    now = now(rl)
    batch = if rl.store.db.metered, do: @metered_rollup_batch, else: @rollup_batch

    Enum.reduce(sites(rl), 0, fn site, built ->
      first = if remote(rl, site["id"]), do: nil, else: Store.first_seen(rl.store, site["id"])

      with false <- remote(rl, site["id"]) != nil,
           first when first != nil <- first,
           cutoff = retention_cutoff(rl, site["id"]) || 0,
           since when since != nil <- rollup_since(rl, site) do
        done = Store.rollup_days(rl.store, site["id"])
        tz = site["timezone"]
        today = Time.local_date(now, tz)
        oldest = Time.local_date(max(first, cutoff), tz)
        built + build_days(rl, site, Time.add_days(today, -1), oldest, done, since, cutoff, now, batch, 0)
      else
        _ -> built
      end
    end)
  end

  # Newest first, so recent ranges speed up before a long history is done.
  defp build_days(rl, site, day, oldest, done, since, cutoff, now, batch, made) do
    if day < oldest or made >= batch do
      made
    else
      tz = site["timezone"]
      start = Time.start_of(day, tz)
      finish = Time.start_of(Time.add_days(day, 1), tz)

      cond do
        MapSet.member?(done, day) ->
          build_days(rl, site, Time.add_days(day, -1), oldest, done, since, cutoff, now, batch, made)

        start < since ->
          made

        now < finish + @rollup_delay_ms or start < cutoff ->
          build_days(rl, site, Time.add_days(day, -1), oldest, done, since, cutoff, now, batch, made)

        true ->
          made =
            try do
              Store.build_rollup_day(rl.store, site["id"], day, start, finish)
              made + 1
            rescue
              error ->
                # Another process building the same day at once loses nothing: the day is there either way.
                unless MapSet.member?(Store.rollup_days(rl.store, site["id"]), day),
                  do: Logger.error("Runlight: could not add up #{day} for #{site["id"]}: #{Exception.message(error)}")

                made
            end

          build_days(rl, site, Time.add_days(day, -1), oldest, done, since, cutoff, now, batch, made)
      end
    end
  end

  ## The assistant

  @doc "The dashboard assistant's provider, model, and key, kept sealed like the mail keys. Nil until an owner sets it up."
  @spec assistant_settings(t()) :: Object.t() | nil
  def assistant_settings(rl) do
    with stored when is_binary(stored) <- Store.setting(rl.store, "assistant"),
         opened when is_binary(opened) <- Crypto.unseal(stored, rl.secret),
         {:ok, %Object{} = settings} <- JS.parse(opened) do
      settings
    else
      _ -> nil
    end
  end

  @doc "Saves the assistant's settings; an empty key keeps the one saved for the same provider. Nil removes them."
  @spec save_assistant_settings(t(), Object.t() | nil) :: :ok
  def save_assistant_settings(rl, nil), do: Store.set_setting(rl.store, "assistant", nil)

  def save_assistant_settings(rl, input) do
    provider = Enum.find(Runlight.Assistant.providers(), &(&1["id"] == JS.prop(input, "provider")))
    if provider == nil, do: raise(SettingsError, message: "Choose a provider", code: "assistant_provider")

    base_url =
      input |> JS.prop("baseUrl") |> JS.nullish("") |> JS.string() |> JS.trim() |> String.replace(~r/\/+\z/, "")

    if base_url != "" do
      parsed = Url.parse(base_url)

      if parsed == nil or parsed.protocol not in ["https:", "http:"],
        do:
          raise(SettingsError,
            message: "Enter the service's address, starting with https://",
            code: "assistant_address_bad"
          )
    end

    if base_url == "" and provider["baseUrl"] == "",
      do: raise(SettingsError, message: "Enter the service's address", code: "assistant_address")

    model = input |> JS.prop("model") |> JS.nullish("") |> JS.string() |> JS.trim() |> JS.slice(0, 200)

    if model == "" and provider["model"] == "",
      do: raise(SettingsError, message: "Enter the model to use", code: "assistant_model")

    before = assistant_settings(rl)
    key = input |> JS.prop("key") |> JS.nullish("") |> JS.string() |> JS.trim()

    # A saved key is kept only for the same service at the same address, so it is never sent somewhere new.
    key =
      if key == "" and before != nil and before["provider"] == provider["id"] and
           JS.or_else(before["baseUrl"], provider["baseUrl"]) == JS.or_else(base_url, provider["baseUrl"]),
         do: before["key"],
         else: key

    if key == "" and provider["key"] == "yes",
      do:
        raise(SettingsError,
          message: "Enter your #{provider["name"]} key",
          code: "assistant_key",
          params: %{"provider" => provider["name"]}
        )

    settings = JS.obj(provider: provider["id"], model: model, baseUrl: base_url, key: key)
    Store.set_setting(rl.store, "assistant", Crypto.seal(JS.stringify(settings), rl.secret))
  end

  @doc "The oldest moment a site keeps visits from, or nil when it keeps everything."
  @spec retention_cutoff(t(), String.t()) :: integer() | nil
  def retention_cutoff(rl, site) do
    case retention(rl, site) do
      nil ->
        nil

      months ->
        now = now(rl)
        days = Integer.floor_div(now, 86_400_000)
        rest = now - days * 86_400_000
        {y, m, d} = JS.civil_from_days(days)
        # setUTCMonth keeps the day of the month, overflowing into the next month as Date does.
        JS.date_utc(y, m - 1 - months, d) + rest
    end
  end

  # Deletes visits older than each site's retention allows. Cheap when there is nothing to delete.
  defp apply_retention(rl, only) do
    for site <- sites(rl), only == nil or site["id"] == only, remote(rl, site["id"]) == nil do
      case retention_cutoff(rl, site["id"]) do
        nil ->
          :ok

        cutoff ->
          Store.drop_before(rl.store, site["id"], cutoff)

          # Earlier versions let an event join its visit days late, so retention could leave such an event behind
          # once its visit was gone. They are swept once.
          unless Store.setting(rl.store, "orphans-swept:#{site["id"]}") do
            Store.drop_orphans(rl.store, site["id"], cutoff, now(rl))
            Store.set_setting(rl.store, "orphans-swept:#{site["id"]}", "1")
          end
      end
    end

    :ok
  end

  @doc "The site with an id, or the first site when the id is nil or empty."
  @spec site(t(), String.t() | nil) :: Object.t() | nil
  def site(rl, id) when id in [nil, ""], do: List.first(sites(rl))
  def site(rl, id), do: Enum.find(sites(rl), &(&1["id"] == id))

  @doc "The site a page belongs to, or nil if it belongs to none."
  @spec site_for(t(), String.t(), String.t() | nil) :: Object.t() | nil
  def site_for(rl, hostname, id \\ nil) do
    host = Sources.strip_www(hostname)
    remotes = remotes(rl)
    id = if id == "", do: nil, else: id

    # A site counted by another install never takes hits here.
    if map_size(remotes) > 0 do
      local = Enum.reject(sites(rl), &Map.has_key?(remotes, &1["id"]))

      cond do
        id && Map.has_key?(remotes, id) -> nil
        true -> site_for_among(local, host, id)
      end
    else
      site_for_among(sites(rl), host, id)
    end
  end

  defp site_for_among(sites, host, id) do
    cond do
      id ->
        site = Enum.find(sites, &(&1["id"] == id))
        if site && (site["hostnames"] == [] or host in site["hostnames"]), do: site

      length(sites) == 1 ->
        [only] = sites
        if only["hostnames"] == [] or host in only["hostnames"], do: only

      true ->
        Enum.find(sites, &(host in &1["hostnames"]))
    end
  end

  # A test from a developer's own machine while a site is being set up: a site with no visits yet accepts hits
  # from localhost and .local or .test names; after its first visit they are ignored again.
  defp setup_site(rl, hostname, id) do
    host = hostname |> JS.lower() |> String.replace(~r/^\[|\]$/, "")

    if host in ["localhost", "127.0.0.1", "::1"] or Regex.match?(~r/\.(localhost|local|test)\z/, host) do
      sites = sites(rl)
      id = if id == "", do: nil, else: id
      site = if id, do: site(rl, id), else: if(length(sites) == 1, do: hd(sites))
      if site && remote(rl, site["id"]) == nil && Store.last_seen(rl.store, site["id"]) == nil, do: site
    end
  end

  @doc """
  The visitor's address, for the daily visitor hash and the rate limit.
  Behind a proxy it comes from a header: by default the last X-Forwarded-For
  entry, which the nearest proxy wrote, then X-Real-IP and CF-Connecting-IP.
  """
  @spec client_ip(t(), Request.t()) :: String.t()
  def client_ip(rl, %Request{} = request) do
    forwarded =
      if rl.trust_proxy do
        h = request.headers

        last = fn name ->
          case Headers.get(h, name) do
            nil -> nil
            value -> value |> String.split(",") |> Enum.map(&JS.trim/1) |> Enum.reject(&(&1 == "")) |> List.last()
          end
        end

        case rl.trust_proxy do
          true -> last.("x-forwarded-for") || Headers.get(h, "x-real-ip") || Headers.get(h, "cf-connecting-ip")
          "x-forwarded-for" -> last.("x-forwarded-for")
          name -> Headers.get(h, name)
        end
      end

    if forwarded && JS.trim(forwarded) != "" do
      JS.trim(forwarded)
    else
      # A public address with no forwarding header means nothing sits in front, and then any client
      # could name its own address in one. Said once, only when trust_proxy was left at its default.
      if rl.warn_direct && request.remote_address && Safefetch.public_address?(request.remote_address) &&
           :ets.insert_new(rl.table, {:warned_direct, true}) do
        Logger.warning(
          "Runlight: a request came straight from a public address with no proxy in front, but trustProxy is on by default, so a client could send X-Forwarded-For and choose its own address, getting round the rate limits. Set trust_proxy: false when nothing sits in front of this server, or put a proxy in front that sets the header."
        )
      end

      request.remote_address || ""
    end
  end

  # Today's salt in a site's timezone and, if it still exists, yesterday's. Old salts go on the way.
  defp current_salts(rl, now, timezone) do
    day = Time.local_date(now, timezone)

    case State.get(rl.table, {:salts, timezone}) do
      %{day: ^day} = cached ->
        cached

      _ ->
        today = Store.salt(rl.store, day, Hash.random_salt())
        yesterday = Store.salt_if_exists(rl.store, Time.add_days(day, -1))
        drop_old_salts(rl, now)
        State.put(rl.table, {:salts, timezone}, %{day: day, today: today, yesterday: yesterday})
    end
  end

  # Deletes salts whose day has ended everywhere: a salt goes two UTC days after its date.
  defp drop_old_salts(rl, now), do: Store.drop_salts_before(rl.store, JS.iso_day(now - 2 * 86_400_000))

  # The host a proxy says the request was for, read only when proxy headers are trusted.
  defp forwarded_host(rl, request), do: if(rl.trust_proxy, do: Request.header(request, "x-forwarded-host"))

  @doc "Handles one tracker request. Always succeeds; bad input is dropped quietly."
  @spec collect(t(), Request.t()) :: :ok
  def collect(rl, %Request{} = request) do
    length = JS.number(Request.header(request, "content-length") || 0)

    with false <- is_number(length) and length > Payload.max_body(),
         # Read no more than a tracker hit can be, whatever the length header says.
         true <- byte_size(request.body) <= Payload.max_body(),
         %{} = payload <- Payload.parse(Request.text(request)),
         ua = Request.header(request, "user-agent") || "",
         false <- Ua.ai_agent(ua) != nil or Ua.bot?(ua),
         true <- rl.limit == nil or RateLimit.allow?(rl.limit, client_ip(rl, request), now(rl)) do
      now = now(rl)
      record_with_retries(rl, payload, request, now, 1)
    else
      _ -> :ok
    end
  end

  # A database too busy to take the hit right now gets it a little later, at the time it arrived.
  defp record_with_retries(rl, payload, request, now, attempt) do
    record(rl, payload, request, now)
  rescue
    error ->
      if attempt >= 3 or not busy?(error) do
        reraise error, __STACKTRACE__
      else
        Process.sleep(500 * attempt)
        record_with_retries(rl, payload, request, now, attempt + 1)
      end
  end

  defp busy?(error) do
    Regex.match?(
      ~r/timeout exceeded when trying to connect|connection timeout|no MySQL connection was free|SQLITE_BUSY|database is locked/i,
      Exception.message(error)
    )
  end

  defp record(rl, payload, request, now) do
    # Managed sites load from the database in init(), so it must come first.
    init(rl)
    hostname = payload.url.hostname
    site = site_for(rl, hostname, payload.site) || setup_site(rl, hostname, payload.site)

    cond do
      site == nil ->
        :ok

      payload.kind == "engagement" ->
        engagement(rl, site, payload, now)

      true ->
        page = Sources.parse_page(payload.url)

        {session, reopen} =
          if payload.kind == "event" and payload.pageview_id != "" do
            pageview = Store.pageview(rl.store, site["id"], payload.pageview_id)

            # An event joins its page's visit unless that visit began longer ago than reports look for its rows.
            if pageview && now - pageview.started_at < Runlight.Store.Sql.event_tail_ms() do
              if now - pageview.started_at > 3_600_000,
                do:
                  Store.touched_old_visit(rl.store, site["id"], pageview.started_at, now - @rollup_delay_ms + 3_600_000)

              # A visit idle past the 30 minutes stays ended: the event counts in it without reopening it.
              {%{id: pageview.session, visitor: pageview.visitor}, now - pageview.last_at <= session_idle_ms()}
            else
              {nil, true}
            end
          else
            {nil, true}
          end

        session =
          session ||
            session_for(rl, site, request, page, payload.referrer, now, %{
              screen_width: payload.screen_width,
              screen:
                if(JS.truthy?(payload.screen_width) and JS.truthy?(payload.screen_height),
                  do: "#{payload.screen_width}x#{payload.screen_height}",
                  else: ""
                ),
              language: payload.language
            })

        Store.touch_session(rl.store, session.id, now, payload.kind, page.path, reopen)

        Store.insert_event(rl.store, %{
          site: site["id"],
          ts: now,
          kind: payload.kind,
          visitor: session.visitor,
          session: session.id,
          pageview: payload.pageview_id,
          path: page.path,
          hostname: page.hostname,
          title: if(payload.kind == "pageview", do: payload.title, else: ""),
          name: if(payload.kind == "event", do: payload.name, else: ""),
          props: payload.props,
          engaged_ms: 0,
          scroll: nil,
          link: ""
        })
    end
  end

  # The visitor's open session on a site, or a new one attributed to this request.
  defp session_for(rl, site, request, page, referrer, now, client) do
    ua = Request.header(request, "user-agent") || ""
    ip = client_ip(rl, request)
    salts = current_salts(rl, now, site["timezone"])
    today = Hash.visitor_hash(salts.today, site["id"], ip, ua)
    candidates = if salts.yesterday, do: [today, Hash.visitor_hash(salts.yesterday, site["id"], ip, ua)], else: [today]

    # One visitor's requests often arrive together. Taking turns per visitor means only the first opens a
    # session and the rest find it, instead of each opening its own.
    State.one_at_a_time(rl.table, {:visitor, site["id"], today}, fn ->
      case Store.open_session(rl.store, site["id"], candidates, now - session_idle_ms()) do
        %{} = open ->
          open

        nil ->
          session = %{id: Hash.random_id(), visitor: today}
          attribution = Sources.attribute(page, referrer, site["hostnames"])

          parsed =
            Ua.parse_client(
              ua,
              %{
                brands: Request.header(request, "sec-ch-ua"),
                mobile: Request.header(request, "sec-ch-ua-mobile"),
                platform: Request.header(request, "sec-ch-ua-platform")
              },
              client[:screen_width]
            )

          location = Runlight.Geo.locate(request.headers, ip, rl.geo)

          Store.insert_session(rl.store, %{
            id: session.id,
            site: site["id"],
            visitor: session.visitor,
            started_at: now,
            hostname: page.hostname,
            referrer_host: attribution.referrer_host,
            referrer_path: attribution.referrer_path,
            source: attribution.source,
            channel: attribution.channel,
            utm_source: page.utm.source,
            utm_medium: page.utm.medium,
            utm_campaign: page.utm.campaign,
            utm_term: page.utm.term,
            utm_content: page.utm.content,
            country: location.country,
            region: location.region,
            city: location.city,
            browser: parsed.browser,
            browser_version: parsed.browser_version,
            os: parsed.os,
            os_version: parsed.os_version,
            device: parsed.device,
            screen: client.screen,
            language: client.language
          })

          session
      end
    end)
  end

  @doc "The link domains, read at most every 30 seconds."
  @spec link_domain_set(t()) :: MapSet.t()
  def link_domain_set(rl) do
    now = now(rl)

    case State.get(rl.table, :link_domains) do
      %{at: at, domains: domains} when now - at < 30_000 ->
        domains

      _ ->
        init(rl)
        domains = rl.store |> Store.link_domains() |> MapSet.new(&JS.string(&1["domain"]))
        State.put(rl.table, :link_domains, %{at: now, domains: domains})
        domains
    end
  end

  @doc "Clears the cached link domains after one is added or removed."
  def forget_link_domains(rl), do: State.delete(rl.table, :link_domains)

  @doc false
  def add_route_base(rl, base), do: State.put(rl.table, {:route_base, base}, true)

  defp route_bases(rl) do
    case State.entries(rl.table, :route_base) do
      [] -> ["/runlight"]
      entries -> entries |> Enum.map(fn {{:route_base, base}, _} -> base end) |> Enum.sort()
    end
  end

  @doc """
  Handles `{link_path}/{slug}` on the app's own domain: a redirect to the
  link's destination, with the click recorded, or a 404.
  """
  @spec link_handler(t(), Request.t()) :: Response.t()
  def link_handler(rl, %Request{} = request) do
    path = Url.new(request.url).pathname
    prefix = rl.link_path <> "/"

    slug =
      if String.starts_with?(path, prefix),
        do: JS.decode_uri_component(binary_part(path, byte_size(prefix), byte_size(path) - byte_size(prefix))),
        else: ""

    if slug == nil, do: raise(uri_error())

    found = if slug != "" and not String.contains?(slug, "/"), do: redirect(rl, request, slug, "")
    found || not_found()
  end

  defp not_found, do: Response.new("Not found", 404, [{"content-type", "text/plain; charset=utf-8"}])

  # decodeURIComponent throws a URIError for a malformed escape, which the routes answer as an internal error.
  defp uri_error, do: %RuntimeError{message: "URI malformed"}

  @doc """
  For middleware: when a request arrives on a link domain added in Settings,
  answers `/{slug}` there with the redirect, and anything else with a 404.
  Nil for every other host, so the app carries on as normal, and for the
  dashboard's own paths.
  """
  @spec link_domain_response(t(), Request.t()) :: Response.t() | nil
  def link_domain_response(rl, %Request{} = request) do
    url = Url.new(request.url)
    # A forwarded host only counts behind a proxy that sets it; otherwise any client could pick one.
    given = forwarded_host(rl, request) || Request.header(request, "host") || Url.host(url)
    host = given |> String.split(",") |> hd() |> JS.trim() |> String.split(":") |> hd() |> Sources.strip_www()

    cond do
      not MapSet.member?(link_domain_set(rl), host) ->
        nil

      # Lets the dashboard confirm that requests to this domain reach Runlight.
      url.pathname == link_domain_check() ->
        Response.new(JS.stringify(JS.obj(runlight: true, domain: host)), 200, [
          {"content-type", "application/json"},
          {"cache-control", "no-store"}
        ])

      Enum.any?(route_bases(rl), fn base ->
        base != "/" and (url.pathname == base or String.starts_with?(url.pathname, base <> "/"))
      end) ->
        nil

      true ->
        slug = JS.decode_uri_component(JS.slice(url.pathname, 1))
        if slug == nil, do: raise(uri_error())
        found = if slug != "" and not String.contains?(slug, "/"), do: redirect(rl, request, slug, host)
        found || not_found()
    end
  end

  @doc """
  Answers a request for a short link: a redirect to its destination, with the
  click recorded like a visit but kept out of visitor and pageview counts.
  `domain` is the link domain the request came in on, or "" for the app's
  own link path, which answers for every link. Nil when no link fits.
  """
  @spec redirect(t(), Request.t(), String.t(), String.t()) :: Response.t() | nil
  def redirect(rl, %Request{} = request, slug, domain) do
    init(rl)
    url = Url.new(request.url)

    host =
      (forwarded_host(rl, request) || Request.header(request, "host") || Url.host(url))
      |> String.split(":")
      |> hd()
      |> Sources.strip_www()

    link = Store.link_by_slug(rl.store, slug)

    # The app's own link path answers for every link, so a link whose domain was removed keeps working; a link
    # domain answers only for its own links.
    if link == nil or (domain != "" and link["domain"] != domain) do
      nil
    else
      site = site(rl, link["site"]) || List.first(sites(rl))
      ua = Request.header(request, "user-agent") || ""

      if site && Ua.ai_agent(ua) == nil && not Ua.bot?(ua) && request.method == "GET" do
        try do
          now = now(rl)

          language =
            (Request.header(request, "accept-language") || "")
            |> String.split(",")
            |> hd()
            |> String.split(";")
            |> hd()
            |> JS.trim()
            |> JS.slice(0, 35)

          session =
            session_for(rl, site, request, Sources.parse_page(url), Request.header(request, "referer") || "", now, %{
              screen: "",
              language: language
            })

          Store.touch_session(rl.store, session.id, now, "click", url.pathname)

          Store.insert_event(rl.store, %{
            site: site["id"],
            ts: now,
            kind: "click",
            visitor: session.visitor,
            session: session.id,
            pageview: "",
            path: JS.slice(url.pathname, 0, 1000),
            hostname: host,
            title: "",
            name: link["slug"],
            props: nil,
            engaged_ms: 0,
            scroll: nil,
            link: link["id"]
          })
        rescue
          # A failed count must never break the redirect.
          error -> Logger.error("Runlight: could not record a link click #{Exception.message(error)}")
        end
      end

      Response.new(nil, 302, [
        {"location", link["url"]},
        {"cache-control", "no-store"},
        {"referrer-policy", "no-referrer-when-downgrade"}
      ])
    end
  end

  defp engagement(rl, site, payload, now) do
    pageview = if payload.engaged_ms > 0, do: Store.pageview(rl.store, site["id"], payload.pageview_id)

    # Reports look for a visit's rows only so long after it began, so later time on it is let go.
    if pageview && now - pageview.started_at < Runlight.Store.Sql.event_tail_ms() do
      Store.add_engagement(rl.store, pageview.session, payload.engaged_ms)

      # Only a visit that began more than an hour ago can belong to a day that is already added up.
      if now - pageview.started_at > 3_600_000,
        do: Store.touched_old_visit(rl.store, site["id"], pageview.started_at, now - @rollup_delay_ms + 3_600_000)

      Store.insert_event(rl.store, %{
        site: site["id"],
        ts: now,
        kind: "engagement",
        visitor: pageview.visitor,
        session: pageview.session,
        pageview: payload.pageview_id,
        path: pageview.path,
        hostname: pageview.hostname,
        title: "",
        name: "",
        props: nil,
        engaged_ms: payload.engaged_ms,
        scroll: payload.scroll,
        link: ""
      })
    end

    :ok
  end

  @doc """
  Records a request from a known AI agent. Call it from middleware for every
  page request (see `Runlight.Plug.Observer`); it ignores everything else and
  never raises. `at` is when the page was served, for a log reader.
  """
  @spec observe(t(), Request.t(), number() | nil) :: boolean()
  def observe(rl, %Request{} = request, at \\ nil) do
    with "GET" <- request.method,
         agent when agent != nil <- Ua.ai_agent(Request.header(request, "user-agent") || ""),
         url = Url.new(request.url),
         ext = (Regex.run(~r/\.([a-z0-9]+)$/i, url.pathname) || [nil, nil]) |> Enum.at(1),
         true <- ext == nil or JS.lower(ext) in ["html", "htm", "md", "txt", "php"],
         host = forwarded_host(rl, request) || Request.header(request, "host") || url.hostname,
         :ok <- init(rl),
         site when site != nil <- site_for(rl, host |> String.split(":") |> hd()),
         now = now(rl),
         # A log reader sends when the page was served. Older than a week is dropped; a time ahead counts as now.
         false <- at != nil and JS.finite?(at) and at < now - 7 * 86_400_000 do
      ts = if at != nil and JS.finite?(at) and at <= now, do: JS.floor(at), else: now

      Store.insert_event(rl.store, %{
        site: site["id"],
        ts: ts,
        kind: "fetch",
        visitor: "",
        session: "",
        pageview: "",
        path: JS.slice(url.pathname, 0, 1000),
        hostname: Sources.strip_www(url.hostname),
        title: "",
        name: agent.name,
        props: JS.obj(company: agent.company, kind: agent.kind),
        engaged_ms: 0,
        scroll: nil,
        link: ""
      })

      true
    else
      _ -> false
    end
  rescue
    # Analytics must never break the page it watches, but a failure should still be seen.
    error ->
      Logger.error("Runlight: could not record an AI agent fetch #{Exception.message(error)}")
      false
  end

  @doc """
  Scheduled upkeep, safe to run every minute. It rotates salts, sends the
  email reports that are due, deletes visits past each site's retention, and
  builds daily rollups. It also rereads sites, their dashboard settings, and
  connected installs, so a change made by another process shows up here too.
  """
  @spec check(t()) :: Object.t()
  def check(rl) do
    # A check still running when the next is due is waited for, never run twice at once.
    State.one_at_a_time(rl.table, :check, fn -> run_check(rl) end)
  end

  defp run_check(rl) do
    init(rl)

    if rl.managed_sites do
      set_configured(rl, Store.sites(rl.store))
      load_remotes(rl)
    end

    # A name or timezone changed in the dashboard by another process reaches this one too.
    State.put(rl.table, :overrides, Store.site_overrides(rl.store))
    State.delete_all(rl.table, :salts)
    now = now(rl)
    for timezone <- sites(rl) |> Enum.map(& &1["timezone"]) |> Enum.uniq(), do: current_salts(rl, now, timezone)
    drop_old_salts(rl, now(rl))
    State.later(rl.table, fn -> safely_apply_retention(rl, nil) end)
    idle(rl)

    if now(rl) - State.get(rl.table, :optimized_at, 0) >= 86_400_000 do
      State.put(rl.table, :optimized_at, now(rl))
      Store.optimize(rl.store)
    end

    build_rollups(rl)
    reports = send_reports(rl)
    JS.obj(ok: true, reports: JS.obj(sent: reports.sent, failed: reports.failed))
  end
end
