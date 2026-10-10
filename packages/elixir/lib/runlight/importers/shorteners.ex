defmodule Runlight.Importers.Shorteners do
  @moduledoc false
  # Internal. One step of each shortener's import (the SDK's importers/dub.ts,
  # bitly.ts, shortio.ts, rebrandly.ts, and umami.ts): a few links and their
  # history, and a cursor to carry on from. Each step answers a JavaScript
  # object in the SDK's shape, `{cursor, total, links}`, each link
  # `{link, clicks, daily}` or `{link, known: true}`, so what one importer
  # hands on is what the TypeScript one does. `known` is a function of the
  # source's id, the slug, and the destination.

  import Runlight.Importers.Http, only: [get: 2, dig: 2, date_or: 2, parse_date: 1]

  alias Runlight.ImportError
  alias Runlight.Importers.Http
  alias Runlight.JS
  alias Runlight.JS.Object

  defp cred(credentials, key) do
    case Map.get(credentials, key) do
      v when is_binary(v) -> JS.trim(v)
      _ -> ""
    end
  end

  defp key!(value, message, service) do
    if value == "", do: raise(ImportError, message: message, code: "import_key", params: %{"service" => service})
    value
  end

  defp lower(v) when is_binary(v), do: JS.lower(v)
  defp lower(v), do: v

  defp str(v), do: JS.string(v)

  ## Dub

  @dub "https://api.dub.co"
  @dub_page 10

  @doc """
  Dub. Links come from GET /links (cursor pages, archived included). Click
  history is per click from /events where the plan allows, else daily counts
  from /analytics, else none; the first link decides.
  """
  def dub(http, credentials, cursor, known, now) do
    key = credentials |> cred("apiKey") |> key!("Enter a Dub API key", "Dub")
    headers = [{"authorization", "Bearer #{key}"}]
    state = if cursor, do: JS.parse!(cursor), else: JS.obj(after: nil, history: nil)

    after_part =
      if JS.truthy?(state["after"]), do: "&startingAfter=#{JS.encode_uri_component(str(state["after"]))}", else: ""

    list = Http.get_json(http, "#{@dub}/links?pageSize=#{@dub_page}&showArchived=true#{after_part}", headers: headers)

    {links, history} =
      Enum.reduce(list, {[], state["history"]}, fn l, {links, history} ->
        if known.(l["id"], l["key"], l["url"]) do
          {links ++ [JS.obj(link: link(l["id"], l["key"], "", "", l["url"], 0), known: true)], history}
        else
          {clicks, history} =
            if history in [nil, "events"], do: dub_events(http, headers, l, history), else: {:undefined, history}

          {daily, history} = if history == "daily", do: dub_daily(http, headers, l), else: {:undefined, history}

          item =
            JS.obj(
              link:
                link(l["id"], l["key"], l["domain"], JS.or_else(l["title"], ""), l["url"], date_or(l["createdAt"], now)),
              clicks: clicks,
              daily: daily
            )

          {links ++ [item], history}
        end
      end)

    last = List.last(list)

    next =
      if length(list) == @dub_page and last != nil,
        do: JS.stringify(JS.obj(after: last["id"], history: history)),
        else: nil

    JS.obj(cursor: next, total: nil, links: links)
  end

  # Whether Dub said the plan does not include what was asked (403, or 402). Any other failure (a server error
  # that outlasts the retries, say) fails the step and leaves the history mode as it was.
  defp plan_refused?(error), do: Http.http_error?(error) and error.status in [403, 402]

  defp dub_events(http, headers, l, history) do
    clicks = dub_pages(http, headers, l, 1, [])
    {clicks, "events"}
  rescue
    error in ImportError ->
      if not plan_refused?(error), do: reraise(error, __STACKTRACE__)
      _ = history
      {:undefined, "daily"}
  end

  defp dub_pages(http, headers, l, page, acc) do
    events =
      Http.get_json(
        http,
        "#{@dub}/events?event=clicks&linkId=#{JS.encode_uri_component(str(l["id"]))}&interval=all&sortOrder=asc&limit=1000&page=#{page}",
        headers: headers
      )

    acc =
      acc ++
        Enum.map(events, fn e ->
          click = get(e, "click")
          referer = get(click, "referer")

          referrer =
            JS.or_else(
              get(click, "refererUrl"),
              if(JS.truthy?(referer) and referer != "(direct)", do: "https://#{referer}/", else: "")
            )

          JS.obj(
            ts: parse_date(get(e, "timestamp")),
            visit: get(click, "id"),
            referrer: referrer,
            country: get(click, "country"),
            region: get(click, "region"),
            city: get(click, "city"),
            device: lower(get(click, "device")),
            browser: get(click, "browser"),
            os: get(click, "os")
          )
        end)

    if length(events) < 1000, do: acc, else: dub_pages(http, headers, l, page + 1, acc)
  end

  defp dub_daily(http, headers, l) do
    series =
      Http.get_json(
        http,
        "#{@dub}/analytics?event=clicks&groupBy=timeseries&interval=all&linkId=#{JS.encode_uri_component(str(l["id"]))}",
        headers: headers
      )

    daily = for p <- series, p["clicks"] > 0, do: JS.obj(day: JS.slice(p["start"], 0, 10), clicks: p["clicks"])
    {daily, "daily"}
  rescue
    error in ImportError ->
      if not plan_refused?(error), do: reraise(error, __STACKTRACE__)
      {:undefined, "none"}
  end

  defp link(id, slug, domain, name, url, created),
    do: JS.obj(sourceId: id, slug: slug, domain: domain, name: name, url: url, createdAt: created)

  ## Bitly

  @bitly "https://api-ssl.bitly.com/v4"
  @bitly_page 20

  # A short URL's domain and back-half, from "bit.ly/abc" or "https://t.brand.com/sale".
  defp split(value) do
    bare = String.replace(value, ~r/^https?:\/\//, "")

    case :binary.match(bare, "/") do
      :nomatch ->
        {bare, ""}

      {at, _} ->
        {binary_part(bare, 0, at), bare |> binary_part(at + 1, byte_size(bare) - at - 1) |> String.replace(~r/\/$/, "")}
    end
  end

  @doc """
  Bitly. Links are listed per group, with archived ones. Bitly only keeps
  daily click counts. A custom back-half or branded domain wins over the
  random bit.ly one.
  """
  def bitly(http, credentials, cursor, known, now) do
    token = JS.or_else(cred(credentials, "token"), cred(credentials, "apiKey"))

    if token == "",
      do: raise(ImportError, message: "Enter a Bitly access token", code: "import_key", params: %{"service" => "Bitly"})

    headers = [{"authorization", "Bearer #{JS.string(token)}"}]

    state =
      if cursor do
        JS.parse!(cursor)
      else
        groups = Http.get_json(http, "#{@bitly}/groups", headers: headers)["groups"] |> Enum.map(& &1["guid"])
        JS.obj(groups: groups, g: 0, after: nil)
      end

    case Enum.at(state["groups"], state["g"]) do
      nil ->
        JS.obj(cursor: nil, total: nil, links: [])

      group ->
        after_part =
          if JS.truthy?(state["after"]), do: "&search_after=#{JS.encode_uri_component(str(state["after"]))}", else: ""

        page =
          Http.get_json(http, "#{@bitly}/groups/#{group}/bitlinks?size=#{@bitly_page}&archived=both#{after_part}",
            headers: headers
          )

        links =
          Enum.flat_map(page["links"], fn b ->
            custom = dig(b, ["custom_bitlinks", "0"])
            short_from = if custom in [nil, :undefined], do: b["id"], else: custom
            {domain, slug} = split(short_from)

            cond do
              JS.truthy?(get(b, "is_deleted")) ->
                []

              known.(b["id"], slug, b["long_url"]) ->
                [JS.obj(link: link(b["id"], "", "", "", b["long_url"], 0), known: true)]

              true ->
                daily = bitly_daily(http, headers, b)

                [
                  JS.obj(
                    link:
                      link(
                        b["id"],
                        slug,
                        domain,
                        JS.or_else(b["title"], ""),
                        b["long_url"],
                        date_or(b["created_at"], now)
                      ),
                    daily: daily
                  )
                ]
            end
          end)

        next = dig(page, ["pagination", "search_after"])
        next = if JS.truthy?(next) and length(page["links"]) == @bitly_page, do: next, else: nil

        more =
          cond do
            next ->
              Object.put(state, "after", next)

            state["g"] + 1 < length(state["groups"]) ->
              state |> Object.put("g", state["g"] + 1) |> Object.put("after", nil)

            true ->
              nil
          end

        JS.obj(cursor: if(more, do: JS.stringify(more)), total: nil, links: links)
    end
  end

  defp bitly_daily(http, headers, b) do
    clicks =
      Http.get_json(http, "#{@bitly}/bitlinks/#{JS.encode_uri_component(str(b["id"]))}/clicks?unit=day&units=-1",
        headers: headers
      )

    for c <- clicks["link_clicks"], c["clicks"] > 0, do: JS.obj(day: JS.slice(c["date"], 0, 10), clicks: c["clicks"])
  rescue
    # Plans without analytics refuse this; the link still comes across.
    error in ImportError ->
      if not Http.http_error?(error) or error.status == 401, do: reraise(error, __STACKTRACE__)
      :undefined
  end

  ## Rebrandly

  @rebrandly "https://api.rebrandly.com/v1"
  @rebrandly_page 25

  @doc """
  Rebrandly. Its API gives only total clicks, with no dates, so links come
  across with their slugs and domains and start their history fresh.
  """
  def rebrandly(http, credentials, cursor, _known, now) do
    key = credentials |> cred("apiKey") |> key!("Enter a Rebrandly API key", "Rebrandly")
    workspace = cred(credentials, "workspace")
    headers = [{"apikey", key}] ++ if(workspace != "", do: [{"workspace", workspace}], else: [])
    last = if cursor, do: "&last=#{JS.encode_uri_component(cursor)}", else: ""

    list =
      Http.get_json(http, "#{@rebrandly}/links?orderBy=createdAt&orderDir=desc&limit=#{@rebrandly_page}#{last}",
        headers: headers
      )

    links =
      Enum.map(list, fn l ->
        domain = JS.nullish(dig(l, ["domain", "fullName"]), "")

        JS.obj(
          link:
            link(
              JS.string(l["id"]),
              l["slashtag"],
              domain,
              JS.or_else(get(l, "title"), ""),
              l["destination"],
              date_or(l["createdAt"], now)
            )
        )
      end)

    finish = List.last(list)

    JS.obj(
      cursor: if(length(list) == @rebrandly_page and finish != nil, do: JS.string(finish["id"])),
      total: nil,
      links: links
    )
  end

  ## Short.io

  @shortio_api "https://api.short.io"
  @shortio_stats "https://statistics.short.io/statistics"
  @shortio_page 8
  # The statistics API allows 60 requests a minute.
  @stats_gap_ms 1050

  @doc """
  Short.io. Links are listed per domain. Daily click counts come from the
  statistics API, paced to its limit of 60 requests a minute.
  """
  def shortio(http, credentials, cursor, known, now) do
    key = credentials |> cred("apiKey") |> key!("Enter a Short.io secret API key", "Short.io")
    headers = [{"authorization", key}]

    state =
      if cursor do
        JS.parse!(cursor)
      else
        domains =
          http
          |> Http.get_json("#{@shortio_api}/api/domains?limit=300", headers: headers)
          |> Enum.map(&JS.obj(id: &1["id"], hostname: &1["hostname"]))

        JS.obj(domains: domains, d: 0, token: nil, total: nil)
      end

    case Enum.at(state["domains"], state["d"]) do
      nil ->
        JS.obj(cursor: nil, total: nil, links: [])

      domain ->
        token =
          if JS.truthy?(state["token"]), do: "&pageToken=#{JS.encode_uri_component(str(state["token"]))}", else: ""

        page =
          Http.get_json(http, "#{@shortio_api}/api/links?domain_id=#{str(domain["id"])}&limit=#{@shortio_page}#{token}",
            headers: headers
          )

        links =
          Enum.map(page["links"], fn l ->
            id = str(JS.nullish(get(l, "idString"), l["id"]))

            if known.(id, l["path"], l["originalURL"]) do
              JS.obj(link: link(id, l["path"], "", "", l["originalURL"], 0), known: true)
            else
              daily = shortio_daily(http, headers, id)

              JS.obj(
                link:
                  link(
                    id,
                    l["path"],
                    domain["hostname"],
                    JS.or_else(get(l, "title"), ""),
                    l["originalURL"],
                    date_or(l["createdAt"], now)
                  ),
                daily: daily
              )
            end
          end)

        next = get(page, "nextPageToken")

        more =
          cond do
            JS.truthy?(next) ->
              Object.put(state, "token", next)

            state["d"] + 1 < length(state["domains"]) ->
              state |> Object.put("d", state["d"] + 1) |> Object.put("token", nil)

            true ->
              nil
          end

        JS.obj(cursor: if(more, do: JS.stringify(more)), total: nil, links: links)
    end
  end

  defp shortio_daily(http, headers, id) do
    Http.pause(http, @stats_gap_ms)

    body =
      Http.get_json(http, "#{@shortio_stats}/link/#{JS.encode_uri_component(id)}/by_interval",
        method: "POST",
        headers: headers ++ [{"content-type", "application/json"}],
        body: JS.stringify(JS.obj(period: "total", clicksChartInterval: "day", tz: "UTC"))
      )

    raw = get(body, "clickStatistics")
    points = if is_list(raw), do: raw, else: JS.nullish(dig(raw, ["datasets", "0", "data"]), [])

    for p <- points,
        y = JS.number(p["y"]),
        is_number(y) and y > 0,
        x = p["x"],
        ts = if(is_number(x), do: x, else: JS.date_parse(x)),
        # A point whose date cannot be read is left out, not the link.
        is_number(ts) and abs(ts) <= 8.64e15 do
      JS.obj(day: JS.iso_day(trunc(ts)), clicks: p["y"])
    end
  rescue
    error in ImportError ->
      if not Http.http_error?(error) or error.status == 401, do: reraise(error, __STACKTRACE__)
      :undefined
  end

  ## Umami

  @umami_page 5

  @doc """
  Signs in to an Umami: an API key, or a username and password (stock
  self-hosted Umami has no API keys). A token from an earlier step is reused.
  Answers `{base, token}`.
  """
  def umami_sign_in(http, credentials, token \\ nil) do
    base = (Map.get(credentials, "url") || "") |> JS.trim() |> String.replace(~r/\/+\z/, "")

    unless Regex.match?(~r/^https:\/\/[^\/]+/, base),
      do:
        raise(ImportError,
          message: "Enter your Umami address, like https://stats.example.com",
          code: "import_umami_address"
        )

    key = cred(credentials, "apiKey")

    cond do
      key != "" or JS.truthy?(token) ->
        {base, if(key != "", do: key, else: token)}

      not JS.truthy?(Map.get(credentials, "username")) or not JS.truthy?(Map.get(credentials, "password")) ->
        raise ImportError, message: "Enter an API key, or a username and password", code: "import_umami_login"

      true ->
        login =
          Http.get_json(http, "#{base}/api/auth/login",
            method: "POST",
            headers: [{"content-type", "application/json"}],
            body: JS.stringify(JS.obj(username: credentials["username"], password: credentials["password"]))
          )

        token = get(login, "token")

        # A sign-in that answers without a token was refused, whatever its status.
        unless is_binary(token) and token != "",
          do: raise(ImportError, message: "The key or sign-in was refused", code: "import_refused")

        {base, token}
    end
  end

  @doc """
  Umami v3 (and forks with custom link domains). In Umami a link's clicks are
  events stored under the link's id, with the visitor's session holding place
  and device.
  """
  def umami(http, credentials, cursor, known, now) do
    # A key comes with every step; only a sign-in token, which expires, rides in the cursor.
    saved = if cursor, do: JS.parse!(cursor), else: JS.obj(page: 1)
    key = cred(credentials, "apiKey")
    {base, token} = umami_sign_in(http, credentials, JS.nullish(get(saved, "token"), nil))
    page = saved["page"]
    headers = [{"authorization", "Bearer #{JS.string(token)}"}]
    list = Http.get_json(http, "#{base}/api/links?page=#{str(page)}&pageSize=#{@umami_page}", headers: headers)

    links =
      Enum.flat_map(list["data"], fn l ->
        cond do
          JS.truthy?(get(l, "deletedAt")) ->
            []

          known.(l["id"], l["slug"], l["url"]) ->
            [JS.obj(link: link(l["id"], l["slug"], "", l["name"], l["url"], 0), known: true)]

          true ->
            created = date_or(l["createdAt"], now)
            range = "startAt=#{JS.string(created - 86_400_000)}&endAt=#{JS.string(now + 60_000)}"
            events = umami_all(http, base, headers, "/websites/#{l["id"]}/events?#{range}")
            sessions = umami_all(http, base, headers, "/websites/#{l["id"]}/sessions?#{range}")
            info = Map.new(sessions, &{&1["id"], &1})

            clicks =
              Enum.map(events, fn e ->
                s = Map.get(info, e["sessionId"])
                domain = get(e, "referrerDomain")

                JS.obj(
                  ts: parse_date(get(e, "createdAt")),
                  visit: get(e, "sessionId"),
                  referrer:
                    if(JS.truthy?(domain), do: "https://#{domain}#{JS.or_else(get(e, "referrerPath"), "/")}", else: ""),
                  path: get(e, "urlPath"),
                  query: get(e, "urlQuery"),
                  country: get(e, "country"),
                  region: get(s, "region"),
                  city: get(e, "city"),
                  browser: get(e, "browser"),
                  os: get(e, "os"),
                  device: get(e, "device"),
                  screen: get(s, "screen"),
                  language: get(s, "language")
                )
              end)

            domain = JS.nullish(dig(l, ["customDomain", "domain"]), "")
            [JS.obj(link: link(l["id"], l["slug"], domain, l["name"], l["url"], created), clicks: clicks)]
        end
      end)

    # Without a count there is no total, and a full page may have more after it.
    count = if is_number(get(list, "count")), do: list["count"], else: nil

    more =
      if count == nil, do: length(list["data"]) == @umami_page, else: page * @umami_page < count and list["data"] != []

    next =
      if more do
        JS.stringify(if key != "", do: JS.obj(page: page + 1), else: JS.obj(page: page + 1, token: token))
      end

    JS.obj(cursor: next, total: count, links: links)
  end

  defp umami_all(http, base, headers, path, page \\ 1, out \\ []) do
    body = Http.get_json(http, "#{base}/api#{path}&page=#{page}&pageSize=1000", headers: headers)
    out = out ++ body["data"]

    if length(out) >= body["count"] or body["data"] == [],
      do: out,
      else: umami_all(http, base, headers, path, page + 1, out)
  end
end
