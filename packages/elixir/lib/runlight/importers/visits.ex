defmodule Runlight.Importers.Visits do
  @moduledoc """
  Visit history from Umami or a CSV file: pageviews and custom events with
  where each visit came from, its place, and its device, written as imported
  visits so the dashboard's history does not start the day Runlight was
  installed (the SDK's importers/visits.ts and csvvisits.ts).

  The dashboard drives an Umami import a few days at a time, oldest first. It
  stops where Runlight's own visits begin, so nothing is counted twice, and
  it remembers how far it got, so running it again carries on from there.
  """

  import Runlight.Importers.Http, only: [get: 2]

  alias Runlight.ImportError
  alias Runlight.Importers
  alias Runlight.Importers.Http
  alias Runlight.Importers.Shorteners
  alias Runlight.JS
  alias Runlight.JS.Object
  alias Runlight.Sources
  alias Runlight.Store
  alias Runlight.Store.Sql
  alias Runlight.Time
  alias Runlight.Url

  @day 86_400_000
  # Each step reads at most this many days, or stops after this many events.
  @step_days 14
  @step_events 5_000
  # A single day with more than this is refused rather than read without end.
  @max_day_events 200_000
  @pageview 1
  @custom_event 2

  @doc "At most this many rows in one CSV request."
  def csv_batch, do: 2000

  defp progress_key(site, website), do: "import:umami-visits:#{site}:#{website}"

  @doc "The websites an Umami account can see, to pick which one becomes this site's history."
  @spec umami_websites(Runlight.t(), map()) :: [Object.t()]
  def umami_websites(rl, credentials), do: websites(Http.new(rl), credentials)

  @doc false
  def websites(http, credentials) do
    {base, token} = Shorteners.umami_sign_in(http, credentials)
    headers = [{"authorization", "Bearer #{JS.string(token)}"}]

    Enum.reduce_while(1..99, [], fn page, out ->
      body = Http.get_json(http, "#{base}/api/websites?page=#{page}&pageSize=100", headers: headers)
      out = out ++ Enum.map(body["data"], &JS.obj(id: &1["id"], name: &1["name"], domain: &1["domain"]))
      if length(out) >= body["count"] or body["data"] == [], do: {:halt, out}, else: {:cont, out}
    end)
  end

  # Every page of an Umami list for a time window.
  defp all(http, base, path, headers, limit, page \\ 1, out \\ []) do
    body = Http.get_json(http, "#{base}/api#{path}&page=#{page}&pageSize=1000", headers: headers)
    out = out ++ body["data"]

    cond do
      length(out) >= body["count"] or body["data"] == [] ->
        out

      length(out) > limit ->
        raise ImportError,
          message: "One day has more than #{format_en(limit)} events, more than an import step can read",
          code: "import_day_full",
          params: %{"limit" => Integer.to_string(limit)}

      true ->
        all(http, base, path, headers, limit, page + 1, out)
    end
  end

  # `toLocaleString("en")` of a whole number: digits in threes with commas.
  defp format_en(n) do
    n |> Integer.to_string() |> String.reverse() |> String.replace(~r/(\d{3})(?=\d)/, "\\1,") |> String.reverse()
  end

  @doc "One step: read the next few days from Umami and write them as imported visits."
  @spec import_umami_visits(Runlight.t(), String.t(), map(), String.t(), String.t() | nil) :: Object.t()
  def import_umami_visits(rl, site_id, credentials, website, cursor) do
    Runlight.init(rl)
    if Runlight.site(rl, site_id) == nil, do: raise(ImportError, message: "Unknown site", code: "unknown_site")

    unless is_binary(website) and Regex.match?(~r/\A[A-Za-z0-9-]{1,64}\z/, website),
      do: raise(ImportError, message: "Pick the Umami website to import", code: "import_website")

    http = Http.new(rl)
    saved = if cursor, do: JS.parse!(cursor)
    {base, token} = Shorteners.umami_sign_in(http, credentials, saved && JS.nullish(get(saved, "token"), nil))
    headers = [{"authorization", "Bearer #{JS.string(token)}"}]

    state =
      if saved && saved["website"] == website do
        saved
      else
        info = Http.get_json(http, "#{base}/api/websites/#{website}", headers: headers)
        created = Http.date_or(get(info, "createdAt"), Runlight.now(rl))
        # Carry on where an earlier run stopped, and end where Runlight's own visits begin.
        resumed = JS.number(JS.nullish(Store.setting(rl.store, progress_key(site_id, website)), 0))
        resumed = if JS.finite?(resumed), do: resumed, else: 0
        # Never older than the site keeps, or the next scheduled check would delete it again.
        cutoff = Runlight.retention_cutoff(rl, site_id) || 0
        start = Enum.max([JS.floor(created / @day) * @day, resumed, JS.ceil(cutoff / @day) * @day])
        own = Store.first_own_visit(rl.store, site_id)
        JS.obj(website: website, day: start, start: start, end: own || Runlight.now(rl))
      end

    uses_key = credentials |> Map.get("apiKey", "") |> JS.nullish("") |> JS.trim() != ""

    # Read whole days until the step has enough.
    from = state["day"]

    {events, to} =
      Stream.iterate(0, &(&1 + 1))
      |> Enum.reduce_while({[], from}, fn _, {events, to} ->
        if to < state["end"] and to - from < @step_days * @day and length(events) < @step_events do
          next = min(to + @day, state["end"])

          read =
            all(
              http,
              base,
              "/websites/#{website}/events?startAt=#{JS.string(to)}&endAt=#{JS.string(next - 1)}",
              headers,
              @max_day_events
            )

          {:cont, {events ++ read, next}}
        else
          {:halt, {events, to}}
        end
      end)

    sessions =
      if events != [],
        do:
          all(
            http,
            base,
            "/websites/#{website}/sessions?startAt=#{JS.string(from)}&endAt=#{JS.string(to - 1)}",
            headers,
            @max_day_events * @step_days
          ),
        else: []

    info = Map.new(sessions, &{&1["id"], &1})
    ns = "umami-visits:#{website}"

    visits =
      events
      |> Enum.filter(fn e ->
        type = get(e, "eventType")
        type == @pageview or (type == @custom_event and JS.truthy?(get(e, "eventName")))
      end)
      |> Enum.map(&{Http.parse_date(get(&1, "createdAt")), &1})
      |> Enum.filter(fn {ts, _} -> JS.finite?(ts) and ts < state["end"] end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {ts, e} -> {ns, from_umami(e, ts, Map.get(info, get(e, "sessionId")))} end)

    counts =
      write_step(rl, site_id, from, to, visits, fn store ->
        Store.set_setting(store, progress_key(site_id, website), JS.string(to))
      end)

    total_days = max(1, JS.ceil((state["end"] - state["start"]) / @day))
    done_days = min(total_days, JS.ceil((to - state["start"]) / @day))
    more = to < state["end"]

    next =
      if more do
        moved = Object.put(state, "day", to)
        JS.stringify(if uses_key, do: moved, else: Object.put(moved, "token", token))
      end

    JS.obj(
      cursor: next,
      done: done_days,
      total: total_days,
      pageviews: counts.pageviews,
      events: counts.events,
      visits: counts.visits
    )
  end

  defp referrer_of(domain, path, query) do
    if JS.truthy?(domain) do
      q = if JS.truthy?(query), do: "?" <> String.replace(query, ~r/^\?/, ""), else: ""
      "https://#{domain}#{JS.or_else(path, "/")}#{q}"
    else
      ""
    end
  end

  defp text(value), do: JS.nullish(value, "")

  defp from_umami(e, ts, session) do
    %{
      ts: ts,
      key: get(e, "sessionId"),
      kind: if(get(e, "eventType") == @pageview, do: "pageview", else: "event"),
      hostname: text(get(e, "hostname")),
      path: get(e, "urlPath"),
      query: text(get(e, "urlQuery")),
      referrer: referrer_of(get(e, "referrerDomain"), get(e, "referrerPath"), get(e, "referrerQuery")),
      title: text(get(e, "pageTitle")),
      name: text(get(e, "eventName")),
      country: text(get(e, "country")),
      region: JS.or_else(get(session, "subdivision1"), JS.or_else(get(session, "region"), "")),
      city: text(get(e, "city")),
      browser: text(get(e, "browser")),
      os: text(get(e, "os")),
      device: text(get(e, "device")),
      screen: text(get(session, "screen")),
      language: text(get(session, "language"))
    }
  end

  # Writes one step of imported visits, sorted oldest first, all within [from, to). Whatever an earlier import
  # left in those times is cleared first, so a step can always run again. `done` runs in the same transaction.
  defp write_step(rl, site_id, from, to, hits, done) do
    site = Runlight.site(rl, site_id) || raise(ImportError, message: "Unknown site", code: "unknown_site")

    Store.transaction(rl.store, fn store ->
      # Days this step writes into are added up again later, with the imported visits in them.
      Store.clear_rollups(store, site_id, from: from, to: to)
      imported = "SELECT id FROM rl_sessions WHERE site = ? AND imported = 1"

      Store.run_sql(
        store,
        "DELETE FROM rl_events WHERE site = ? AND ts >= ? AND ts < ? AND kind IN ('pageview', 'event') AND session IN (#{imported})",
        [site_id, from, to, site_id]
      )

      # Visits of these days that kept no rows go too.
      Store.run_sql(
        store,
        """
        DELETE FROM rl_sessions WHERE site = ? AND imported = 1 AND started_at >= ? AND started_at < ?
                 AND id NOT IN (SELECT e.session FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ?)\
        """,
        [site_id, from, to, site_id, from, to + Sql.event_tail_ms()]
      )

      counts =
        Enum.reduce(hits, %{pageviews: 0, events: 0, visits: 0}, fn {ns, hit}, counts ->
          made = write_event(store, site, ns, hit)
          counts = if made, do: %{counts | visits: counts.visits + 1}, else: counts

          if hit.kind == "pageview",
            do: %{counts | pageviews: counts.pageviews + 1},
            else: %{counts | events: counts.events + 1}
        end)

      carry_over(store, site_id, from, to)
      if done, do: done.(store)
      counts
    end)
  end

  # A visit that began in an earlier step and went on into this one is counted again from its rows, so a
  # repeated step cannot leave it with doubled totals. The day it began may already be built, so it is cleared.
  defp carry_over(store, site_id, from, to) do
    carried =
      Store.all_rows(
        store,
        """
        SELECT s.id AS id, s.started_at AS started_at FROM rl_sessions s
               WHERE s.site = ? AND s.imported = 1 AND s.started_at < ? AND s.started_at >= ?
                 AND s.id IN (SELECT e.session FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ?)\
        """,
        [site_id, from, from - Sql.event_tail_ms(), site_id, from, to]
      )

    if carried != [] do
      earliest = carried |> Enum.map(&JS.number(&1["started_at"])) |> Enum.min()
      Store.clear_rollups(store, site_id, from: earliest, to: from)

      rows =
        carried
        |> Enum.chunk_every(90)
        |> Enum.flat_map(fn chunk ->
          ids = Enum.map(chunk, &JS.string(&1["id"]))

          Store.all_rows(
            store,
            """
            SELECT e.session AS session, e.kind AS kind, e.ts AS ts, e.path AS path FROM rl_events e
                         WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind IN ('pageview', 'event') AND e.session IN (#{Enum.map_join(ids, ", ", fn _ -> "?" end)})
                         ORDER BY e.ts, e.id\
            """,
            [site_id, earliest, to] ++ ids
          )
        end)

      {order, totals} =
        Enum.reduce(rows, {[], %{}}, fn r, {order, totals} ->
          id = JS.string(r["session"])

          {order, t} =
            if Map.has_key?(totals, id),
              do: {order, totals[id]},
              else: {[id | order], %{pageviews: 0, events: 0, last: 0, exit: nil}}

          t =
            if r["kind"] == "pageview",
              do: %{t | pageviews: t.pageviews + 1, exit: r["path"]},
              else: %{t | events: t.events + 1}

          {order, Map.put(totals, id, %{t | last: max(t.last, JS.number(r["ts"]))})}
        end)

      for id <- Enum.reverse(order) do
        t = totals[id]

        Store.run_sql(
          store,
          "UPDATE rl_sessions SET pageviews = ?, events = ?, last_at = ?, exit_path = COALESCE(?, exit_path) WHERE id = ?",
          [
            t.pageviews,
            t.events,
            t.last,
            t.exit,
            id
          ]
        )
      end
    end

    :ok
  end

  # Writes one imported pageview or event as part of a Runlight visit. Visitors are hashed per day from the
  # hit's key, and a hit within thirty minutes of the visitor's last one joins that visit. Answers whether it
  # started a new visit.
  defp write_event(store, site, ns, e) do
    # The site's own day, as live visitors are counted, so days add up the same way in rollups.
    day = Time.local_date(e.ts, site["timezone"])
    key = JS.string(e.key)
    visitor = Importers.hex_id("#{ns}:#{key}:#{day}", 16)
    # A visit that runs past midnight keeps the id it started with, as a live one does.
    yesterday = Importers.hex_id("#{ns}:#{key}:#{Time.add_days(day, -1)}", 16)
    host = JS.lower(JS.or_else(e.hostname, List.first(site["hostnames"]) || "imported.invalid"))
    query = if JS.truthy?(e.query), do: "?" <> String.replace(e.query, ~r/^\?/, ""), else: ""

    page =
      case Url.parse("https://#{host}#{JS.or_else(e.path, "/")}#{query}") do
        nil -> Sources.parse_page(Url.new("https://#{host}/"))
        url -> Sources.parse_page(url)
      end

    open = Store.open_session(store, site["id"], [visitor, yesterday], e.ts - Runlight.session_idle_ms())

    id =
      if open do
        open.id
      else
        id = Importers.hex_id("#{ns}:#{key}:#{JS.string(e.ts)}")
        Store.run_sql(store, "DELETE FROM rl_sessions WHERE id = ?", [id])
        country = e.country |> JS.or_else("") |> JS.upper() |> JS.slice(0, 2)
        raw_region = e.region

        region =
          if JS.truthy?(raw_region) do
            text = if String.contains?(raw_region, "-"), do: raw_region, else: "#{country}-#{raw_region}"
            text |> JS.upper() |> JS.slice(0, 10)
          else
            ""
          end

        valid = Regex.match?(~r/\A[A-Z]{2}\z/, country)
        attribution = Sources.attribute(page, e.referrer, site["hostnames"])

        Store.insert_session(store, %{
          id: id,
          site: site["id"],
          visitor: visitor,
          started_at: e.ts,
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
          country: if(valid, do: country, else: ""),
          region: if(valid, do: region, else: ""),
          city: e.city |> JS.or_else("") |> JS.slice(0, 100),
          browser: Importers.browser_name(JS.or_else(e.browser, "")),
          browser_version: "",
          os: Importers.system_name(e.os),
          os_version: "",
          device: Importers.device_name(JS.or_else(e.device, "")),
          screen: JS.slice(e.screen, 0, 20),
          language: JS.slice(e.language, 0, 35)
        })

        # No engaged time is known, so duration falls back to first-to-last pageview.
        Store.run_sql(store, "UPDATE rl_sessions SET imported = 1, engaged_ms = NULL WHERE id = ?", [id])
        id
      end

    Store.touch_session(store, id, e.ts, e.kind, page.path)

    Store.insert_event(store, %{
      site: site["id"],
      ts: e.ts,
      kind: e.kind,
      # The visit's own visitor, which for one running past midnight is the id of the day it started.
      visitor: if(open, do: open.visitor, else: visitor),
      session: id,
      pageview: "",
      path: page.path,
      hostname: page.hostname,
      title: if(e.kind == "pageview", do: JS.slice(e.title, 0, 300), else: ""),
      name: if(e.kind == "event", do: JS.slice(e.name, 0, 120), else: ""),
      props: nil,
      engaged_ms: 0,
      scroll: nil,
      link: ""
    })

    open == nil
  end

  @doc """
  One batch of a CSV file, sorted oldest first by the dashboard. Only rows
  from before Runlight's own first visit, and within what the site keeps, are
  written. A batch can run again: its time span is cleared first.
  """
  @spec import_csv_visits(Runlight.t(), String.t(), term()) :: Object.t()
  def import_csv_visits(rl, site_id, rows) do
    Runlight.init(rl)
    if Runlight.site(rl, site_id) == nil, do: raise(ImportError, message: "Unknown site", code: "unknown_site")

    unless is_list(rows) and length(rows) <= csv_batch(),
      do:
        raise(ImportError,
          message: "Send at most #{csv_batch()} rows at a time",
          code: "import_csv_batch",
          params: %{"max" => Integer.to_string(csv_batch())}
        )

    clean =
      Enum.map(rows, fn r ->
        pairs =
          if JS.objectish?(r) and not is_list(r),
            do: Object.to_list(r),
            else: if(is_list(r), do: Enum.with_index(r, fn v, i -> {Integer.to_string(i), v} end), else: [])

        pairs |> Enum.map(fn {k, v} -> {k |> JS.trim() |> JS.lower(), JS.string(JS.nullish(v, ""))} end) |> Object.new()
      end)

    format = csv_format(Object.keys(List.first(clean) || Object.new()))

    unless format,
      do:
        raise(ImportError,
          message: "This CSV is not an Umami export or Runlight's visit format",
          code: "import_csv_format"
        )

    cutoff = Runlight.retention_cutoff(rl, site_id) || 0
    own = Store.first_own_visit(rl.store, site_id)
    finish = if own, do: min(own, Runlight.now(rl)), else: Runlight.now(rl)

    hits =
      clean
      |> Enum.map(&csv_hit(&1, format))
      |> Enum.filter(&(&1 != nil and elem(&1, 1).ts >= cutoff and elem(&1, 1).ts < finish))
      |> Enum.sort_by(&elem(&1, 1).ts)

    skipped = length(clean) - length(hits)

    if hits == [] do
      JS.obj(pageviews: 0, events: 0, visits: 0, skipped: skipped)
    else
      first = elem(hd(hits), 1).ts
      last = elem(List.last(hits), 1).ts
      counts = write_step(rl, site_id, first, last + 1, hits, nil)
      JS.obj(pageviews: counts.pageviews, events: counts.events, visits: counts.visits, skipped: skipped)
    end
  end

  ## CSV

  @doc "Which shape a file is, from its header row (lower case, as the dashboard reads it): \"umami\", \"runlight\", or nil."
  @spec csv_format([String.t()]) :: String.t() | nil
  def csv_format(columns) do
    cond do
      "created_at" in columns and "url_path" in columns -> "umami"
      "time" in columns and ("path" in columns or "url" in columns) -> "runlight"
      true -> nil
    end
  end

  defp row(o, key) do
    case o do
      %Object{} -> o[key]
      %{} -> Map.get(o, key)
    end
  end

  @doc """
  A row's time in milliseconds, or NaN. ISO 8601 with or without a zone (both
  read as UTC when no zone is given, as Umami writes them), or a Unix time in
  seconds or milliseconds.
  """
  @spec row_time(Object.t() | map(), String.t()) :: number() | :nan
  def row_time(r, format) do
    text = JS.trim(JS.nullish(row(r, if(format == "umami", do: "created_at", else: "time")), ""))

    cond do
      text == "" ->
        :nan

      Regex.match?(~r/\A\d+(\.\d+)?\z/, text) ->
        n = JS.number(text)
        if n < 1.0e12, do: JS.round(n * 1000), else: JS.round(n)

      true ->
        iso = String.replace(text, " ", "T", global: false)
        zoned = Regex.match?(~r/[zZ]|[+-]\d\d:?\d\d\z/, iso) or not Regex.match?(~r/T\d/, iso)
        JS.date_parse(if zoned, do: iso, else: iso <> "Z")
    end
  end

  defp cell(r, names) do
    Enum.find_value(names, "", fn n ->
      v = row(r, n)
      if is_binary(v) and JS.trim(v) != "", do: JS.trim(v)
    end)
  end

  # A row with no visitor is its own visit, keyed by its whole content so a second import gives it the same ids.
  defp own_key(r) do
    pairs =
      case r do
        %Object{} -> Object.to_list(r)
        %{} -> Map.to_list(r)
      end

    entries = pairs |> Enum.sort_by(&elem(&1, 0), &(JS.compare(&1, &2) <= 0)) |> Enum.map(fn {k, v} -> [k, v] end)
    "row:" <> JS.stringify(entries)
  end

  # A referrer as a full address: a bare domain gains https://.
  defp full_referrer(""), do: ""
  defp full_referrer(v), do: if(Regex.match?(~r/^[a-z][a-z0-9+.-]*:\/\//i, v), do: v, else: "https://" <> v)

  @doc """
  One row as `{namespace, hit}`, or nil for a row that is not a pageview or a
  named event, or has no time. Umami rows use the namespace the Umami API
  import does, so the same visits brought in both ways get the same ids.
  """
  @spec csv_hit(Object.t() | map(), String.t()) :: {String.t(), map()} | nil
  def csv_hit(r, format) do
    ts = row_time(r, format)

    cond do
      not JS.finite?(ts) -> nil
      format == "umami" -> umami_hit(r, ts)
      true -> runlight_hit(r, ts)
    end
  end

  defp umami_hit(r, ts) do
    type = JS.or_else(cell(r, ["event_type"]), "1")
    name = cell(r, ["event_name"])

    if type != "1" and not (type == "2" and name != "") do
      nil
    else
      website = cell(r, ["website_id"])
      domain = cell(r, ["referrer_domain"])

      referrer =
        if domain == "" do
          ""
        else
          query = cell(r, ["referrer_query"])
          q = if query != "", do: "?" <> String.replace(query, ~r/^\?/, ""), else: ""
          "https://#{domain}#{JS.or_else(cell(r, ["referrer_path"]), "/")}#{q}"
        end

      {if(website != "", do: "umami-visits:#{website}", else: "umami-csv"),
       %{
         ts: ts,
         key: JS.or_else(cell(r, ["session_id", "visit_id"]), own_key(r)),
         kind: if(type == "1", do: "pageview", else: "event"),
         hostname: cell(r, ["hostname"]),
         path: JS.or_else(cell(r, ["url_path"]), "/"),
         query: cell(r, ["url_query"]),
         referrer: referrer,
         title: cell(r, ["page_title"]),
         name: if(type == "2", do: name, else: ""),
         country: cell(r, ["country"]),
         region: cell(r, ["subdivision1", "region"]),
         city: cell(r, ["city"]),
         browser: cell(r, ["browser"]),
         os: cell(r, ["os"]),
         device: cell(r, ["device"]),
         screen: cell(r, ["screen"]),
         language: cell(r, ["language"])
       }}
    end
  end

  # Runlight's own shape: a full url, or a path (with its query) and a hostname.
  defp runlight_hit(r, ts) do
    hostname = cell(r, ["hostname"])
    url = cell(r, ["url"])

    parts =
      if url != "" do
        case Url.parse(if Regex.match?(~r/^[a-z][a-z0-9+.-]*:\/\//i, url), do: url, else: "https://" <> url) do
          nil -> nil
          u -> {JS.or_else(hostname, u.hostname), u.pathname, JS.slice(u.search, 1)}
        end
      else
        path = cell(r, ["path"])

        case :binary.match(path, "?") do
          {at, _} -> {hostname, binary_part(path, 0, at), binary_part(path, at + 1, byte_size(path) - at - 1)}
          :nomatch -> {hostname, path, ""}
        end
      end

    case parts do
      nil ->
        nil

      {hostname, path, query} ->
        path = if String.starts_with?(path, "/"), do: path, else: "/" <> path
        name = cell(r, ["event"])

        {"csv",
         %{
           ts: ts,
           # Without a visitor column every row is its own visit.
           key: JS.or_else(cell(r, ["visitor"]), own_key(r)),
           kind: if(name != "", do: "event", else: "pageview"),
           hostname: hostname,
           path: path,
           query: query,
           referrer: full_referrer(cell(r, ["referrer"])),
           title: cell(r, ["title"]),
           name: name,
           country: cell(r, ["country"]),
           region: cell(r, ["region"]),
           city: cell(r, ["city"]),
           browser: cell(r, ["browser"]),
           os: cell(r, ["os"]),
           device: cell(r, ["device"]),
           screen: cell(r, ["screen"]),
           language: cell(r, ["language"])
         }}
    end
  end
end
