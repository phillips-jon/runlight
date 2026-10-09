defmodule Runlight.Importers do
  @moduledoc """
  Short links and their history from other shorteners: Umami, Dub, Bitly,
  Short.io, and Rebrandly (the SDK's importers). The dashboard drives an
  import a step at a time; each step fetches the next few links, writes each
  with its history, and reports progress, with a cursor to carry on from.
  Credentials come with every step and are never stored.
  """

  alias Runlight.Hash
  alias Runlight.ImportError
  alias Runlight.Importers.Http
  alias Runlight.Importers.Shorteners
  alias Runlight.JS
  alias Runlight.JS.Object
  alias Runlight.Sources
  alias Runlight.Store
  alias Runlight.Url

  @sources ~w(umami dub bitly shortio rebrandly)

  # Domains run by the shorteners themselves. Links there stay on Runlight's own path.
  @shortener_domains ~w(bit.ly bitly.com j.mp dub.sh dub.co dub.link short.gy rebrand.ly rebrandly.com rb.gy)

  # Browser and system names as other tools write them, in Runlight's spelling.
  @browsers %{
    "chrome" => "Chrome",
    "crios" => "Chrome",
    "chromium-webview" => "Android WebView",
    "chrome webview" => "Android WebView",
    "safari" => "Safari",
    "ios" => "Safari",
    "ios-webview" => "Safari",
    "mobile safari" => "Safari",
    "firefox" => "Firefox",
    "fxios" => "Firefox",
    "edge" => "Edge",
    "edge-chromium" => "Edge",
    "edge-ios" => "Edge",
    "microsoft edge" => "Edge",
    "opera" => "Opera",
    "opera-mini" => "Opera",
    "samsung" => "Samsung Internet",
    "samsung internet" => "Samsung Internet",
    "yandexbrowser" => "Yandex Browser",
    "facebook" => "Facebook",
    "instagram" => "Instagram",
    "brave" => "Brave",
    "duckduckgo" => "DuckDuckGo"
  }
  @systems %{
    "mac os" => "macOS",
    "mac os x" => "macOS",
    "macos" => "macOS",
    "ios" => "iOS",
    "android os" => "Android",
    "android" => "Android",
    "windows 10" => "Windows",
    "windows 11" => "Windows",
    "windows 7" => "Windows",
    "windows" => "Windows",
    "linux" => "Linux",
    "chrome os" => "Chrome OS",
    "chromium os" => "Chrome OS"
  }
  @devices %{
    "desktop" => "desktop",
    "laptop" => "desktop",
    "mobile" => "mobile",
    "smartphone" => "mobile",
    "phone" => "mobile",
    "tablet" => "tablet"
  }

  @doc false
  def browsers, do: @browsers
  @doc false
  def systems, do: @systems
  @doc false
  def devices, do: @devices

  @doc "A browser's name as another tool wrote it, in Runlight's spelling."
  def browser_name(value) do
    text = if is_binary(value), do: value, else: ""
    Map.get(@browsers, JS.lower(text)) || title(text)
  end

  @doc "A system's name as another tool wrote it, in Runlight's spelling."
  def system_name(value) do
    text = if is_binary(value), do: value, else: ""
    Map.get(@systems, JS.lower(text)) || JS.nullish(value, "")
  end

  @doc "A device as another tool wrote it, in Runlight's three."
  def device_name(value), do: Map.get(@devices, JS.lower(if(is_binary(value), do: value, else: ""))) || ""

  @doc "The first letter in upper case."
  def title(""), do: ""
  def title(v), do: JS.upper(JS.slice(v, 0, 1)) <> JS.slice(v, 1)

  @doc "The first `length` hex digits of SHA-256 of a value."
  def hex_id(value, length \\ 24), do: binary_part(Hash.sha256(value), 0, length)

  @doc "The Runlight id an imported link gets, from its source and its id there."
  def imported_link_id(source, source_id), do: hex_id("#{source}:#{JS.string(source_id)}")

  @doc "Two destinations are the same link when they differ only by a trailing slash."
  def same_url?(a, b), do: String.replace(a, ~r/\/\z/, "") == String.replace(b, ~r/\/\z/, "")

  @doc """
  One step of an import from `source`: fetch the next few links, write each
  with its history, and report progress. The page calls again with the
  cursor until it comes back null.
  """
  @spec import_step(Runlight.t(), String.t(), String.t(), map(), String.t() | nil, integer()) :: Object.t()
  def import_step(rl, site, source, credentials, cursor, done) do
    unless source in @sources,
      do:
        raise(ImportError,
          message: "Runlight cannot import from #{source}",
          code: "import_source",
          params: %{"source" => source}
        )

    Runlight.init(rl)

    known = fn source_id, slug, url ->
      if Store.link_by_id(rl.store, imported_link_id(source, source_id)) do
        true
      else
        if JS.truthy?(slug) and JS.truthy?(url) do
          taken = Store.link_by_slug(rl.store, slug)
          taken != nil and same_url?(taken["url"], url)
        else
          false
        end
      end
    end

    result = step(Http.new(rl), source, credentials, cursor, known, Runlight.now(rl))

    acc = %{done: done, links: 0, clicks: 0, skipped: 0, failed: []}

    acc =
      Enum.reduce(result["links"], acc, fn item, acc ->
        if item["known"] == true do
          %{acc | done: acc.done + 1, skipped: acc.skipped + 1}
        else
          written = write_link(rl, site, source, item["link"], item)
          acc = %{acc | done: acc.done + 1}

          case written.status do
            "created" ->
              %{acc | links: acc.links + 1, clicks: acc.clicks + written.clicks}

            "skipped" ->
              %{acc | skipped: acc.skipped + 1}

            _ ->
              failure =
                JS.obj(
                  slug: item["link"]["slug"],
                  reason: written.reason,
                  code: Map.get(written, :code, :undefined),
                  params: if(Map.has_key?(written, :code), do: JS.obj(written.params), else: :undefined)
                )

              %{acc | failed: acc.failed ++ [failure]}
          end
        end
      end)

    # Links the source skipped (deleted ones) still count toward progress.
    done = if result["cursor"] == nil and result["total"] != nil, do: max(acc.done, result["total"]), else: acc.done

    JS.obj(
      cursor: result["cursor"],
      done: done,
      total: result["total"],
      links: acc.links,
      clicks: acc.clicks,
      skipped: acc.skipped,
      failed: acc.failed
    )
  end

  @doc false
  # One step of a source's importer, as its module answers it.
  def step(http, source, credentials, cursor, known, now) do
    case source do
      "dub" -> Shorteners.dub(http, credentials, cursor, known, now)
      "bitly" -> Shorteners.bitly(http, credentials, cursor, known, now)
      "shortio" -> Shorteners.shortio(http, credentials, cursor, known, now)
      "rebrandly" -> Shorteners.rebrandly(http, credentials, cursor, known, now)
      "umami" -> Shorteners.umami(http, credentials, cursor, known, now)
    end
  end

  defp field(o, key), do: Http.get(o, key)

  @doc """
  Writes one link and its history in a single transaction: the link (and its
  branded domain), then each click as a visit like a live one, or daily
  counts as clicks without visitors. Ids come from the source's own ids, so
  importing again skips what is already there. Answers `%{status, clicks}`,
  with `reason`, `code`, and `params` for a link that failed.
  """
  @spec write_link(Runlight.t(), String.t(), String.t(), Object.t(), Object.t()) :: map()
  def write_link(rl, site, source, foreign, history) do
    id = imported_link_id(source, foreign["sourceId"])
    slug = foreign["slug"]
    url = foreign["url"]

    cond do
      Store.link_by_id(rl.store, id) ->
        %{status: "skipped", clicks: 0}

      (taken = Store.link_by_slug(rl.store, slug)) && same_url?(taken["url"], url) ->
        # The same slug to the same place is this link, brought in earlier some other way.
        %{status: "skipped", clicks: 0}

      taken = Store.link_by_slug(rl.store, slug) ->
        %{
          status: "failed",
          clicks: 0,
          reason: ~s(/#{slug} is already used by "#{taken["name"]}"),
          code: "import_slug_taken",
          params: %{"slug" => slug, "name" => taken["name"]}
        }

      not Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,99}\z/, slug) ->
        %{
          status: "failed",
          clicks: 0,
          reason: "/#{slug} has characters Runlight slugs cannot use",
          code: "import_slug_bad",
          params: %{"slug" => slug}
        }

      true ->
        domain = Sources.strip_www(JS.or_else(foreign["domain"], ""))
        domain = if domain in @shortener_domains, do: "", else: domain
        now = Runlight.now(rl)

        # Nothing in the transaction is one link's own problem (those are checked above), so a failure in it is
        # the database's, and it stops the import rather than marking the link.
        clicks =
          Store.transaction(rl.store, fn store ->
            # A failed earlier try can have left some of this link's clicks behind. Clear them, then write the
            # link row last, so a link only counts as imported once all of its history is in.
            Store.run_sql(
              store,
              "DELETE FROM rl_sessions WHERE id IN (SELECT DISTINCT session FROM rl_events WHERE link = ? AND session <> '')",
              [id]
            )

            Store.run_sql(store, "DELETE FROM rl_events WHERE link = ?", [id])

            clicks = write_clicks(store, site, source, foreign, domain, id, JS.nullish(field(history, "clicks"), []))
            clicks = write_daily(store, site, foreign, domain, id, JS.nullish(field(history, "daily"), []), clicks)

            if domain != "", do: Store.add_link_domain(store, domain, site, now)
            created = JS.or_else(foreign["createdAt"], now)

            Store.insert_link(
              store,
              JS.obj(
                id: id,
                site: site,
                domain: domain,
                slug: slug,
                name: JS.slice(JS.or_else(foreign["name"], slug), 0, 100),
                url: url,
                createdAt: created,
                updatedAt: created
              )
            )

            clicks
          end)

        if domain != "", do: Runlight.forget_link_domains(rl)
        %{status: "created", clicks: clicks}
    end
  end

  defp write_clicks(store, site, source, foreign, domain, id, clicks) do
    slug = foreign["slug"]

    {count, _made} =
      Enum.reduce(clicks, {0, MapSet.new()}, fn c, {count, made} ->
        ts = field(c, "ts")

        if not JS.finite?(ts) do
          {count, made}
        else
          visit = field(c, "visit")
          visit_key = if visit in [nil, :undefined], do: "#{JS.string(ts)}:#{count}", else: JS.string(visit)
          session = hex_id("#{source}:#{JS.string(foreign["sourceId"])}:#{visit_key}")
          # A visitor id lasts one day at most, as every other visitor id does.
          visitor = hex_id("#{source}:#{visit_key}:#{JS.iso_day(trunc(ts))}", 16)
          path = JS.or_else(field(c, "path"), "/#{slug}")

          made =
            if MapSet.member?(made, session) do
              made
            else
              Store.run_sql(store, "DELETE FROM rl_sessions WHERE id = ?", [session])
              host = if domain == "", do: "link.invalid", else: domain
              query = field(c, "query")
              query_part = if JS.truthy?(query), do: "?" <> String.replace(query, ~r/^\?/, ""), else: ""

              page =
                case Url.parse("https://#{host}#{path}#{query_part}") do
                  nil -> Sources.parse_page(Url.new("https://#{host}/#{slug}"))
                  url -> Sources.parse_page(url)
                end

              country = c |> field("country") |> JS.or_else("") |> JS.upper() |> JS.slice(0, 2)
              raw_region = field(c, "region")

              region =
                if JS.truthy?(raw_region) do
                  text = if String.contains?(raw_region, "-"), do: raw_region, else: "#{country}-#{raw_region}"
                  text |> JS.upper() |> JS.slice(0, 10)
                else
                  ""
                end

              attribution = Sources.attribute(page, JS.nullish(field(c, "referrer"), ""), [])

              Store.insert_session(store, %{
                id: session,
                site: site,
                visitor: visitor,
                started_at: ts,
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
                country: if(Regex.match?(~r/\A[A-Z]{2}\z/, country), do: country, else: ""),
                region: if(country != "", do: region, else: ""),
                city: c |> field("city") |> JS.or_else("") |> JS.slice(0, 100),
                browser: browser_name(JS.or_else(field(c, "browser"), "")),
                browser_version: "",
                os: system_name(field(c, "os")),
                os_version: "",
                device: device_name(JS.or_else(field(c, "device"), "")),
                screen: JS.nullish(field(c, "screen"), ""),
                language: JS.nullish(field(c, "language"), "")
              })

              Store.run_sql(store, "UPDATE rl_sessions SET imported = 1 WHERE id = ?", [session])
              MapSet.put(made, session)
            end

          Store.touch_session(store, session, ts, "click", path)

          Store.insert_event(store, %{
            site: site,
            ts: ts,
            kind: "click",
            visitor: visitor,
            session: session,
            pageview: "",
            path: JS.slice(path, 0, 1000),
            hostname: domain,
            title: "",
            name: slug,
            props: nil,
            engaged_ms: 0,
            scroll: nil,
            link: id
          })

          {count + 1, made}
        end
      end)

    count
  end

  # Counts without detail: clicks spread through each day, with no visitor or visit.
  defp write_daily(store, site, foreign, domain, id, daily, clicks) do
    Enum.reduce(daily, clicks, fn d, clicks ->
      start = JS.date_parse("#{JS.string(field(d, "day"))}T00:00:00Z")
      count = JS.number(field(d, "clicks"))

      if not JS.finite?(start) or not (is_number(count) and count > 0) do
        clicks
      else
        n = min(count, 1_000_000)
        whole = JS.ceil(n)

        Enum.reduce(0..(whole - 1)//1, clicks, fn i, clicks ->
          Store.insert_event(store, %{
            site: site,
            ts: start + JS.floor((i + 0.5) / n * 86_400_000),
            kind: "click",
            visitor: "",
            session: "",
            pageview: "",
            path: "/#{foreign["slug"]}",
            hostname: domain,
            title: "",
            name: foreign["slug"],
            props: JS.obj(imported: "daily"),
            engaged_ms: 0,
            scroll: nil,
            link: id
          })

          clicks + 1
        end)
      end
    end)
  end
end
