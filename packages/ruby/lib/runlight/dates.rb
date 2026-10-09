# frozen_string_literal: true

require "tzinfo"

module Runlight
  # Dates in a site's timezone, without a date library. Ranges are computed
  # here as epoch milliseconds so the database only ever compares integers.
  #
  # A range is a Hash {"from", "to", "fromDate", "toDate", "interval"}: `from` inclusive, `to` exclusive, and
  # the first and last local dates covered, YYYY-MM-DD, both inclusive. A bucket is a Hash {"start", "end"}.
  #
  # The TypeScript reads local times through Intl.DateTimeFormat, which knows ICU's zone names. TZInfo knows
  # nearly the same ones, and the differences are settled here: a name is matched without regard to case, the
  # few that are links to another zone in the time zone database (CET, EST, MST) go to the zone ICU reads them
  # as, ICU's own extra names (PST, SystemV/EST5EDT) are added, and "Factory", which ICU refuses, is refused.
  module Dates
    PERIODS = %w[today yesterday 7d 30d 90d month last_month year 12mo all].freeze
    INTERVALS = %w[hour day week month].freeze
    COMPARE_MODES = %w[previous year custom off].freeze

    MAX_BUCKETS = 1000
    # A month of hours. Longer hourly ranges are cut off rather than refused.
    MAX_HOURS = 744

    # Names Intl reads as another zone where TZInfo has no name, or reads it differently.
    ALIASES = {
      # Links in the time zone database whose names PHP took for abbreviations.
      "cet" => "Europe/Brussels", "eet" => "Europe/Athens", "est" => "America/Panama", "gmt" => "UTC", "gmt+0" => "UTC",
      "gmt-0" => "UTC", "hst" => "Pacific/Honolulu", "met" => "Europe/Brussels", "mst" => "America/Phoenix", "uct" => "UTC",
      "wet" => "Europe/Lisbon",
      # ICU's three letter names, kept from early Java.
      "act" => "Australia/Darwin", "aet" => "Australia/Sydney", "agt" => "America/Argentina/Buenos_Aires", "art" => "Africa/Cairo",
      "ast" => "America/Anchorage", "bet" => "America/Sao_Paulo", "bst" => "Asia/Dhaka", "cat" => "Africa/Maputo",
      "cnt" => "America/St_Johns", "cst" => "America/Chicago", "ctt" => "Asia/Shanghai", "eat" => "Africa/Nairobi",
      "ect" => "Europe/Paris", "iet" => "America/Indiana/Indianapolis", "ist" => "Asia/Kolkata", "jst" => "Asia/Tokyo",
      "mit" => "Pacific/Apia", "net" => "Asia/Yerevan", "nst" => "Pacific/Auckland", "plt" => "Asia/Karachi",
      "pnt" => "America/Phoenix", "prt" => "America/Puerto_Rico", "pst" => "America/Los_Angeles", "sst" => "Pacific/Guadalcanal",
      "vst" => "Asia/Ho_Chi_Minh",
      # ICU's System V zones.
      "systemv/ast4" => "Etc/GMT+4", "systemv/ast4adt" => "America/Halifax", "systemv/est5" => "Etc/GMT+5",
      "systemv/est5edt" => "America/New_York", "systemv/cst6" => "Etc/GMT+6", "systemv/cst6cdt" => "America/Chicago",
      "systemv/mst7" => "Etc/GMT+7", "systemv/mst7mdt" => "America/Denver", "systemv/pst8" => "Etc/GMT+8",
      "systemv/pst8pdt" => "America/Los_Angeles", "systemv/yst9" => "Etc/GMT+9", "systemv/yst9ydt" => "America/Anchorage",
      "systemv/hst10" => "Etc/GMT+10",
      # Names the database dropped and ICU kept.
      "canada/east-saskatchewan" => "America/Regina", "us/pacific-new" => "America/Los_Angeles",
    }.freeze

    OFFSET = /\A([+\-]|−)([01][0-9]|2[0-3])(?::?([0-5][0-9]))?\z/
    private_constant :MAX_BUCKETS, :MAX_HOURS, :ALIASES, :OFFSET

    # A zone: a TZInfo::Timezone, or the seconds of a fixed offset; false where Intl throws a RangeError.
    @zones = {}
    # Lowercase name to TZInfo's name.
    @names = nil

    module_function

    # The zone Intl.DateTimeFormat would use for a timeZone option, or nil where it throws a RangeError.
    def zone(timezone)
      @zones[timezone] = open_zone(timezone) || false unless @zones.key?(timezone)
      @zones[timezone] || nil
    end

    def open_zone(timezone)
      # An offset, as ECMA-402 takes one: a sign (a minus sign too), two digit hours, and optional minutes.
      if (m = timezone.match(OFFSET))
        seconds = (m[2].to_i * 3600) + (m[3].to_i * 60)
        return m[1] == "+" ? seconds : -seconds
      end
      return nil if timezone.b.match?(/[^\x21-\x7e]/n)

      key = timezone.downcase
      return TZInfo::Timezone.get(ALIASES[key]) if ALIASES.key?(key)

      if @names.nil?
        names = {}
        TZInfo::Timezone.all_identifiers.each { |name| names[name.downcase] = name }
        names.delete("factory")
        @names = names
      end
      name = @names[key]
      name.nil? ? nil : TZInfo::Timezone.get(name)
    end

    def timezone?(value)
      !zone(value).nil?
    end

    # Year, month, day, hour, minute, and second of an instant in a zone, as Intl formats them.
    def parts(ts, timezone)
      zone = zone(timezone)
      raise ArgumentError, "Invalid time zone specified: #{timezone}" if zone.nil?

      seconds = ts.div(1000)
      local = seconds + utc_offset(zone, seconds)
      y, m, d = civil(local.div(86_400) * 86_400_000)
      second = local % 86_400
      [y, m, d, second / 3600, (second / 60) % 60, second % 60]
    end

    # Seconds a zone is ahead of UTC at an instant. TZInfo works out a zone's rules only for the next hundred
    # years or so and then keeps the last offset, where Intl follows the rules for ever; past the last change
    # TZInfo knows, the rules come from the zone's file, as Intl reads them.
    def utc_offset(zone, seconds)
      return zone if zone.is_a?(Integer)

      period = zone.period_for(Time.at(seconds).utc)
      return period.utc_total_offset unless period.end_transition.nil?

      rules = rules(zone)
      rules.nil? ? period.utc_total_offset : rule_offset(rules, seconds)
    end

    # The rules at the end of a zone's file (a POSIX TZ string such as EST5EDT,M3.2.0,M11.1.0) as
    # [standard offset, summer offset, start rule, end rule], each rule [kind, a, b, c, seconds into the day];
    # nil for a zone that keeps one offset, or whose file cannot be read.
    def rules(zone)
      name = zone.canonical_identifier
      return @rules[name] if @rules.key?(name)

      @rules[name] = begin
        source = TZInfo::DataSource.get
        dirs = source.respond_to?(:zoneinfo_dir) ? [source.zoneinfo_dir] : TZInfo::DataSources::ZoneinfoDataSource.search_path
        file = dirs.map { |dir| File.join(dir, name) }.find { |path| File.file?(path) }
        footer = file && File.binread(file)[/\n([^\n]*)\n\z/n, 1]
        footer && posix(footer)
      rescue SystemCallError, IOError
        nil
      end
    end

    POSIX_NAME = /(?:[A-Za-z]{3,}|<[+\-0-9A-Za-z]+>)/n
    POSIX_TIME = /([+\-]?)(\d{1,3})(?::(\d{1,2}))?(?::(\d{1,2}))?/n
    POSIX_RULE = /(?:M(\d{1,2})\.(\d)\.(\d)|J(\d{1,3})|(\d{1,3}))(?:\/#{POSIX_TIME})?/n
    POSIX = /\A#{POSIX_NAME}#{POSIX_TIME}(?:#{POSIX_NAME}(?:#{POSIX_TIME})?,#{POSIX_RULE},#{POSIX_RULE})?\z/n
    private_constant :POSIX_NAME, :POSIX_TIME, :POSIX_RULE, :POSIX
    @rules = {}

    def posix(text)
      m = text.match(POSIX)
      return nil if m.nil? || (m[9] || m[12] || m[13]).nil?

      time = lambda do |sign, h, mi, s|
        value = (h.to_i * 3600) + (mi.to_i * 60) + s.to_i
        sign == "-" ? -value : value
      end
      # POSIX counts west of Greenwich as positive.
      std = -time.call(*m.values_at(1, 2, 3, 4))
      dst = m[6].nil? ? std + 3600 : -time.call(*m.values_at(5, 6, 7, 8))
      rule = lambda do |at|
        seconds = m[at + 6].nil? ? 7200 : time.call(*m.values_at(at + 5, at + 6, at + 7, at + 8))
        if m[at] then [:m, m[at].to_i, m[at + 1].to_i, m[at + 2].to_i, seconds]
        elsif m[at + 3] then [:j, m[at + 3].to_i, 0, 0, seconds]
        else [:n, m[at + 4].to_i, 0, 0, seconds]
        end
      end
      [std, dst, rule.call(9), rule.call(18)]
    end

    def rule_offset(rules, seconds)
      std, dst, start, finish = rules
      year, = civil((seconds + std) * 1000)
      # The change to summer time happens at a standard time, and the change back at a summer time.
      from = rule_day(start, year) + start[4] - std
      to = rule_day(finish, year) + finish[4] - dst
      summer = from < to ? seconds >= from && seconds < to : !(seconds >= to && seconds < from)
      summer ? dst : std
    end

    # Seconds from the epoch to the start of the day a rule names in a year, in local time.
    def rule_day(rule, year)
      kind, a, b, c = rule
      day = case kind
            # Jn: day n of 365, never counting February 29.
            when :j then days_from_civil(year, 1, 1) + a - 1 + (a >= 60 && days_in_month(year, 2) == 29 ? 1 : 0)
            # n: day n counted from 0, February 29 included.
            when :n then days_from_civil(year, 1, 1) + a
            # Mm.w.d: weekday d (0 is Sunday) of week w of month m, week 5 being the last.
            else
              first = days_from_civil(year, a, 1)
              # 1970-01-01 was a Thursday.
              offset = (c - ((first + 4) % 7)) % 7
              found = first + offset + ((b - 1) * 7)
              found -= 7 while found >= first + days_in_month(year, a)
              found
            end
      day * 86_400
    end

    # Milliseconds the zone is ahead of UTC at an instant.
    def offset(ts, timezone)
      y, mo, d, h, mi, s = parts(ts, timezone)
      utc(y, mo - 1, d, h, mi, s) - (ts - ts.remainder(1000))
    end

    # The instant a local date (and hour) begins in a zone.
    def start_of(date, timezone, hour = 0)
      y, m, d = split(date)
      guess = utc(y, m - 1, d, hour)
      first = guess - offset(guess, timezone)
      at = guess - offset(first, timezone)
      # Where clocks jump forward at that time (midnight in Santiago, Havana, and the Azores), it never
      # happens, and the sum above lands before it; the day then begins when the clocks land, at most a
      # few quarter hours on.
      8.times do
        ly, lm, ld, lh = parts(at, timezone)
        break if utc(ly, lm - 1, ld, lh) >= guess

        at += 15 * 60_000
      end
      at
    end

    # The local date of an instant, YYYY-MM-DD.
    def local_date(ts, timezone)
      y, m, d = parts(ts, timezone)
      format("%s-%02d-%02d", y.to_s.rjust(4, "0"), m, d)
    end

    def add_days(date, days)
      y, m, d = split(date)
      iso(utc(y, m - 1, d + days))[0, 10]
    end

    def add_months(date, months)
      y, m, = split(date)
      iso(utc(y, m - 1 + months, 1))[0, 10]
    end

    def date?(value)
      # Years from 1900 to 9998, so the day after any date is a date too.
      return false if !value.match?(/\A\d{4}-\d{2}-\d{2}\z/) || value < "1900" || value >= "9999"

      # A month or day that does not exist (2026-13-01) makes no date at all, rather than a wrong one.
      y, m, d = split(value)
      m.between?(1, 12) && d.between?(1, days_in_month(y, m))
    end

    def days_between(from, to)
      fy, fm, fd = split(from)
      ty, tm, td = split(to)
      tdiv(utc(ty, tm - 1, td) - utc(fy, fm - 1, fd), 86_400_000)
    end

    def default_interval(from_date, to_date)
      days = days_between(from_date, to_date)
      return "hour" if days < 1
      return "day" if days <= 92

      "month"
    end

    # A named period or custom dates as a range in the site's timezone.
    # `first_date` is the earliest local date with data, used by "all".
    # input: a Hash with "period", "from", "to", and "interval", each optional.
    def resolve_range(input, timezone, now, first_date = nil)
      today = local_date(now, timezone)
      from = input["from"]
      to = input["to"]

      if (!from.nil? && from != "") || (!to.nil? && to != "")
        return nil if from.nil? || from == "" || to.nil? || to == "" || !date?(from) || !date?(to) || from > to

        from_date = from
        to_date = to
      else
        month_start = "#{today[0, 8]}01"
        case input["period"] || "30d"
        when "today" then from_date = to_date = today
        when "yesterday" then from_date = to_date = add_days(today, -1)
        when "7d" then from_date, to_date = add_days(today, -6), today
        when "30d" then from_date, to_date = add_days(today, -29), today
        when "90d" then from_date, to_date = add_days(today, -89), today
        when "month" then from_date, to_date = month_start, today
        when "last_month" then from_date, to_date = add_months(today, -1), add_days(month_start, -1)
        when "year" then from_date, to_date = "#{today[0, 4]}-01-01", today
        when "12mo" then from_date, to_date = add_months(today, -11), today
        when "all"
          from_date = !first_date.nil? && first_date != "" && first_date < today ? first_date : today
          to_date = today
        else return nil
        end
      end

      interval = INTERVALS.include?(input["interval"]) ? input["interval"] : default_interval(from_date, to_date)
      { "from" => start_of(from_date, timezone), "to" => start_of(add_days(to_date, 1), timezone), "fromDate" => from_date,
        "toDate" => to_date, "interval" => interval }
    end

    def add_years(date, years)
      y, m, d = split(date)
      shifted = utc(y + years, m - 1, d)
      # Feb 29 in a year without one becomes Feb 28, not Mar 1.
      sy, sm = civil(shifted)
      # setUTCDate(0): the last day of the month before.
      shifted = utc(sy, sm - 1, 0) if sm != m
      iso(shifted)[0, 10]
    end

    # The range a period is compared with: the same number of days just before
    # it, the same dates a year earlier, or custom dates. Nil for "off" or bad
    # custom dates.
    def compare_range(range, mode, timezone, custom = {})
      return nil if mode == "off"

      if mode == "year"
        from_date = add_years(range["fromDate"], -1)
        to_date = add_years(range["toDate"], -1)
      elsif mode == "custom"
        from = custom["from"]
        to = custom["to"]
        return nil if from.nil? || from == "" || to.nil? || to == "" || !date?(from) || !date?(to) || from > to

        from_date = from
        to_date = to
      else
        days = days_between(range["fromDate"], range["toDate"]) + 1
        from_date = add_days(range["fromDate"], -days)
        to_date = add_days(range["fromDate"], -1)
      end
      { "from" => start_of(from_date, timezone), "to" => start_of(add_days(to_date, 1), timezone), "fromDate" => from_date,
        "toDate" => to_date, "interval" => range["interval"] }
    end

    # Chart buckets covering a range, each starting on a local boundary.
    def buckets(range, timezone)
      starts = []
      if range["interval"] == "hour"
        t = range["from"]
        while t < range["to"] && starts.length < MAX_HOURS
          starts << t
          t += 3_600_000
        end
      else
        date = range["fromDate"]
        if range["interval"] == "week"
          date = add_days(date, -weekday(date))
        elsif range["interval"] == "month"
          date = "#{date[0, 8]}01"
        end
        while date <= range["toDate"] && starts.length < MAX_BUCKETS
          starts << start_of(date, timezone)
          date = case range["interval"]
                 when "day" then add_days(date, 1)
                 when "week" then add_days(date, 7)
                 else add_months(date, 1)
                 end
        end
      end
      starts.each_with_index.map do |start, i|
        { "start" => [start, range["from"]].max, "end" => [starts[i + 1] || range["to"], range["to"]].min }
      end
    end

    # Monday is 0. [weekday, hour].
    def local_weekday_hour(ts, timezone)
      y, m, d, h = parts(ts, timezone)
      [weekday(format("%04d-%02d-%02d", y, m, d)), h]
    end

    # Monday is 0.
    def weekday(date)
      y, m, d = split(date)
      days = tdiv(utc(y, m - 1, d), 86_400_000)
      # 1970-01-01 was a Thursday.
      (days + 3) % 7
    end

    def split(date)
      parts = date.split("-").map(&:to_i)
      [parts[0], parts[1] || 0, parts[2] || 0]
    end

    def days_in_month(year, month)
      return [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1] unless month == 2

      leap = (year % 4).zero? && (!(year % 100).zero? || (year % 400).zero?)
      leap ? 29 : 28
    end

    # PHP's intdiv: the quotient truncated toward zero.
    def tdiv(a, b)
      q = a.abs / b.abs
      (a.negative? ^ b.negative?) ? -q : q
    end

    # Date.UTC: months and days past their ends roll over, and a year from 0 to 99 means 1900 to 1999.
    def utc(year, month, day, hour = 0, minute = 0, second = 0)
      year += 1900 if year.between?(0, 99)
      year += month.div(12)
      month = (month % 12) + 1
      days = days_from_civil(year, month, 1) + day - 1
      (days * 86_400_000) + (hour * 3_600_000) + (minute * 60_000) + (second * 1000)
    end

    # Days from 1970-01-01 to a proleptic Gregorian date.
    def days_from_civil(y, m, d)
      y -= m <= 2 ? 1 : 0
      era = tdiv(y >= 0 ? y : y - 399, 400)
      yoe = y - (era * 400)
      doy = tdiv((153 * (m + (m > 2 ? -3 : 9))) + 2, 5) + d - 1
      doe = (yoe * 365) + tdiv(yoe, 4) - tdiv(yoe, 100) + doy
      (era * 146_097) + doe - 719_468
    end

    # Year, month, and day of an instant in UTC.
    def civil(ms)
      z = ms.div(86_400_000) + 719_468
      era = tdiv(z >= 0 ? z : z - 146_096, 146_097)
      doe = z - (era * 146_097)
      yoe = tdiv(doe - tdiv(doe, 1460) + tdiv(doe, 36_524) - tdiv(doe, 146_096), 365)
      doy = doe - ((365 * yoe) + tdiv(yoe, 4) - tdiv(yoe, 100))
      mp = tdiv((5 * doy) + 2, 153)
      d = doy - tdiv((153 * mp) + 2, 5) + 1
      m = mp < 10 ? mp + 3 : mp - 9
      [yoe + (era * 400) + (m <= 2 ? 1 : 0), m, d]
    end

    # The date part of Date.prototype.toISOString, with its six digit form outside years 0 to 9999.
    def iso(ms)
      y, m, d = civil(ms)
      year = y.between?(0, 9999) ? format("%04d", y) : "#{y.negative? ? "-" : "+"}#{format("%06d", y.abs)}"
      format("%s-%02d-%02d", year, m, d)
    end

    private_class_method :zone, :open_zone, :parts, :utc_offset, :rules, :posix, :rule_offset, :rule_day, :offset, :days_between, :default_interval, :add_years, :weekday, :split,
                         :days_in_month, :tdiv, :utc, :days_from_civil, :civil, :iso
  end
end
