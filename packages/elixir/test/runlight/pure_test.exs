defmodule Runlight.PureTest do
  @moduledoc """
  The pure modules against the fixtures written from the TypeScript SDK:
  conformance/url.json and ua.json, and the PHP port's sources, query,
  payload, time, journeys, zip, goals, geo, and messages fixtures.
  """
  use ExUnit.Case, async: true

  alias Runlight.Geo
  alias Runlight.Goals
  alias Runlight.Http.Headers
  alias Runlight.Journeys
  alias Runlight.JS
  alias Runlight.JS.Object
  alias Runlight.Messages
  alias Runlight.Payload
  alias Runlight.Query
  alias Runlight.SearchParams
  alias Runlight.Sources
  alias Runlight.Test.Fixtures
  alias Runlight.Time
  alias Runlight.Ua
  alias Runlight.Url
  alias Runlight.Zip

  defp url_parts(nil), do: nil

  defp url_parts(%Url{} = u) do
    JS.obj(
      href: Url.href(u),
      protocol: u.protocol,
      username: u.username,
      password: u.password,
      hostname: u.hostname,
      port: u.port,
      host: Url.host(u),
      origin: Url.origin(u),
      pathname: u.pathname,
      search: u.search,
      hash: u.hash
    )
  end

  defp canon(v), do: JS.stringify(sorted(v))

  defp sorted(%Object{} = o),
    do: o |> Object.to_list() |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {k, v} -> {k, sorted(v)} end) |> Object.new()

  defp sorted(list) when is_list(list), do: Enum.map(list, &sorted/1)

  defp sorted(%{} = m) when not is_struct(m),
    do: m |> Enum.map(fn {k, v} -> {to_string(k), sorted(v)} end) |> sorted_pairs()

  defp sorted(v), do: v

  defp sorted_pairs(pairs), do: pairs |> Enum.sort_by(&elem(&1, 0)) |> Object.new()

  test "urls read as JavaScript reads them" do
    file = Fixtures.conformance("url.json")

    for c <- file["urls"] ++ file["relative"] do
      got = url_parts(Url.parse(c["input"], c["base"]))
      assert canon(got) == canon(c["expect"]), "#{inspect(c["input"])} with #{inspect(c["base"])}"
    end

    for c <- file["queries"] do
      params = SearchParams.parse(c["input"])
      assert Enum.map(params, &Tuple.to_list/1) == c["pairs"], c["input"]
      assert SearchParams.to_string(params) == c["string"], c["input"]
    end

    for c <- file["written"] do
      assert SearchParams.to_string(Enum.map(c["pairs"], &List.to_tuple/1)) == c["string"]
    end

    for c <- file["numbers"] do
      assert JS.format_number(c["n"]) == c["text"], inspect(c["n"])
    end
  end

  test "user agents" do
    for c <- Fixtures.conformance("ua.json")["cases"] do
      ua = c["ua"]

      if Object.has_key?(c, "client") do
        hints = %{brands: c["hints"]["brands"], mobile: c["hints"]["mobile"], platform: c["hints"]["platform"]}
        got = Ua.parse_client(ua, if(c["hints"], do: hints, else: %{}), c["screenWidth"])

        assert JS.obj(
                 browser: got.browser,
                 browserVersion: got.browser_version,
                 os: got.os,
                 osVersion: got.os_version,
                 device: got.device
               ) == c["client"],
               ua
      end

      if Object.has_key?(c, "bot"), do: assert(Ua.bot?(ua) == c["bot"], ua)

      if Object.has_key?(c, "agent") do
        agent = Ua.ai_agent(ua)
        assert (agent && JS.obj(name: agent.name, kind: agent.kind)) == c["agent"], ua
      end
    end
  end

  defp source_obj(nil), do: nil

  defp source_obj(s),
    do:
      JS.obj(
        name: s.name,
        kind: s.kind,
        hosts: s.hosts,
        aliases: if(s.aliases == [] and s.hosts == [], do: :undefined, else: s.aliases)
      )

  test "sources and attribution" do
    f = Fixtures.php("sources.json")

    for c <- f["hosts"] do
      got = Sources.source_for_host(c["host"])
      want = c["source"]
      assert (got && got.name) == (want && want["name"]), c["host"]
      assert (got && got.kind) == (want && want["kind"]), c["host"]
    end

    for c <- f["aliases"] do
      got = Sources.source_for_alias(c["alias"])
      want = c["source"]
      assert (got && got.name) == (want && want["name"]), c["alias"]
    end

    for c <- f["pages"] do
      p = Sources.parse_page(Url.new(c["url"]))

      got =
        JS.obj(
          hostname: p.hostname,
          path: p.path,
          utm:
            JS.obj(
              source: p.utm.source,
              medium: p.utm.medium,
              campaign: p.utm.campaign,
              term: p.utm.term,
              content: p.utm.content
            ),
          ref: p.ref,
          paid: p.paid
        )

      assert got == c["page"], c["url"]
    end

    for c <- f["visits"] do
      a = Sources.attribute(Sources.parse_page(Url.new(c["url"])), c["referrer"], c["internal"])
      got = JS.obj(referrerHost: a.referrer_host, referrerPath: a.referrer_path, source: a.source, channel: a.channel)
      assert got == c["attribution"], "#{c["url"]} from #{c["referrer"]}"
    end

    for c <- f["recordedPaths"], do: assert(Sources.recorded_path(c["input"]) == c["path"], inspect(c["input"]))
    for c <- f["readablePaths"], do: assert(Sources.readable_path(c["input"]) == c["path"], inspect(c["input"]))
    for c <- f["stripWww"], do: assert(Sources.strip_www(c["input"]) == c["host"])
    _ = &source_obj/1
  end

  test "query dimensions and filters" do
    f = Fixtures.php("query.json")
    assert Query.dimensions() == f["dimensions"]
    assert Query.max_filters() == f["maxFilters"]
    assert Object.to_list(f["eventDimensions"]) == Query.event_dimensions()
    assert Object.to_list(f["sessionDimensions"]) == Query.session_dimensions()

    for c <- f["dimensionTests"] do
      assert Query.dimension?(c["value"]) == c["isDimension"]
      assert Query.session_dimension?(c["value"]) == c["isSessionDimension"]
      assert Query.event_dimension?(c["value"]) == c["isEventDimension"]
    end

    for c <- f["filters"] do
      got = Query.parse_filter(c["text"])
      want = c["filter"]
      assert (got && JS.obj(dimension: got.dimension, op: got.op, value: got.value)) == want, c["text"]
    end
  end

  test "tracker payloads" do
    f = Fixtures.php("payload.json")
    assert Payload.max_body() == f["maxBody"]

    for c <- f["cases"] do
      got = Payload.parse(c["text"])

      got =
        got &&
          JS.obj(
            kind: got.kind,
            site: got.site,
            url: Url.href(got.url),
            referrer: got.referrer,
            title: got.title,
            screenWidth: got.screen_width,
            screenHeight: got.screen_height,
            language: got.language,
            name: got.name,
            props: got.props && JS.stringify(got.props),
            pageviewId: got.pageview_id,
            engagedMs: got.engaged_ms,
            scroll: got.scroll
          )

      assert canon(got) == canon(c["payload"]), c["text"]
    end
  end

  defp range_obj(nil), do: nil

  defp range_obj(r),
    do: JS.obj(from: r.from, to: r.to, fromDate: r.from_date, toDate: r.to_date, interval: r.interval)

  defp input_map(%Object{} = o), do: Map.new(Object.to_list(o), fn {k, v} -> {String.to_atom(k), v} end)

  # The fixture came from Node's ICU with time zone data 2025c; tz carries newer data, where Morocco and
  # British Columbia (and the Mountain zones that follow Alberta) changed their rules since.
  defp changed_zones,
    do:
      ~w(Africa/Casablanca Africa/El_Aaiun America/Vancouver Canada/Pacific America/Edmonton America/Inuvik America/Yellowknife Canada/Mountain)

  test "zones" do
    f = Fixtures.php("time.json")
    since1970 = f["sampleTimes"] |> Enum.with_index() |> Enum.filter(fn {ts, _} -> ts >= 0 end)
    system_v = ~w(systemv/ast4adt systemv/est5edt systemv/cst6cdt systemv/mst7mdt systemv/pst8pdt systemv/yst9ydt)
    changed = changed_zones()

    failures =
      for zone <- f["zones"],
          valid = Time.timezone?(zone["name"]),
          failure <-
            (cond do
               valid != zone["valid"] ->
                 ["#{zone["name"]} #{if valid, do: "taken", else: "refused"}"]

               not valid or String.downcase(zone["name"]) in system_v or zone["name"] in changed ->
                 []

               true ->
                 for {ts, i} <- since1970,
                     {wd, h} = Time.local_weekday_hour(ts, zone["name"]),
                     local = "#{Time.local_date(ts, zone["name"])} #{wd} #{h}",
                     local != Enum.at(zone["local"], i),
                     do: "#{zone["name"]} at #{ts}: #{local} not #{Enum.at(zone["local"], i)}"
             end),
          do: failure

    assert Enum.take(failures, 30) == []
  end

  test "instants and day starts" do
    f = Fixtures.php("time.json")

    changed = changed_zones()

    failures =
      for [zone, ts, date, weekday, hour] <- f["instants"],
          zone not in changed,
          {wd, h} = Time.local_weekday_hour(ts, zone),
          got = [Time.local_date(ts, zone), wd, h],
          got != [date, weekday, hour],
          do: "#{zone} #{ts}: #{inspect(got)}"

    assert Enum.take(failures, 30) == []

    failures =
      for [zone, date, hour, start] <- f["starts"],
          zone not in changed,
          got = Time.start_of(date, zone, hour),
          got != start,
          do: "#{zone} #{date} #{hour}: #{got} not #{start}"

    assert Enum.take(failures, 30) == []

    for [zone, year, sha] <- f["dayStarts"], zone not in changed do
      days =
        "#{year}-01-01"
        |> Stream.iterate(&Time.add_days(&1, 1))
        |> Enum.take_while(&(&1 < "#{year + 1}-01-01"))
        |> Enum.map(&Time.start_of(&1, zone))

      assert Runlight.Hash.sha256(JS.stringify(days)) == sha, "#{zone} #{year}"
    end
  end

  test "date math, ranges, buckets, and comparisons" do
    f = Fixtures.php("time.json")
    assert Time.periods() == f["periods"]

    for c <- f["dates"] do
      date = c["date"]
      assert Time.date?(date) == c["isDate"], date

      if c["plus"] != nil do
        assert Enum.map([-400, -366, -365, -31, -1, 0, 1, 28, 29, 31, 365, 366, 1000], &Time.add_days(date, &1)) ==
                 c["plus"]

        assert Enum.map([-25, -12, -11, -1, 0, 1, 11, 12, 13], &Time.add_months(date, &1)) == c["months"]
      end
    end

    failures =
      for c <- f["ranges"],
          range = Time.resolve_range(input_map(c["input"]), c["zone"], c["now"], c["firstDate"]),
          failure <-
            (
              got = JS.obj(range: range_obj(range))
              want = JS.obj(range: c["range"])

              {got, want} =
                if range do
                  buckets = Time.buckets(range, c["zone"])
                  bucket_list = Enum.map(buckets, &JS.obj(start: &1.start, end: &1.end))

                  got =
                    Object.put(
                      got,
                      "buckets",
                      JS.obj(
                        count: length(buckets),
                        first: List.first(bucket_list),
                        sha256: Runlight.Hash.sha256(JS.stringify(bucket_list))
                      )
                    )

                  want = Object.put(want, "buckets", c["buckets"])

                  if c["compare"] do
                    compare =
                      Enum.reduce(~w(previous year off custom nope), JS.obj([]), fn mode, acc ->
                        Object.put(
                          acc,
                          mode,
                          range_obj(Time.compare_range(range, mode, c["zone"], %{from: "2025-02-28", to: "2025-03-31"}))
                        )
                      end)

                    {Object.put(got, "compare", compare), Object.put(want, "compare", c["compare"])}
                  else
                    {got, want}
                  end
                else
                  {got, want}
                end

              if canon(got) == canon(want),
                do: [],
                else: ["#{c["zone"]} #{c["now"]} #{JS.stringify(c["input"])}: #{JS.stringify(got)}"]
            ),
          do: failure

    assert Enum.take(failures, 10) == []

    for c <- f["compares"] do
      r = c["range"]
      range = %{from: r["from"], to: r["to"], from_date: r["fromDate"], to_date: r["toDate"], interval: r["interval"]}
      custom = %{from: c["custom"]["from"], to: c["custom"]["to"]}
      assert canon(range_obj(Time.compare_range(range, c["mode"], c["zone"], custom))) == canon(c["compare"])
    end
  end

  test "journeys" do
    f = Fixtures.php("journeys.json")
    datasets = f["datasets"]

    for c <- f["runs"] do
      rows = datasets |> Enum.at(c["dataset"]) |> Enum.map(&%{session: &1["session"], path: &1["path"]})
      o = c["options"]

      options =
        %{steps: o["steps"], start: o["start"], end: o["end"]}
        |> then(fn m ->
          if o["through"], do: Map.put(m, :through, {o["through"]["step"], o["through"]["value"]}), else: m
        end)

      assert canon(Journeys.journeys(rows, options)) == canon(c["result"]), JS.stringify(c)
    end
  end

  defp cell(%Object{} = o) do
    case o["js"] do
      nil -> o
      "undefined" -> :undefined
      "NaN" -> :nan
      "Infinity" -> :infinity
      "-Infinity" -> :neg_infinity
      "-0" -> -0.0
    end
  end

  defp cell(v), do: v

  test "csv and zip" do
    f = Fixtures.php("zip.json")
    for c <- f["rows"], do: assert(Zip.csv_row([cell(c["cell"])]) == c["row"], inspect(c["cell"]))

    for c <- f["csvs"] do
      assert Zip.csv(Enum.map(c["header"], &cell/1), Enum.map(c["rows"], fn r -> Enum.map(r, &cell/1) end)) == c["csv"]
    end

    for c <- f["zips"] do
      files = Enum.map(c["files"], &%{name: &1["name"], text: &1["text"]})
      assert Base.encode64(Zip.zip(files, c["now"])) == c["base64"]
    end
  end

  test "goals, funnels, page patterns, and click rules" do
    f = Fixtures.php("goals.json")

    outcome = fn fun, fresh ->
      try do
        value = fun.()

        value =
          if fresh and Regex.match?(~r/\A[0-9a-f]{24}\z/, value["id"]),
            do: Object.put(value, "id", "<random>"),
            else: value

        JS.obj(value: value)
      rescue
        e in [Runlight.GoalError, Runlight.FunnelError] ->
          JS.obj(error: JS.obj(message: e.message, code: e.code, params: JS.obj(e.params)))
      end
    end

    for c <- f["goals"] do
      got = outcome.(fn -> Goals.goal_from(c["input"], "s", f["existing"], 1000, c["id"]) end, c["id"] == nil)
      assert JS.stringify(got) == JS.stringify(c["result"]), JS.stringify(c["input"])
    end

    for c <- f["funnels"] do
      got = outcome.(fn -> Goals.funnel_from(c["input"], "s", f["existingFunnels"], 1000, c["id"]) end, c["id"] == nil)
      assert JS.stringify(got) == JS.stringify(c["result"]), JS.stringify(c["input"])
    end

    for c <- f["patterns"], do: assert(Goals.page_pattern(c["input"]) == c["result"], c["input"])
  end

  test "locations from headers and lookups" do
    f = Fixtures.php("geo.json")

    loc = fn
      nil -> nil
      l -> JS.obj(country: l.country, region: l.region, city: l.city)
    end

    for c <- f["headers"] do
      headers = Headers.new(Object.to_list(c["headers"]))
      assert canon(loc.(Geo.location_from_headers(headers))) == canon(c["location"]), JS.stringify(c["headers"])
    end

    for c <- f["located"] do
      headers = Headers.new(Object.to_list(c["headers"]))
      found = c["found"]

      lookup =
        cond do
          c["throws"] -> fn _ -> raise "broken" end
          found == nil -> fn _ -> nil end
          true -> fn _ -> %{country: found["country"], region: found["region"], city: found["city"]} end
        end

      assert canon(loc.(Geo.locate(headers, c["ip"], lookup))) == canon(c["location"]), JS.stringify(c)
    end
  end

  test "plural forms and words" do
    f = Fixtures.php("messages.json")
    assert Messages.languages() == f["languages"]

    numbers =
      Enum.map(f["numbers"], fn
        "NaN" -> :nan
        "Infinity" -> :infinity
        "-Infinity" -> :neg_infinity
        n -> n
      end)

    for lang <- f["languages"] do
      assert Enum.map(numbers, &Messages.plural(lang, &1)) == f["plural"][lang], lang
    end

    for w <- f["words"] do
      for t <- w["t"] do
        vars = Map.new(Object.to_list(t["vars"]))
        assert Messages.t(w["lang"], t["key"], vars) == t["text"], "#{w["lang"]} #{t["key"]}"
      end
    end
  end
end
