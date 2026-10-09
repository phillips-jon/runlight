defmodule Runlight.VisitsImportTest do
  @moduledoc "Visit history from Umami and from CSV files, as visits-import*.test.ts and visits-csv.test.ts test it at the store."
  use ExUnit.Case, async: false

  alias Runlight.Http.Request
  alias Runlight.Http.Response
  alias Runlight.ImportError
  alias Runlight.Importers.Visits
  alias Runlight.JS
  alias Runlight.SearchParams
  alias Runlight.Store
  alias Runlight.Test.FakeFetcher
  alias Runlight.Test.Stores
  alias Runlight.Time
  alias Runlight.Url

  @credentials %{"url" => "https://umami.example.com", "apiKey" => "key"}
  @day 86_400_000

  defp at(iso), do: JS.date_parse(iso)
  defp o(pairs), do: JS.obj(pairs)

  # A small Umami: one website, events answered by time window like the real API, newest first.
  defp umami(events, sessions, created \\ "2026-03-01T08:00:00Z", newest_first \\ true) do
    FakeFetcher.new(fn url, _ ->
      parsed = Url.new(url)
      q = Url.search_params(parsed)

      body =
        cond do
          Regex.match?(~r/\/api\/websites\?/, url) ->
            o(data: [o(id: "w1", name: "Blog", domain: "blog.example.com")], count: 1)

          Regex.match?(~r/\/api\/websites\/w1$/, url) ->
            o(id: "w1", createdAt: created)

          Regex.match?(~r/\/api\/websites\/w1\/events\?/, url) ->
            from = String.to_integer(SearchParams.get(q, "startAt"))
            to = String.to_integer(SearchParams.get(q, "endAt"))
            rows = Enum.filter(events, &(at(&1["createdAt"]) >= from and at(&1["createdAt"]) <= to))
            rows = if newest_first, do: Enum.reverse(rows), else: rows
            o(data: rows, count: length(rows))

          Regex.match?(~r/\/api\/websites\/w1\/sessions\?/, url) ->
            o(data: sessions, count: length(sessions))

          true ->
            nil
        end

      {:ok,
       if(body,
         do: Response.new(JS.stringify(body), 200, [{"content-type", "application/json"}]),
         else: Response.new("{}", 404)
       )}
    end)
  end

  defp event(session, created, path, extra \\ []) do
    o([sessionId: session, createdAt: created, hostname: "blog.example.com", urlPath: path, eventType: 1] ++ extra)
  end

  defp fake_events do
    phone = [country: "CA", city: "Toronto", device: "mobile", os: "iOS", browser: "ios"]
    desk = [country: "GB", city: "London", device: "desktop", os: "Mac OS", browser: "chrome"]

    [
      # Visit 1: Google, two pages and a signup, in Toronto on a phone.
      event(
        "s1",
        "2026-03-01T10:00:00.000Z",
        "/",
        [urlQuery: "utm_campaign=spring", referrerDomain: "www.google.com", referrerPath: "/", pageTitle: "Home"] ++
          phone
      ),
      event("s1", "2026-03-01T10:02:00.000Z", "/pricing", [pageTitle: "Pricing"] ++ phone),
      o(
        [
          sessionId: "s1",
          createdAt: "2026-03-01T10:03:00.000Z",
          hostname: "blog.example.com",
          urlPath: "/pricing",
          eventType: 2,
          eventName: "Signup"
        ] ++
          phone
      ),
      # The same Umami session two hours later is a second visit.
      event("s1", "2026-03-01T12:30:00.000Z", "/blog", phone),
      # Visit 3: direct, desktop, the next day.
      event("s2", "2026-03-02T09:00:00.000Z", "/", desk),
      # A performance event is not a visit.
      o(
        [
          sessionId: "s2",
          createdAt: "2026-03-02T09:00:01.000Z",
          hostname: "blog.example.com",
          urlPath: "/",
          eventType: 5
        ] ++ desk
      )
    ]
  end

  defp sessions do
    [
      o(id: "s1", screen: "390x844", language: "en-CA", region: "CA-ON"),
      o(id: "s2", screen: "1440x900", language: "en-GB", region: "GB-ENG")
    ]
  end

  defp harness(fetcher, now, timezone \\ "UTC", kind \\ :sqlite) do
    url = Stores.kinds() |> Keyword.get(kind)
    {store, cleanup} = Stores.store(kind, url)
    on_exit(cleanup)
    clock = :counters.new(1, [])
    :counters.put(clock, 1, now)

    rl =
      Runlight.new(
        store: store,
        site: [hostnames: ["blog.example.com"], timezone: timezone],
        fetcher: fetcher,
        now: fn -> :counters.get(clock, 1) end
      )

    {rl, clock}
  end

  defp import_all(rl, credentials \\ @credentials) do
    Stream.iterate(0, & &1)
    |> Enum.reduce_while({nil, %{pageviews: 0, events: 0, visits: 0, steps: 0}}, fn _, {cursor, totals} ->
      step = Visits.import_umami_visits(rl, "default", credentials, "w1", cursor)
      assert step["done"] <= step["total"]

      totals = %{
        pageviews: totals.pageviews + step["pageviews"],
        events: totals.events + step["events"],
        visits: totals.visits + step["visits"],
        steps: totals.steps + 1
      }

      if step["cursor"] == nil, do: {:halt, totals}, else: {:cont, {step["cursor"], totals}}
    end)
  end

  defp query(rl, from, to) do
    tz = Runlight.site(rl, nil)["timezone"]
    %{site: "default", from: Time.start_of(from, tz), to: Time.start_of(Time.add_days(to, 1), tz), filters: []}
  end

  defp values(rl, q, dimension), do: rl.store |> Store.breakdown(q, dimension, 10, 0) |> Enum.map(& &1["value"])

  defp hit(rl, body, ip) do
    request =
      Request.new("https://x.com/runlight/e",
        method: "POST",
        headers: [
          {"user-agent",
           "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36"},
          {"x-forwarded-for", ip},
          {"content-type", "text/plain;charset=UTF-8"}
        ],
        body: JS.stringify(body)
      )

    Runlight.collect(rl, request)
  end

  for {kind, _} <- Stores.kinds() do
    @kind kind
    test "Umami visit history: pageviews and events become visits with sources, places, and devices (#{kind})" do
      {fetcher, agent} = umami(fake_events(), sessions())
      {rl, clock} = harness(fetcher, at("2026-03-04T00:00:00Z"), "UTC", @kind)
      assert Visits.umami_websites(rl, @credentials) == [o(id: "w1", name: "Blog", domain: "blog.example.com")]
      totals = import_all(rl)
      assert Map.take(totals, [:pageviews, :events, :visits]) == %{pageviews: 4, events: 1, visits: 3}

      for r <- FakeFetcher.requests(agent),
          do: assert(r["headers"]["authorization"] == "Bearer key", "every request carries the key")

      q = query(rl, "2026-03-01", "2026-03-03")
      stats = Store.stats(rl.store, q)
      assert {stats["pageviews"], stats["visits"], stats["visitors"]} == {4, 3, 2}
      assert stats["visitDuration"] > 0, "imported visits take their length from first to last pageview"
      assert values(rl, q, "source") == ["Google"]
      assert Enum.sort(values(rl, q, "region")) == ["CA-ON", "GB-ENG"]
      assert Enum.sort(values(rl, q, "browser")) == ["Chrome", "Safari"]
      assert values(rl, q, "event") == ["Signup"]
      assert values(rl, q, "utm_campaign") == ["spring"]

      # Running it again carries on from where it stopped, so nothing doubles.
      :counters.add(clock, 1, @day)
      assert Visits.import_umami_visits(rl, "default", @credentials, "w1", nil)["pageviews"] == 0
      assert Store.stats(rl.store, q)["pageviews"] == 4

      # No imported visitor id lasts past a day.
      days =
        rl.store
        |> Store.all_rows("SELECT visitor, ts FROM rl_events", [])
        |> Enum.group_by(& &1["visitor"], &JS.iso_day(JS.number(&1["ts"])))

      for {_, list} <- days, do: assert(length(Enum.uniq(list)) == 1)
    end

    test "an imported visit that runs past midnight keeps one visitor on all its rows (#{kind})" do
      ev = fn session, iso, path, name ->
        o(
          [
            sessionId: session,
            createdAt: iso,
            hostname: "blog.example.com",
            urlPath: path,
            eventType: if(name, do: 2, else: 1)
          ] ++
            if(name, do: [eventName: name], else: [])
        )
      end

      events = [
        ev.("s1", "2026-03-01T23:50:00.000Z", "/a", nil),
        ev.("s1", "2026-03-02T00:05:00.000Z", "/b", nil),
        ev.("s1", "2026-03-02T00:06:00.000Z", "/b", "Signup"),
        ev.("s1", "2026-03-02T10:00:00.000Z", "/b", nil),
        ev.("s1", "2026-03-02T10:01:00.000Z", "/b", "Signup")
      ]

      {fetcher, _} = umami(events, [], "2026-03-01T00:00:00.000Z")
      {rl, _} = harness(fetcher, at("2026-03-05T12:00:00Z"), "UTC", @kind)
      import_all(rl)

      assert Store.all_rows(
               rl.store,
               "SELECT e.id FROM rl_events e JOIN rl_sessions s ON s.id = e.session WHERE e.visitor <> s.visitor",
               []
             ) == []

      q = query(rl, "2026-03-01", "2026-03-02")

      read = fn ->
        {Enum.map(Store.breakdown(rl.store, q, "page", 10, 0), &{&1["value"], &1["visitors"]}),
         Enum.map(Store.breakdown(rl.store, q, "event", 10, 0), &{&1["value"], &1["visitors"]})}
      end

      raw = read.()
      build_all(rl)
      assert read.() == raw, "the same before and after the days are built"
      assert elem(raw, 1) == [{"Signup", 2}]
    end
  end

  defp build_all(rl), do: if(Runlight.build_rollups(rl) > 0, do: build_all(rl), else: :ok)

  test "Umami visit history stops where Runlight's own visits begin" do
    {fetcher, _} = umami(fake_events(), sessions())
    {rl, _} = harness(fetcher, at("2026-03-01T23:00:00Z"))
    # Runlight started counting on the evening of March 1st.
    hit(rl, o(k: "pageview", u: "https://blog.example.com/"), "203.0.113.9")
    assert import_all(rl).pageviews == 3, "March 2nd is left to Runlight"
  end

  test "Umami visit history skips days older than the site keeps" do
    {fetcher, _} = umami(fake_events(), sessions())
    {rl, _} = harness(fetcher, at("2026-09-01T12:00:00Z"))
    Runlight.init(rl)
    # Six months back from September 1st at noon is March 1st at noon, so March 1st is left out.
    Runlight.set_retention(rl, "default", 6)
    Runlight.idle(rl)
    assert import_all(rl).pageviews == 1, "only March 2nd comes in"
  end

  test "an imported visit across UTC midnight is one visit on the site's own day" do
    base = [
      hostname: "blog.example.com",
      eventType: 1,
      country: "CA",
      device: "desktop",
      os: "Mac OS",
      browser: "chrome"
    ]

    events = [
      o([sessionId: "n1", createdAt: "2026-03-02T23:55:00.000Z", urlPath: "/"] ++ base),
      o([sessionId: "n1", createdAt: "2026-03-03T00:05:00.000Z", urlPath: "/about"] ++ base)
    ]

    {fetcher, _} = umami(events, [o(id: "n1")], "2026-03-02T00:00:00Z", false)
    {rl, _} = harness(fetcher, at("2026-03-10T00:00:00Z"), "America/Toronto")
    import_all(rl)
    stats = Store.stats(rl.store, query(rl, "2026-03-02", "2026-03-02"))
    assert {stats["visits"], stats["visitors"], stats["pageviews"]} == {1, 1, 2}
  end

  test "a visit that crosses into the next import step has its first day built again" do
    ev = fn session, iso, path -> event(session, iso, path) end

    events = [
      ev.("s0", "2026-03-02T10:00:00.000Z", "/"),
      ev.("s1", "2026-03-14T23:50:00.000Z", "/a"),
      ev.("s1", "2026-03-15T00:10:00.000Z", "/b"),
      ev.("s2", "2026-03-20T10:00:00.000Z", "/")
    ]

    {fetcher, _} = umami(events, [], "2026-03-01T00:00:00.000Z")
    {rl, _} = harness(fetcher, at("2026-03-25T12:00:00Z"))
    cursor = Visits.import_umami_visits(rl, "default", @credentials, "w1", nil)["cursor"]
    cursor_after = JS.parse!(cursor)
    assert JS.Object.keys(cursor_after) == ["website", "day", "start", "end"]
    assert cursor_after["day"] == at("2026-03-15T00:00:00Z"), "fourteen days a step"
    # The scheduled check builds days between two steps.
    build_all(rl)
    finish = fn f, c -> if c, do: f.(f, Visits.import_umami_visits(rl, "default", @credentials, "w1", c)["cursor"]) end
    finish.(finish, cursor)
    build_all(rl)
    q = query(rl, "2026-03-14", "2026-03-14")

    read = fn ->
      {Store.stats(rl.store, q), Enum.map(Store.breakdown(rl.store, q, "page", 10, 0), &{&1["value"], &1["pageviews"]})}
    end

    rolled = read.()
    Store.clear_rollups(rl.store, "default")
    assert read.() == rolled
    assert elem(rolled, 0)["pageviews"] == 2

    error = assert_raise ImportError, fn -> Visits.import_umami_visits(rl, "default", @credentials, "w/1", nil) end
    assert error.code == "import_website"
  end

  ## CSV

  @runlight_rows [
    [
      time: "2026-03-01T10:00:00Z",
      url: "https://blog.example.com/?utm_campaign=spring",
      referrer: "www.google.com",
      visitor: "a",
      country: "CA",
      region: "CA-ON",
      city: "Toronto",
      browser: "Safari",
      os: "iOS",
      device: "mobile",
      title: "Home"
    ],
    [
      time: "2026-03-01T10:02:00Z",
      url: "https://blog.example.com/pricing",
      visitor: "a",
      country: "CA",
      browser: "Safari",
      os: "iOS",
      device: "mobile"
    ],
    [time: "2026-03-01T10:03:00Z", url: "https://blog.example.com/pricing", event: "Signup", visitor: "a"],
    [
      time: "1772442000",
      path: "/",
      hostname: "blog.example.com",
      visitor: "b",
      country: "GB",
      browser: "Chrome",
      os: "macOS",
      device: "desktop"
    ],
    # Not a time at all.
    [time: "yesterday", path: "/x", visitor: "c"]
  ]

  defp rows, do: Enum.map(@runlight_rows, &o/1)

  defp csv(now \\ nil) do
    {fetcher, _} = FakeFetcher.new(fn _, _ -> {:error, :none} end)
    {rl, _} = harness(fetcher, now || at("2026-03-04T00:00:00Z"))
    rl
  end

  test "CSV in Runlight's format: rows become visits with sources, places, devices, and events" do
    rl = csv()
    assert Visits.import_csv_visits(rl, "default", rows()) == o(pageviews: 3, events: 1, visits: 2, skipped: 1)
    q = query(rl, "2026-03-01", "2026-03-03")
    stats = Store.stats(rl.store, q)
    assert {stats["pageviews"], stats["visits"], stats["visitors"]} == {3, 2, 2}
    assert values(rl, q, "source") == ["Google"]
    assert values(rl, q, "utm_campaign") == ["spring"]
    assert values(rl, q, "event") == ["Signup"]
    assert Enum.sort(values(rl, q, "device")) == ["desktop", "mobile"]
    assert values(rl, q, "region") == ["CA-ON"]
    # The same file again replaces what it brought in, so nothing doubles.
    Visits.import_csv_visits(rl, "default", rows())
    assert {Store.stats(rl.store, q)["pageviews"], Store.stats(rl.store, q)["visits"]} == {3, 2}
  end

  test "CSV in Runlight's format without a visitor column: every row is its own visit" do
    rl = csv()
    list = [o(time: "2026-03-01 10:00:00", path: "/a"), o(time: "2026-03-01 10:01:00", path: "/b?ref=x")]
    assert Visits.import_csv_visits(rl, "default", list)["visits"] == 2
    Visits.import_csv_visits(rl, "default", list)
    q = query(rl, "2026-03-01", "2026-03-03")
    assert Store.stats(rl.store, q)["visits"] == 2, "the same rows get the same ids the second time"
    assert Enum.sort(values(rl, q, "page")) == ["/a", "/b"]
  end

  test "CSV from Umami's export: pageviews and named events come across, other event types do not" do
    rl = csv()

    list = [
      o(
        website_id: "w1",
        session_id: "s1",
        created_at: "2026-03-01 10:00:00",
        hostname: "blog.example.com",
        url_path: "/",
        url_query: "",
        referrer_domain: "news.ycombinator.com",
        page_title: "Home",
        event_type: "1",
        country: "CA",
        subdivision1: "ON",
        city: "Toronto",
        browser: "ios",
        os: "iOS",
        device: "mobile",
        screen: "390x844",
        language: "en-CA"
      ),
      o(
        website_id: "w1",
        session_id: "s1",
        created_at: "2026-03-01 10:03:00",
        hostname: "blog.example.com",
        url_path: "/pricing",
        event_type: "2",
        event_name: "Signup"
      ),
      o(
        website_id: "w1",
        session_id: "s1",
        created_at: "2026-03-01 10:03:01",
        hostname: "blog.example.com",
        url_path: "/pricing",
        event_type: "5"
      ),
      o(
        website_id: "w1",
        session_id: "s2",
        created_at: "2026-03-02T09:00:00.000Z",
        hostname: "blog.example.com",
        url_path: "/blog",
        event_type: "1",
        country: "GB",
        browser: "chrome",
        os: "Mac OS",
        device: "desktop"
      )
    ]

    assert Visits.import_csv_visits(rl, "default", list) == o(pageviews: 2, events: 1, visits: 2, skipped: 1)
    q = query(rl, "2026-03-01", "2026-03-03")
    assert values(rl, q, "source") == ["Hacker News"]
    assert values(rl, q, "region") == ["CA-ON"]
    assert Enum.sort(values(rl, q, "browser")) == ["Chrome", "Safari"]
  end

  test "CSV rows from after Runlight's own first visit are left to Runlight" do
    rl = csv(at("2026-03-01T23:00:00Z"))
    hit(rl, o(k: "pageview", u: "https://blog.example.com/"), "203.0.113.9")
    step = Visits.import_csv_visits(rl, "default", Enum.take(rows(), 4))
    assert {step["pageviews"], step["skipped"]} == {2, 1}
  end

  test "a CSV it cannot read and a batch that is too big are refused" do
    rl = csv()

    for {list, code} <- [
          {[o(date: "2026-03-01", visitors: "12")], "import_csv_format"},
          {List.duplicate(hd(rows()), 2001), "import_csv_batch"},
          {"not rows", "import_csv_batch"}
        ] do
      error = assert_raise ImportError, fn -> Visits.import_csv_visits(rl, "default", list) end
      assert error.code == code
    end

    assert Visits.import_csv_visits(rl, "default", rows())["visits"] == 2
  end

  test "CSV times and formats" do
    assert Visits.csv_format(["created_at", "url_path", "session_id"]) == "umami"
    assert Visits.csv_format(["time", "url"]) == "runlight"
    assert Visits.csv_format(["date", "visitors"]) == nil
    iso = at("2026-03-01T10:00:00Z")
    assert Visits.row_time(%{"time" => "2026-03-01 10:00:00"}, "runlight") == iso, "no zone reads as UTC"
    assert Visits.row_time(%{"time" => "2026-03-01T12:00:00+02:00"}, "runlight") == iso
    assert Visits.row_time(%{"time" => Integer.to_string(div(iso, 1000))}, "runlight") == iso, "Unix seconds"
    assert Visits.row_time(%{"time" => Integer.to_string(iso)}, "runlight") == iso, "Unix milliseconds"
    assert Visits.row_time(%{"created_at" => "2026-03-01 10:00:00"}, "umami") == iso
    assert Visits.row_time(%{"time" => ""}, "runlight") == :nan
    assert Visits.row_time(%{"time" => "yesterday"}, "runlight") == :nan
  end
end
