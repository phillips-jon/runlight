defmodule Runlight.ImportStepTest do
  @moduledoc "Link imports written into the store, as importers.test.ts tests them."
  use ExUnit.Case, async: true

  alias Runlight.Http.Response
  alias Runlight.ImportError
  alias Runlight.Importers
  alias Runlight.JS
  alias Runlight.Links
  alias Runlight.Store
  alias Runlight.Test.FakeFetcher
  alias Runlight.Test.Stores

  @now 1_791_288_000_000

  setup do
    Process.put(:runlight_pause, fn _ -> :ok end)
    :ok
  end

  # A fetcher answering the first route whose pattern matches; a route answers a body, or {status, body}.
  defp router(routes) do
    FakeFetcher.new(fn url, opts ->
      case Enum.find(routes, fn {pattern, _} -> Regex.match?(pattern, url) end) do
        nil ->
          {:ok, Response.new("{}", 404)}

        {_, answer} ->
          {status, body} =
            case answer.(url, opts) do
              {status, body} when is_integer(status) -> {status, body}
              body -> {200, body}
            end

          {:ok, Response.new(JS.stringify(body), status, [{"content-type", "application/json"}])}
      end
    end)
  end

  defp runlight(fetcher) do
    {store, cleanup} = Stores.store(:sqlite)
    on_exit(cleanup)
    Runlight.new(store: store, fetcher: fetcher, now: fn -> @now end)
  end

  defp run_all(fetcher, source, credentials) do
    rl = runlight(fetcher)

    totals =
      Stream.iterate(0, & &1)
      |> Enum.reduce_while({nil, 0, %{links: 0, clicks: 0, skipped: 0, failed: []}}, fn _, {cursor, done, totals} ->
        step = Importers.import_step(rl, "default", source, credentials, cursor, done)

        totals = %{
          links: totals.links + step["links"],
          clicks: totals.clicks + step["clicks"],
          skipped: totals.skipped + step["skipped"],
          failed: totals.failed ++ step["failed"]
        }

        if step["cursor"] == nil, do: {:halt, totals}, else: {:cont, {step["cursor"], step["done"], totals}}
      end)

    {rl, totals}
  end

  defp links(rl), do: Store.links(rl.store, "default", 0, @now + 1)
  defp rows(rl, sql), do: Store.all_rows(rl.store, sql, [])

  defp o(pairs), do: JS.obj(pairs)

  test "Dub: every click where the plan allows" do
    {fetcher, _} =
      router([
        {~r/api\.dub\.co\/links\?.*startingAfter=l2/, fn _, _ -> [] end},
        {~r/api\.dub\.co\/links\?/,
         fn _, _ ->
           [
             o(
               id: "l1",
               domain: "dub.sh",
               key: "launch",
               url: "https://a.com/launch",
               title: "Launch",
               createdAt: "2026-01-02T00:00:00Z"
             ),
             o(
               id: "l2",
               domain: "go.brand.com",
               key: "sale",
               url: "https://a.com/sale",
               title: nil,
               createdAt: "2026-02-03T00:00:00Z"
             )
           ]
         end},
        {~r/\/events\?.*linkId=l1/,
         fn _, _ ->
           [
             o(
               timestamp: "2026-03-01T10:00:00Z",
               click:
                 o(
                   id: "c1",
                   country: "CA",
                   city: "Toronto",
                   device: "Mobile",
                   browser: "Chrome",
                   os: "iOS",
                   referer: "instagram.com",
                   refererUrl: "https://instagram.com/"
                 )
             ),
             o(
               timestamp: "2026-03-02T10:00:00Z",
               click:
                 o(id: "c2", country: "US", device: "Desktop", browser: "Safari", os: "Mac OS", referer: "(direct)")
             )
           ]
         end},
        {~r/\/events\?.*linkId=l2/, fn _, _ -> [] end}
      ])

    {rl, totals} = run_all(fetcher, "dub", %{"apiKey" => "dub_test"})
    assert {totals.links, totals.clicks} == {2, 2}
    by_slug = Map.new(links(rl), &{&1["slug"], &1})
    assert by_slug["launch"]["domain"] == "", "dub.sh stays behind; the link moves to /go"
    assert by_slug["sale"]["domain"] == "go.brand.com", "branded domains come across"
    assert Store.link_domains(rl.store) == [o(domain: "go.brand.com", site: "default")]
    [session] = rows(rl, "SELECT country, source, device FROM rl_sessions ORDER BY started_at LIMIT 1")
    assert session == o(country: "CA", source: "Instagram", device: "mobile")
    assert hd(rows(rl, "SELECT imported FROM rl_sessions LIMIT 1"))["imported"] == 1
  end

  test "Dub: daily counts when the plan has no events API" do
    {fetcher, _} =
      router([
        {~r/api\.dub\.co\/links\?/,
         fn _, _ ->
           [
             o(
               id: "l1",
               domain: "dub.sh",
               key: "x",
               url: "https://a.com",
               title: "X",
               createdAt: "2026-01-02T00:00:00Z"
             )
           ]
         end},
        {~r/\/events\?/, fn _, _ -> {403, o(error: o(message: "Business plan required"))} end},
        {~r/\/analytics\?/,
         fn _, _ ->
           [o(start: "2026-03-01T00:00:00.000Z", clicks: 3), o(start: "2026-03-02T00:00:00.000Z", clicks: 0)]
         end}
      ])

    {rl, totals} = run_all(fetcher, "dub", %{"apiKey" => "dub_test"})
    assert totals.clicks == 3
    [row] = links(rl)
    assert {row["clicks"], row["visitors"]} == {3, 0}, "daily counts add clicks, not made-up visitors"
    times = rl |> rows("SELECT ts FROM rl_events ORDER BY ts") |> Enum.map(& &1["ts"])
    day = 1_772_323_200_000
    assert times == [day + 14_400_000, day + 43_200_000, day + 72_000_000], "spread through the day"
  end

  test "Bitly: every group, custom back-halves, daily counts" do
    {fetcher, _} =
      router([
        {~r/\/v4\/groups$/, fn _, _ -> o(groups: [o(guid: "G1"), o(guid: "G2")]) end},
        {~r/\/groups\/G1\/bitlinks/,
         fn _, _ ->
           o(
             links: [
               o(
                 id: "bit.ly/3abc",
                 link: "https://bit.ly/3abc",
                 long_url: "https://a.com/1",
                 title: "One",
                 created_at: "2026-01-01T00:00:00+0000",
                 custom_bitlinks: ["https://t.brand.com/one"]
               ),
               o(
                 id: "bit.ly/gone",
                 link: "https://bit.ly/gone",
                 long_url: "https://a.com/x",
                 title: "Gone",
                 created_at: "2026-01-01T00:00:00+0000",
                 is_deleted: true
               )
             ],
             pagination: o(search_after: "")
           )
         end},
        {~r/\/groups\/G2\/bitlinks/,
         fn _, _ ->
           o(
             links: [
               o(
                 id: "bit.ly/4def",
                 link: "https://bit.ly/4def",
                 long_url: "https://a.com/2",
                 title: nil,
                 created_at: "2026-02-01T00:00:00+0000"
               )
             ],
             pagination: o([])
           )
         end},
        {~r/\/bitlinks\/bit\.ly%2F3abc\/clicks/,
         fn _, _ ->
           o(
             link_clicks: [
               o(clicks: 5, date: "2026-03-01T00:00:00+0000"),
               o(clicks: 2, date: "2026-03-02T00:00:00+0000")
             ]
           )
         end},
        {~r/\/bitlinks\/bit\.ly%2F4def\/clicks/, fn _, _ -> {402, o(message: "UPGRADE_REQUIRED")} end}
      ])

    {rl, totals} = run_all(fetcher, "bitly", %{"token" => "bitly_test"})
    assert totals.links == 2, "the deleted link is skipped"
    assert totals.clicks == 7
    pairs = rl |> links() |> Enum.map(&{&1["domain"], &1["slug"]}) |> Enum.sort()
    assert pairs == [{"", "4def"}, {"t.brand.com", "one"}]
  end

  test "Short.io: every domain, paged, with daily counts in either shape" do
    {fetcher, _} =
      router([
        {~r/api\.short\.io\/api\/domains/, fn _, _ -> [o(id: 7, hostname: "s.brand.com")] end},
        {~r/api\/links\?.*pageToken=P2/,
         fn _, _ ->
           o(
             links: [
               o(
                 idString: "lnk2",
                 id: 2,
                 path: "two",
                 originalURL: "https://a.com/2",
                 createdAt: "2026-02-01T00:00:00Z"
               )
             ],
             nextPageToken: nil
           )
         end},
        {~r/api\/links\?domain_id=7/,
         fn _, _ ->
           o(
             links: [
               o(
                 idString: "lnk1",
                 id: 1,
                 path: "one",
                 originalURL: "https://a.com/1",
                 title: "One",
                 createdAt: "2026-01-01T00:00:00Z"
               )
             ],
             nextPageToken: "P2"
           )
         end},
        {~r/statistics\/link\/lnk1\/by_interval/,
         fn _, _ -> o(clickStatistics: [o(x: "2026-03-01T00:00:00Z", y: 4)]) end},
        {~r/statistics\/link\/lnk2\/by_interval/,
         fn _, _ -> o(clickStatistics: o(datasets: [o(data: [o(x: 1_772_409_600_000, y: 1)])])) end}
      ])

    {_rl, totals} = run_all(fetcher, "shortio", %{"apiKey" => "sk_test"})
    assert {totals.links, totals.clicks} == {2, 5}
  end

  test "Rebrandly: links only, paged by the last id" do
    page = fn from, n ->
      for i <- from..(from + n - 1),
          do:
            o(
              id: "r#{i}",
              slashtag: "s#{i}",
              destination: "https://a.com/#{i}",
              domain: o(fullName: "rebrand.ly"),
              createdAt: "2026-01-01T00:00:00Z"
            )
    end

    {fetcher, _} =
      router([
        {~r/\/links\?.*last=r24/, fn _, _ -> page.(25, 3) end},
        {~r/rebrandly\.com\/v1\/links\?/, fn _, _ -> page.(0, 25) end}
      ])

    {rl, totals} = run_all(fetcher, "rebrandly", %{"apiKey" => "rb_test"})
    assert {totals.links, totals.clicks} == {28, 0}
    assert hd(links(rl))["domain"] == "", "rebrand.ly stays behind"
  end

  test "Umami signs in with a username and password, and a re-run skips what is there" do
    {fetcher, agent} =
      router([
        {~r/\/api\/auth\/login/,
         fn _, opts -> if JS.parse!(opts[:body])["password"] == "pw", do: o(token: "tok"), else: o([]) end},
        {~r/\/api\/links\?/,
         fn _, _ ->
           o(
             data: [
               o(
                 id: "u-1",
                 name: "Golden",
                 url: "https://a.com",
                 slug: "golden",
                 createdAt: "2026-01-01T00:00:00Z",
                 deletedAt: nil,
                 customDomain: o(domain: "t.brand.com")
               )
             ],
             count: 1
           )
         end},
        {~r/\/websites\/u-1\/events/,
         fn _, _ ->
           o(
             data: [
               o(
                 sessionId: "s1",
                 createdAt: "2026-03-01T00:00:00Z",
                 urlPath: "/golden",
                 urlQuery: "utm_source=newsletter",
                 referrerDomain: "",
                 referrerPath: "",
                 country: "GB",
                 city: "London",
                 device: "mobile",
                 os: "iOS",
                 browser: "ios"
               )
             ],
             count: 1
           )
         end},
        {~r/\/websites\/u-1\/sessions/,
         fn _, _ -> o(data: [o(id: "s1", screen: "390x844", language: "en-GB", region: "ENG")], count: 1) end}
      ])

    rl = runlight(fetcher)
    creds = %{"url" => "https://stats.example.com/", "username" => "jon", "password" => "pw"}
    first = Importers.import_step(rl, "default", "umami", creds, nil, 0)
    assert {first["links"], first["clicks"]} == {1, 1}
    login = hd(FakeFetcher.requests(agent))
    assert {login["method"], login["url"]} == {"POST", "https://stats.example.com/api/auth/login"}

    assert rows(rl, "SELECT region, source, browser FROM rl_sessions") == [
             o(region: "GB-ENG", source: "Newsletter", browser: "Safari")
           ]

    assert Importers.import_step(rl, "default", "umami", creds, nil, 0)["skipped"] == 1

    error =
      assert_raise ImportError, fn -> Importers.import_step(rl, "default", "umami", %{"url" => "nope"}, nil, 0) end

    assert error.message =~ "Umami address"
    error = assert_raise ImportError, fn -> Importers.import_step(rl, "default", "nowhere", %{}, nil, 0) end
    assert error.message =~ "cannot import"
    assert error.params == %{"source" => "nowhere"}
  end

  test "Umami: a link already here with the same slug and destination is skipped before its history is fetched" do
    {fetcher, agent} =
      router([
        {~r/\/api\/links\?/,
         fn _, _ ->
           o(
             data: [
               o(
                 id: "u-9",
                 name: "Golden",
                 url: "https://a.com/",
                 slug: "golden",
                 createdAt: "2026-01-01T00:00:00Z",
                 deletedAt: nil
               )
             ],
             count: 1
           )
         end},
        {~r/\/websites\/u-9\//, fn _, _ -> o(data: [], count: 0) end}
      ])

    rl = runlight(fetcher)
    Runlight.init(rl)
    # Brought in earlier some other way, such as a CSV, so it has no Umami id.
    Links.create(rl, "default", %{"url" => "https://a.com", "slug" => "golden", "name" => "Golden"})

    step =
      Importers.import_step(rl, "default", "umami", %{"url" => "https://stats.example.com/", "apiKey" => "k"}, nil, 0)

    assert {step["skipped"], step["links"]} == {1, 0}

    refute Enum.any?(FakeFetcher.requests(agent), &String.contains?(&1["url"], "/websites/u-9/")),
           "no history was fetched for it"
  end

  test "a link whose slug is taken or unusable is reported with a code" do
    {fetcher, _} = router([])
    rl = runlight(fetcher)
    Runlight.init(rl)
    Links.create(rl, "default", %{"url" => "https://elsewhere.com", "slug" => "taken", "name" => "Other"})

    foreign = fn pairs ->
      o([sourceId: "x", slug: "x", domain: "", name: "", url: "https://a.com", createdAt: 0] |> Keyword.merge(pairs))
    end

    taken = Importers.write_link(rl, "default", "dub", foreign.(sourceId: "x", slug: "taken", name: "X"), o([]))

    assert taken == %{
             status: "failed",
             clicks: 0,
             reason: ~s(/taken is already used by "Other"),
             code: "import_slug_taken",
             params: %{"slug" => "taken", "name" => "Other"}
           }

    assert Importers.write_link(rl, "default", "dub", foreign.(sourceId: "y", slug: "a/b"), o([])).code ==
             "import_slug_bad"

    made =
      Importers.write_link(
        rl,
        "default",
        "dub",
        foreign.(sourceId: "z", slug: "fine", domain: "www.Go.Brand.com", url: "https://a.com/z"),
        o(clicks: [o(ts: 5_000, visit: "v", path: "/fine", query: "?utm_campaign=c")])
      )

    assert made == %{status: "created", clicks: 1}
    link = Store.link_by_slug(rl.store, "fine")

    assert {link["domain"], link["name"], link["id"]} ==
             {"go.brand.com", "fine", Importers.imported_link_id("dub", "z")}

    assert hd(rows(rl, "SELECT utm_campaign FROM rl_sessions"))["utm_campaign"] == "c"

    assert Importers.write_link(
             rl,
             "default",
             "dub",
             foreign.(sourceId: "z", slug: "fine", url: "https://a.com/z"),
             o([])
           ) ==
             %{status: "skipped", clicks: 0}
  end
end
