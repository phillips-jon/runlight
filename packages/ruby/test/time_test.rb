# frozen_string_literal: true

require "test_helper"
require "openssl"

# The TypeScript SDK's time tests, then the fixture written from it.
class TimeTest < Minitest::Test
  Dates = Runlight::Dates
  Json = Runlight::Json

  # ICU's System V zones with summer time keep the United States rules of their day, which no zone in the
  # time zone database has; their names are taken, and they follow today's rules here.
  SYSTEM_V_SUMMER = %w[systemv/ast4adt systemv/est5edt systemv/cst6cdt systemv/mst7mdt systemv/pst8pdt systemv/yst9ydt].freeze

  # The fixture came from Node's ICU with time zone data 2025c. TZInfo reads the system's copy of the data (or
  # tzinfo-data's), which disagrees wherever a zone's rules changed between the two. Data from 2025c to 2026a
  # agrees with the fixture everywhere; with newer data, the zones whose rules changed since (Morocco, British
  # Columbia, and Alberta, in 2026b) are left out of the comparisons, and every other zone must still match.
  CHANGED_AFTER_2026A = %w[
    Africa/Casablanca Africa/El_Aaiun America/Edmonton America/Vancouver America/Inuvik America/Yellowknife Canada/Mountain Canada/Pacific
  ].freeze

  def self.data_version
    source = TZInfo::DataSource.get
    return TZInfo::Data::Version::TZDATA if defined?(TZInfo::Data::Version::TZDATA) && !source.respond_to?(:zoneinfo_dir)

    File.read(File.join(source.zoneinfo_dir, "+VERSION")).strip
  rescue StandardError
    "unknown"
  end

  # Zones to leave out of the comparisons with this time zone data.
  def self.changed_zones
    @changed_zones ||= data_version.between?("2025c", "2026a") ? [] : CHANGED_AFTER_2026A
  end

  def changed?(zone)
    self.class.changed_zones.include?(zone)
  end

  # Some systems' zone files stop listing changes after 2037, so TZInfo there knows no summer time from 2038 on.
  # Where Lord Howe Island has none in December 2038, instants from 2038 on are not compared.
  BEYOND_2037 = 2_145_916_800_000 # 2038-01-01T00:00:00Z

  def self.short_data?
    @short_data = TZInfo::Timezone.get("Australia/Lord_Howe").period_for(Time.utc(2038, 12, 15)).std_offset.zero? if @short_data.nil?
    @short_data
  end

  def beyond_data?(ts)
    self.class.short_data? && ts >= BEYOND_2037
  end

  def iso(ms)
    Time.at(ms.div(1000), ms % 1000, :millisecond).utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
  end

  def utc(y, m, d = 1, h = 0, i = 0)
    Time.utc(y, m + 1, d, h, i).to_i * 1000
  end

  def sha256(text)
    OpenSSL::Digest::SHA256.hexdigest(text)
  end

  def test_a_local_day_starts_at_local_midnight
    assert_equal "2026-06-30T23:00:00.000Z", iso(Dates.start_of("2026-07-01", "Europe/London"))
    assert_equal "2026-01-15T05:00:00.000Z", iso(Dates.start_of("2026-01-15", "America/Toronto"))
    assert_equal "2026-01-14T18:30:00.000Z", iso(Dates.start_of("2026-01-15", "Asia/Kolkata"))
    assert_equal "2026-01-15T00:00:00.000Z", iso(Dates.start_of("2026-01-15", "UTC"))
  end

  def test_the_spring_dst_change_makes_a_23_hour_day
    range = Dates.resolve_range({ "from" => "2026-03-07", "to" => "2026-03-09" }, "America/Toronto", utc(2026, 2, 10))
    days = Dates.buckets(range, "America/Toronto")
    assert_equal 3, days.length
    assert_equal [24, 23, 24], days.map { |d| (d["end"] - d["start"]) / 3_600_000 }
  end

  def test_named_periods_resolve_in_the_sites_timezone
    now = utc(2026, 9, 6, 2) # 2026-10-06 02:00 UTC is still the 5th in Toronto
    assert_equal "2026-10-05", Dates.local_date(now, "America/Toronto")
    today = Dates.resolve_range({ "period" => "today" }, "America/Toronto", now)
    assert_equal "2026-10-05", today["fromDate"]
    assert_equal "hour", today["interval"]
    week = Dates.resolve_range({ "period" => "7d" }, "UTC", now)
    assert_equal "2026-09-30", week["fromDate"]
    assert_equal "2026-10-06", week["toDate"]
    last_month = Dates.resolve_range({ "period" => "last_month" }, "UTC", now)
    assert_equal %w[2026-09-01 2026-09-30], [last_month["fromDate"], last_month["toDate"]]
    assert_equal "month", Dates.resolve_range({ "period" => "12mo" }, "UTC", now)["interval"]
    assert_nil Dates.resolve_range({ "period" => "nope" }, "UTC", now)
    assert_nil Dates.resolve_range({ "from" => "2026-10-05", "to" => "2026-10-01" }, "UTC", now)
    assert_nil Dates.resolve_range({ "from" => "2026-02-30", "to" => "2026-03-01" }, "UTC", now)
  end

  def test_month_buckets_start_on_the_first
    range = Dates.resolve_range({ "from" => "2026-01-15", "to" => "2026-03-10", "interval" => "month" }, "UTC", utc(2026, 3, 1))
    months = Dates.buckets(range, "UTC")
    assert_equal 3, months.length
    assert_equal "2026-01-15T00:00:00.000Z", iso(months[0]["start"])
    assert_equal "2026-02-01T00:00:00.000Z", iso(months[1]["start"])
    assert_equal "2026-03-11T00:00:00.000Z", iso(months[2]["end"])
  end

  def test_comparison_ranges_previous_a_year_back_custom_and_off
    now = utc(2026, 9, 6, 12)
    week = Dates.resolve_range({ "period" => "7d" }, "UTC", now)
    prev = Dates.compare_range(week, "previous", "UTC")
    assert_equal %w[2026-09-23 2026-09-29], [prev["fromDate"], prev["toDate"]]
    assert_equal week["from"], prev["to"]
    year = Dates.compare_range(week, "year", "UTC")
    assert_equal %w[2025-09-30 2025-10-06], [year["fromDate"], year["toDate"]]
    leap = Dates.compare_range(Dates.resolve_range({ "from" => "2028-02-29", "to" => "2028-02-29" }, "UTC", now), "year", "UTC")
    assert_equal "2027-02-28", leap["fromDate"]
    custom = Dates.compare_range(week, "custom", "UTC", { "from" => "2026-01-01", "to" => "2026-01-07" })
    assert_equal "2026-01-01", custom["fromDate"]
    assert_nil Dates.compare_range(week, "custom", "UTC", { "from" => "2026-01-07", "to" => "2026-01-01" })
    assert_nil Dates.compare_range(week, "off", "UTC")
  end

  def test_a_day_whose_midnight_is_skipped_by_the_clocks_begins_when_they_land
    # Santiago, Havana, and the Azores move their clocks forward at midnight.
    [
      ["2026-09-06", "America/Santiago", "2026-09-06T04:00:00.000Z"],
      ["2026-03-08", "America/Havana", "2026-03-08T05:00:00.000Z"],
      ["2026-03-29", "Atlantic/Azores", "2026-03-29T01:00:00.000Z"],
    ].each do |date, zone, start|
      at = Dates.start_of(date, zone)
      assert_equal start, iso(at), zone
      assert_equal date, Dates.local_date(at, zone)
      refute_equal date, Dates.local_date(at - 1, zone)
    end
  end

  def test_a_date_with_a_month_or_day_that_does_not_exist_is_not_a_date
    %w[2026-13-01 2026-00-05 2026-02-30 2026-04-31 2026-1-01 9999-12-31 0001-01-01].each do |bad|
      refute Dates.date?(bad), bad
    end
    assert Dates.date?("2028-02-29")
  end

  def test_zones
    fixture = Fixtures.load("time")
    failures = []
    # Before 1970 ICU follows the time zone database's backzone history, where zones that are now links
    # (Africa/Bamako, Europe/Oslo) kept their own clocks; the system's database has only the links, so
    # instants before 1970 are compared for the focus zones alone, in test_instants_around_every_offset_change.
    since1970 = fixture["sampleTimes"].each_with_index.select { |ts, _| ts >= 0 }
    fixture["zones"].each do |zone|
      valid = Dates.timezone?(zone["name"])
      if valid != zone["valid"]
        failures << "#{zone["name"]}#{valid ? " taken" : " refused"}"
        next
      end
      next if !valid || SYSTEM_V_SUMMER.include?(zone["name"].downcase) || changed?(zone["name"])

      since1970.each do |ts, i|
        local = "#{Dates.local_date(ts, zone["name"])} #{Dates.local_weekday_hour(ts, zone["name"]).join(" ")}"
        failures << "#{zone["name"]} at #{ts}: #{local} not #{zone["local"][i]}" if local != zone["local"][i]
      end
    end
    assert_operator fixture["zones"].length, :>, 600
    assert_equal [], failures
  end

  def test_instants_around_every_offset_change
    failures = []
    instants = Fixtures.load("time")["instants"]
    instants.each do |zone, ts, date, weekday, hour|
      next if changed?(zone) || beyond_data?(ts)

      got = [Dates.local_date(ts, zone), *Dates.local_weekday_hour(ts, zone)]
      failures << "#{zone} #{ts}: #{got.join(" ")} not #{date} #{weekday} #{hour}" if got != [date, weekday, hour]
    end
    assert_operator instants.length, :>, 10_000
    assert_equal [], failures.first(30)
  end

  def test_day_starts
    fixture = Fixtures.load("time")
    failures = []
    fixture["starts"].each do |zone, date, hour, start|
      next if changed?(zone) || (self.class.short_data? && date >= "2038")

      got = Dates.start_of(date, zone, hour)
      failures << "#{zone} #{date} #{hour}: #{got} not #{start}" if got != start
    end
    fixture["dayStarts"].each do |zone, year, sha|
      next if changed?(zone) || (self.class.short_data? && year >= 2038)

      days = []
      d = "#{year}-01-01"
      while d < "#{year + 1}-01-01"
        days << Dates.start_of(d, zone)
        d = Dates.add_days(d, 1)
      end
      failures << "#{zone} #{year}: every day's start" if sha256(Json.encode(days)) != sha
    end
    assert_equal [], failures.first(30)
  end

  def test_date_math
    fixture = Fixtures.load("time")
    fixture["dates"].each do |c|
      date = c["date"]
      assert_equal c["isDate"], Dates.date?(date), date
      next if c["plus"].nil?

      assert_equal c["plus"], [-400, -366, -365, -31, -1, 0, 1, 28, 29, 31, 365, 366, 1000].map { |n| Dates.add_days(date, n) }, date
      assert_equal c["months"], [-25, -12, -11, -1, 0, 1, 11, 12, 13].map { |n| Dates.add_months(date, n) }, date
    end
    assert_equal fixture["periods"], Dates::PERIODS
  end

  def test_ranges_and_buckets
    failures = []
    ranges = Fixtures.load("time")["ranges"]
    ranges.each do |c|
      range = Dates.resolve_range(c["input"], c["zone"], c["now"], c["firstDate"])
      got = { "range" => range }
      want = { "range" => c["range"] }
      unless range.nil?
        buckets = Dates.buckets(range, c["zone"])
        got["buckets"] = { "count" => buckets.length, "first" => buckets[0], "sha256" => sha256(Json.encode(buckets)) }
        want["buckets"] = c["buckets"]
        if c.key?("compare")
          got["compare"] = {}
          %w[previous year off custom nope].each do |mode|
            got["compare"][mode] = Dates.compare_range(range, mode, c["zone"], { "from" => "2025-02-28", "to" => "2025-03-31" })
          end
          want["compare"] = c["compare"]
        end
      end
      next if Json.encode(got) == Json.encode(want)

      failures << "#{Fixtures.label([c["zone"], c["now"], c["input"], c["firstDate"]])} gave #{Fixtures.label(got)} not #{Fixtures.label(want)}"
    end
    assert_operator ranges.length, :>, 2000
    assert_equal [], failures.first(20)
  end

  def test_compare_ranges
    Fixtures.load("time")["compares"].each do |c|
      assert_equal Json.encode(c["compare"]), Json.encode(Dates.compare_range(c["range"], c["mode"], c["zone"], c["custom"])), Fixtures.label(c)
    end
  end
end
