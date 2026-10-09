# frozen_string_literal: true

require "test_helper"

# Email reports and their periods, replayed from what scripts/php-fixtures-core2.mts had the TypeScript SDK write.
class CoreReportsTest < Minitest::Test
  AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36"
  Intl = Runlight::Intl
  Reports = Runlight::Reports

  Fixtures.load("reports")["intl"].each do |set|
    lang = set["lang"]

    define_method("test_numbers_percents_and_dates_are_written_as_intl_writes_them_in_#{lang}") do
      set["number"].each { |n, text| assert_equal text, Intl.number(lang, n), "#{lang} number #{n}" }
      set["decimal"].each { |n, text| assert_equal text, Intl.number(lang, n, 1, 1), "#{lang} decimal #{n}" }
      set["percent"].each { |n, text| assert_equal text, Intl.percent(lang, n), "#{lang} percent #{n}" }
      set["monthYear"].each { |day, text| assert_equal text, Intl.month_year(lang, day), "#{lang} #{day}" }
      set["shortDay"].each do |day, short, long|
        assert_equal short, Intl.short_day(lang, day, false), "#{lang} #{day}"
        assert_equal long, Intl.short_day(lang, day, true), "#{lang} #{day}"
      end
    end

    define_method("test_currencies_and_region_names_are_as_node_writes_them_in_#{lang}") do
      set["currency"].each do |n, currency, text|
        assert_equal text, Intl.currency(lang, n, currency, n.is_a?(Integer) ? 0 : 2), "#{lang} #{n} #{currency}"
      end
      differ = set["region"].filter_map do |code, name|
        own = Intl.region(lang, code)
        "#{code}: #{own} (Node: #{name})" if own != name
      end
      assert_equal [], differ, "#{lang} region names"
    end
  end

  def test_report_periods_match_for_every_zone_and_frequency
    Fixtures.load("reports")["periods"].each do |c|
      assert_equal c["period"], Reports.last_period(c["frequency"], c["now"], c["zone"]), Fixtures.label(c)
    end
  end

  def test_report_periods_are_last_monday_to_sunday_or_last_month_due_from_8am_the_day_after_in_the_sites_zone
    # Wednesday 8 October 2026, 15:00 UTC (11:00 in Toronto).
    now = Time.utc(2026, 10, 8, 15).to_i * 1000
    week = Reports.last_period("weekly", now, "America/Toronto")
    assert_equal ["w:2026-09-28", "2026-09-28", "2026-10-04", "2026-09-21"], [week["key"], week["fromDate"], week["toDate"], week["previousFrom"]]
    assert_equal Time.utc(2026, 10, 5, 12).to_i * 1000, week["dueAt"], "Monday 5 October, 8am Toronto"
    month = Reports.last_period("monthly", now, "America/Toronto")
    assert_equal ["m:2026-09", "2026-09-01", "2026-09-30", "2026-08-01", "2026-08-31"],
                 [month["key"], month["fromDate"], month["toDate"], month["previousFrom"], month["previousTo"]]
    early = Reports.last_period("weekly", Time.utc(2026, 10, 5, 7).to_i * 1000, "America/Toronto")
    assert_operator Time.utc(2026, 10, 5, 7).to_i * 1000, :<, early["dueAt"]
  end

  Fixtures.load("reports")["cases"].each_with_index do |c, index|
    define_method("test_reports_render_as_the_typescript_sdk_renders_them_in_every_language_#{index + 1}") do
      now = 0
      rl = Runlight::Core.new({
        "store" => Runlight::Stores.sqlite(":memory:"),
        "site" => { "name" => "Example & Co", "hostnames" => ["example.com"], "timezone" => c["timezone"] },
        "now" => -> { now },
      })
      rl.init
      c["goals"].each { |goal| rl.store.save_goal(goal) }
      c["hits"].each do |hit|
        now = hit["at"]
        headers = { "user-agent" => AGENT, "x-forwarded-for" => hit["ip"] }
        headers["x-vercel-ip-country"] = hit["country"] unless hit["country"] == ""
        rl.collect(Runlight::Http::Request.new("https://example.com/runlight/e", method: "POST", headers: headers, body: Runlight::Json.encode(hit["body"])))
      end
      now = c["at"]
      site = rl.site("default")
      c["reports"].each do |expected|
        label = "#{c["name"]}, #{expected["lang"]} #{expected["frequency"]}"
        assert_equal expected["period"], Reports.last_period(expected["frequency"], now, c["timezone"]), label
        report = Reports.build_report(rl, site, expected["frequency"], expected["period"], expected["lang"], expected["links"])
        assert_equal expected["subject"], report["subject"], label
        assert_equal expected["text"], report["text"], label
        assert_equal expected["html"], report["html"], label
      end
    end
  end
end
