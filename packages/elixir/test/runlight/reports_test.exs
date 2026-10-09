defmodule Runlight.ReportsTest do
  @moduledoc """
  Email reports and their periods, and the Intl formatting they use, replayed
  from what scripts/php-fixtures-core2.mts had the TypeScript SDK write
  (packages/php/tests/fixtures/reports.json).
  """
  use ExUnit.Case, async: true

  alias Runlight.Http.Request
  alias Runlight.Intl
  alias Runlight.JS
  alias Runlight.Reports
  alias Runlight.Store
  alias Runlight.Test.Fixtures
  alias Runlight.Test.Stores

  @agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36"

  setup_all do
    {:ok, fixture: Fixtures.php("reports.json")}
  end

  defp period_obj(p) do
    JS.obj(
      key: p.key,
      fromDate: p.from_date,
      toDate: p.to_date,
      previousFrom: p.previous_from,
      previousTo: p.previous_to,
      dueAt: p.due_at
    )
  end

  test "numbers, percents, currencies, dates, and regions are written as Intl writes them", %{fixture: f} do
    for set <- f["intl"] do
      lang = set["lang"]
      for [n, text] <- set["number"], do: assert(Intl.number(lang, n) == text, "#{lang} number #{n}")
      for [n, text] <- set["decimal"], do: assert(Intl.number(lang, n, 1, 1) == text, "#{lang} decimal #{n}")
      for [n, text] <- set["percent"], do: assert(Intl.percent(lang, n) == text, "#{lang} percent #{n}")

      for [n, currency, text] <- set["currency"],
          do:
            assert(
              Intl.currency(lang, n, currency, if(is_integer(n), do: 0, else: 2)) == text,
              "#{lang} #{n} #{currency}"
            )

      for [day, text] <- set["monthYear"], do: assert(Intl.month_year(lang, day) == text, "#{lang} #{day}")

      for [day, short, long] <- set["shortDay"] do
        assert Intl.short_day(lang, day, false) == short, "#{lang} #{day}"
        assert Intl.short_day(lang, day, true) == long, "#{lang} #{day}"
      end

      differ =
        for [code, name] <- set["region"],
            Intl.region(lang, code) != name,
            do: "#{code}: #{Intl.region(lang, code)} (Node: #{name})"

      assert differ == [], "#{lang} region names"
    end
  end

  test "periods match for every zone and frequency", %{fixture: f} do
    for c <- f["periods"] do
      assert period_obj(Reports.last_period(c["frequency"], c["now"], c["zone"])) == c["period"], JS.stringify(c)
    end
  end

  test "reports are last Monday to Sunday or last month, due from 8am the day after in the site's zone" do
    now = JS.date_utc(2026, 9, 8, 15)
    week = Reports.last_period("weekly", now, "America/Toronto")

    assert {week.key, week.from_date, week.to_date, week.previous_from} ==
             {"w:2026-09-28", "2026-09-28", "2026-10-04", "2026-09-21"}

    assert week.due_at == JS.date_utc(2026, 9, 5, 12)
    month = Reports.last_period("monthly", now, "America/Toronto")

    assert {month.key, month.from_date, month.to_date, month.previous_from, month.previous_to} ==
             {"m:2026-09", "2026-09-01", "2026-09-30", "2026-08-01", "2026-08-31"}
  end

  test "reports render as the TypeScript SDK renders them in every language", %{fixture: f} do
    for c <- f["cases"] do
      {store, cleanup} = Stores.store(:sqlite)
      clock = :atomics.new(1, signed: true)

      rl =
        Runlight.new(
          store: store,
          site: [name: "Example & Co", hostnames: ["example.com"], timezone: c["timezone"]],
          now: fn -> :atomics.get(clock, 1) end
        )

      Runlight.init(rl)
      for goal <- c["goals"], do: Store.save_goal(rl.store, goal)

      for hit <- c["hits"] do
        :atomics.put(clock, 1, hit["at"])
        headers = [{"user-agent", @agent}, {"x-forwarded-for", hit["ip"]}]
        headers = if hit["country"] != "", do: headers ++ [{"x-vercel-ip-country", hit["country"]}], else: headers

        Runlight.collect(
          rl,
          Request.new("https://example.com/runlight/e",
            method: "POST",
            headers: headers,
            body: JS.stringify(hit["body"])
          )
        )
      end

      :atomics.put(clock, 1, c["at"])
      site = Runlight.site(rl, "default")

      for expected <- c["reports"] do
        label = "#{c["name"]}, #{expected["lang"]} #{expected["frequency"]}"
        period = Reports.last_period(expected["frequency"], c["at"], c["timezone"])
        assert period_obj(period) == expected["period"], label
        links = %{dashboard: expected["links"]["dashboard"], unsubscribe: expected["links"]["unsubscribe"]}
        report = Reports.build_report(rl, site, expected["frequency"], period, expected["lang"], links)
        assert report.subject == expected["subject"], label
        assert report.text == expected["text"], label
        assert report.html == expected["html"], label
      end

      cleanup.()
    end
  end
end
