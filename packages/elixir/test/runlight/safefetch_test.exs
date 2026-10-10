defmodule Runlight.SafefetchTest do
  @moduledoc "Ports safefetch.test.ts, replays the address and icon checks in outbound.json, and covers the icon's fetches."
  use ExUnit.Case, async: true

  alias Runlight.Http.Response
  alias Runlight.Icon
  alias Runlight.Safefetch
  alias Runlight.Test.FakeFetcher
  alias Runlight.Test.Fixtures
  alias Runlight.Test.Stores

  defp instance(fetcher, now \\ 1_791_471_600_000) do
    {store, cleanup} = Stores.store(:sqlite)
    on_exit(cleanup)
    clock = :counters.new(1, [])
    :counters.put(clock, 1, now)
    {Runlight.new(store: store, fetcher: fetcher, now: fn -> :counters.get(clock, 1) end), clock}
  end

  test "only addresses on the public internet count as public" do
    for ip <- ["93.184.215.14", "1.1.1.1", "2606:4700:4700::1111", "2a00:1450:4001:82a::200e"],
        do: assert(Safefetch.public_address?(ip), ip)

    for ip <- [
          "127.0.0.1",
          "10.0.0.1",
          "172.16.5.4",
          "192.168.1.1",
          "169.254.169.254",
          "100.64.0.1",
          "0.0.0.0",
          "224.0.0.1",
          "255.255.255.255",
          "::1",
          "::",
          "fe80::1",
          "fd00::1",
          "ff02::1",
          "::ffff:127.0.0.1",
          "::ffff:7f00:1",
          "::ffff:169.254.169.254",
          "64:ff9b::a00:1",
          "2002:a00:1::",
          "2001:db8::1",
          "2001:0:4136:e378::1",
          "[::1]",
          "not an address",
          "1.2.3",
          "1.2.3.256"
        ],
        do: refute(Safefetch.public_address?(ip), ip)

    for c <- Fixtures.php("outbound.json")["ips"],
        do: assert(Safefetch.public_address?(c["ip"]) == c["public"], c["ip"])
  end

  test "a public fetch never reaches the install's own network however the address is written" do
    {fetcher, agent} = FakeFetcher.new(fn _, _ -> {:ok, Response.new("ok")} end)
    {rl, _} = instance(fetcher)

    for url <- [
          "http://127.0.0.1:1/",
          "https://127.0.0.1:1/",
          "https://[::1]:1/",
          "https://[::ffff:127.0.0.1]:1/",
          "https://localhost:1/",
          "https://LOCALHOST.:1/",
          "https://app.localhost:1/",
          "https://10.0.0.1/"
        ] do
      assert Safefetch.public_fetch(rl, url, timeout: 2000) in [{:error, :private}], url
    end

    assert FakeFetcher.requests(agent) == []
    assert Safefetch.resolves_privately?("localhost")
    refute Safefetch.resolves_privately?("name.that.does.not.resolve.invalid")
    assert Safefetch.public_addresses("name.that.does.not.resolve.invalid") == []
    assert Safefetch.public_addresses("8.8.8.8") == ["8.8.8.8"]
    assert Safefetch.public_addresses("localhost") == []
  end

  test "redirects are followed by hand under the same rules" do
    {:ok, answers} = Agent.start_link(fn -> [] end)

    hops = fn list ->
      Agent.update(answers, fn _ -> list end)

      FakeFetcher.new(fn _, _ ->
        {:ok,
         Agent.get_and_update(answers, fn
           [a | rest] -> {a, rest}
           [] -> {Response.new("end"), []}
         end)}
      end)
    end

    redirect = fn to, status -> Response.new(nil, status, [{"location", to}]) end

    {fetcher, agent} = hops.([redirect.("/next", 301), redirect.("https://1.1.1.1/last", 302), Response.new("done")])
    {rl, _} = instance(fetcher)
    {:ok, answer} = Safefetch.public_fetch(rl, "https://93.184.215.14/", timeout: 2000, redirects: 3)
    assert answer.body == "done"

    assert Enum.map(FakeFetcher.requests(agent), & &1["url"]) == [
             "https://93.184.215.14/",
             "https://93.184.215.14/next",
             "https://1.1.1.1/last"
           ]

    assert Enum.all?(FakeFetcher.inits(agent), &(&1[:redirect] == :manual))

    {fetcher, _} = hops.([redirect.("https://1.1.1.1/", 302)])
    {rl, _} = instance(fetcher)
    assert {:ok, %{status: 302}} = Safefetch.public_fetch(rl, "https://93.184.215.14/", timeout: 2000)

    for location <- ["https://10.0.0.1/", "http://1.1.1.1/", "https://[fe80::1]/", "https://localhost/"] do
      {fetcher, _} = hops.([redirect.(location, 302)])
      {rl, _} = instance(fetcher)

      assert Safefetch.public_fetch(rl, "https://93.184.215.14/", timeout: 2000, redirects: 3) == {:error, :private},
             location
    end
  end

  test "the default fetcher connects only to an address it checked" do
    # Refused before any connection: the name is resolved and checked where the connection is made.
    assert Runlight.Fetch.httpc("https://localhost:1/", public: true) == {:error, :private}
    assert Runlight.Fetch.httpc("https://127.0.0.1:1/", public: true) == {:error, :private}
    assert Runlight.Fetch.httpc("https://name.that.does.not.resolve.invalid/", public: true) == {:error, :nxdomain}
    assert Safefetch.checked_address("localhost") == {:error, :private}
    assert Safefetch.checked_address("8.8.8.8") == {:ok, "8.8.8.8"}

    {fetcher, agent} = FakeFetcher.new(fn _, _ -> {:ok, Response.new("ok")} end)
    {rl, _} = instance(fetcher)
    {:ok, _} = Safefetch.public_fetch(rl, "https://1.1.1.1/", timeout: 2000)
    assert hd(FakeFetcher.inits(agent))[:public] == true
  end

  test "addresses someone typed in are fetched only on the public internet, or this machine named outright" do
    {fetcher, agent} = FakeFetcher.new(fn _, _ -> {:ok, Response.new("ok")} end)
    {rl, _} = instance(fetcher)

    for url <- ["https://10.0.0.1/api/sites", "https://169.254.169.254/", "http://1.1.1.1/", "https://localhost/"],
        do: assert(Safefetch.fetch_entered(rl, url, timeout: 2000) == {:error, :private}, url)

    assert FakeFetcher.requests(agent) == []

    {:ok, _} = Safefetch.fetch_entered(rl, "http://127.0.0.1:4100/runlight/api/sites", timeout: 2000)
    {:ok, _} = Safefetch.fetch_entered(rl, "https://1.1.1.1/api/token", method: "POST", body: "{}", timeout: 2000)
    [local, public] = FakeFetcher.inits(agent)
    assert local[:redirect] == :manual and local[:public] == nil
    assert {public[:method], public[:body], public[:public]} == {"POST", "{}", true}
  end

  test "running out of time says so" do
    {fetcher, _} = FakeFetcher.new(fn _, _ -> {:error, :timeout} end)
    {rl, _} = instance(fetcher)
    assert Safefetch.public_fetch(rl, "https://1.1.1.1/", timeout: 2000) == {:error, :timeout}
    {fetcher, _} = FakeFetcher.new(fn _, _ -> {:error, :econnrefused} end)
    {rl, _} = instance(fetcher)
    assert Safefetch.public_fetch(rl, "https://1.1.1.1/", timeout: 2000) == {:error, :econnrefused}
  end

  test "icon links match TypeScript" do
    for c <- Fixtures.php("outbound.json")["icons"],
        do: assert(Icon.icon_links(c["html"], c["base"]) == c["links"], c["html"])
  end

  test "the best linked icon is fetched with its caps, and cached for a day" do
    {fetcher, agent} =
      FakeFetcher.new(fn url, _ ->
        {:ok,
         case url do
           "https://93.184.215.14/" ->
             Response.new(~s(<link rel="apple-touch-icon" href="/touch.png"><link rel="icon" href="/i.svg">), 200, [
               {"content-type", "text/html; charset=utf-8"}
             ])

           "https://93.184.215.14/touch.png" ->
             Response.new("<html>", 200, [{"content-type", "text/html"}])

           "https://93.184.215.14/i.svg" ->
             Response.new("<svg/>", 200, [{"content-type", "Image/SVG+xml; charset=utf-8"}])

           _ ->
             Response.new("", 404)
         end}
      end)

    {rl, clock} = instance(fetcher)
    icon = Icon.fetch_icon(rl, "https://93.184.215.14")
    assert icon == %{body: "<svg/>", type: "image/svg+xml"}

    requests = FakeFetcher.requests(agent)

    assert Enum.map(requests, & &1["url"]) == [
             "https://93.184.215.14/",
             "https://93.184.215.14/touch.png",
             "https://93.184.215.14/i.svg"
           ]

    assert hd(requests)["headers"]["user-agent"] == "Runlight (+https://runlight.sh)"
    [first, second | _] = FakeFetcher.inits(agent)
    assert {first[:max_bytes], first[:truncate]} == {200_000, true}
    assert {second[:max_bytes], second[:truncate]} == {262_144, nil}
    assert first[:timeout] <= 4000

    :counters.add(clock, 1, 86_399_000)
    assert Icon.fetch_icon(rl, "https://93.184.215.14") == icon
    assert length(FakeFetcher.requests(agent)) == 3
    :counters.add(clock, 1, 1000)
    Icon.fetch_icon(rl, "https://93.184.215.14")
    assert length(FakeFetcher.requests(agent)) == 6
  end

  test "the favicon is the fallback, no icon is remembered for an hour, and a private origin is never fetched" do
    {fetcher, agent} =
      FakeFetcher.new(fn url, _ ->
        {:ok,
         if(url == "https://1.1.1.1/favicon.ico",
           do: Response.new("", 200, [{"content-type", "image/x-icon"}]),
           else: Response.new("nope", 500)
         )}
      end)

    {rl, clock} = instance(fetcher)
    assert Icon.fetch_icon(rl, "https://1.1.1.1") == nil
    assert Enum.map(FakeFetcher.requests(agent), & &1["url"]) == ["https://1.1.1.1/", "https://1.1.1.1/favicon.ico"]
    :counters.add(clock, 1, 3_599_000)
    assert Icon.fetch_icon(rl, "https://1.1.1.1") == nil
    assert length(FakeFetcher.requests(agent)) == 2
    :counters.add(clock, 1, 1000)
    Icon.fetch_icon(rl, "https://1.1.1.1")
    assert length(FakeFetcher.requests(agent)) == 4

    {fetcher, agent} = FakeFetcher.new(fn _, _ -> {:ok, Response.new("x", 200, [{"content-type", "image/png"}])} end)
    {rl, _} = instance(fetcher)
    assert Icon.fetch_icon(rl, "https://192.168.1.1") == nil
    assert FakeFetcher.requests(agent) == []
  end
end
