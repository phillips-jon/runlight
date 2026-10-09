# frozen_string_literal: true

require "test_helper"

# Replays test/fixtures/intl.json, which scripts/ruby-intl.mts writes from Node's ICU: numbers, percents, one
# decimal place, money, dates, and region names as the email reports format them, in every dashboard language.
class IntlTest < Minitest::Test
  FIXTURE = Runlight::Json.decode(File.read(File.expand_path("fixtures/intl.json", __dir__)))

  def number(text)
    case text
    when "NaN" then Float::NAN
    when "Infinity" then Float::INFINITY
    when "-Infinity" then -Float::INFINITY
    else text.match?(/\A-?\d+\z/) ? Integer(text) : Float(text)
    end
  end

  def test_every_case_matches_node
    failures = []
    FIXTURE["cases"].each do |c|
      lang = c["lang"]
      got = case c["kind"]
            when "number" then Runlight::Intl.number(lang, number(c["n"]))
            when "percent" then Runlight::Intl.percent(lang, number(c["n"]))
            when "decimal" then Runlight::Intl.number(lang, number(c["n"]), 1, 1)
            when "currency"
              n = number(c["n"])
              Runlight::Intl.currency(lang, n, c["currency"], n.is_a?(Integer) ? 0 : 2)
            when "monthYear" then Runlight::Intl.month_year(lang, c["date"])
            when "shortDay" then Runlight::Intl.short_day(lang, c["date"], false)
            when "shortDayYear" then Runlight::Intl.short_day(lang, c["date"], true)
            when "region" then Runlight::Intl.region(lang, c["code"])
            end
      failures << "#{Fixtures.label(c)} gave #{got.inspect}" unless got == c["out"]
    end
    assert_empty failures, failures.first(20).join("\n")
  end
end
