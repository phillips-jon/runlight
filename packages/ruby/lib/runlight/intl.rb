# frozen_string_literal: true

module Runlight
  # The pieces of JavaScript's Intl the email reports use, for the dashboard's languages (en, de, es, fr, and
  # pt), written out since Ruby has no ICU of its own: Intl.NumberFormat for counts, percents, one decimal
  # place, and money, Intl.DateTimeFormat for a month and year or a short day, and Intl.DisplayNames for a
  # region's name. Region names, currency symbols, and currency fraction digits come from assets/intl.json,
  # which scripts/ruby-intl.mts writes from Node's own ICU.
  #
  # Numbers round as ICU does, half away from zero on the number's shortest decimal form, so 2.05 to one
  # place is 2.1, though the double just under it is what is stored.
  module Intl
    GROUP = { "en" => ",", "de" => ".", "es" => ".", "fr" => " ", "pt" => "." }.freeze
    DECIMAL = { "en" => ".", "de" => ",", "es" => ",", "fr" => ",", "pt" => "," }.freeze
    PERCENT = { "en" => "%s%%", "de" => "%s %%", "es" => "%s %%", "fr" => "%s %%", "pt" => "%s%%" }.freeze

    MONTHS = {
      "en" => %w[January February March April May June July August September October November December],
      "de" => %w[Januar Februar März April Mai Juni Juli August September Oktober November Dezember],
      "es" => %w[enero febrero marzo abril mayo junio julio agosto septiembre octubre noviembre diciembre],
      "fr" => %w[janvier février mars avril mai juin juillet août septembre octobre novembre décembre],
      "pt" => %w[janeiro fevereiro março abril maio junho julho agosto setembro outubro novembro dezembro],
    }.freeze
    SHORT_MONTHS = {
      "en" => %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec],
      "de" => %w[Jan. Feb. März Apr. Mai Juni Juli Aug. Sept. Okt. Nov. Dez.],
      "es" => %w[ene feb mar abr may jun jul ago sept oct nov dic],
      "fr" => %w[janv. févr. mars avr. mai juin juil. août sept. oct. nov. déc.],
      "pt" => %w[jan. fev. mar. abr. mai. jun. jul. ago. set. out. nov. dez.],
    }.freeze
    # { month: "long", year: "numeric" }, then { month: "short", day: "numeric" } without and with the year.
    DATE_PATTERNS = {
      "en" => ["{M} {y}", "{m} {d}", "{m} {d}, {y}"],
      "de" => ["{M} {y}", "{d}. {m}", "{d}. {m} {y}"],
      "es" => ["{M} de {y}", "{d} {m}", "{d} {m} {y}"],
      "fr" => ["{M} {y}", "{d} {m}", "{d} {m} {y}"],
      "pt" => ["{M} de {y}", "{d} de {m}", "{d} de {m} de {y}"],
    }.freeze
    private_constant :GROUP, :DECIMAL, :PERCENT, :MONTHS, :SHORT_MONTHS, :DATE_PATTERNS

    module_function

    def lang(lang)
      GROUP.key?(lang) ? lang : "en"
    end

    # new Intl.NumberFormat(lang, { minimumFractionDigits, maximumFractionDigits }).format(n); the defaults are 0 and 3.
    def number(lang, n, min_fraction = 0, max_fraction = 3)
      lang = lang(lang)
      return "NaN" if n.is_a?(Float) && n.nan?
      return "#{n.negative? ? "-" : ""}∞" if n.is_a?(Float) && n.infinite?

      negative, whole, fraction = rounded(n, min_fraction, max_fraction)
      # Spanish groups only from five digits on (CLDR's minimum grouping digits of 2).
      whole = whole.gsub(/\B(?=(\d{3})+\z)/, GROUP[lang]) unless lang == "es" && whole.length < 5
      "#{negative ? "-" : ""}#{whole}#{fraction.empty? ? "" : DECIMAL[lang] + fraction}"
    end

    # new Intl.NumberFormat(lang, { style: "percent", maximumFractionDigits: 0 }).format(n).
    def percent(lang, n)
      lang = lang(lang)
      return format(PERCENT[lang], number(lang, n)) if n.is_a?(Float) && !n.finite?

      format(PERCENT[lang], number(lang, times100(n), 0, 0))
    end

    # new Intl.NumberFormat(lang, { style: "currency", currency, maximumFractionDigits }).format(n), or
    # `${n} ${currency}` where Intl throws (a currency code that is not three letters).
    def currency(lang, n, currency, max_fraction)
      lang = lang(lang)
      return "#{Js.string(n)} #{currency}" unless currency.match?(/\A[A-Za-z]{3}\z/)

      code = currency.upcase
      own = data["currencies"][lang][code]
      before, after = own || data["unknown"][lang].map { |part| part.gsub("{c}", code) }
      min_fraction = [data["digits"].fetch(code, 2), max_fraction].min
      finite = n.is_a?(Integer) || n.finite?
      amount = number(lang, finite ? n.abs : n, min_fraction, max_fraction).delete_prefix("-")
      negative = n.negative? || (n.is_a?(Float) && n.zero? && (1.0 / n).negative?)
      "#{negative ? "-" : ""}#{before}#{amount}#{after}"
    end

    # A date, YYYY-MM-DD, as { month: "long", year: "numeric" } writes it.
    def month_year(lang, date)
      date(lang, date, 0)
    end

    # A date as { month: "short", day: "numeric" } writes it, with `year: "numeric"` too when asked.
    def short_day(lang, date, with_year)
      date(lang, date, with_year ? 2 : 1)
    end

    def date(lang, date, pattern)
      lang = lang(lang)
      y, m, d = date.split("-").map(&:to_i)
      values = { "{M}" => MONTHS[lang][m - 1], "{m}" => SHORT_MONTHS[lang][m - 1], "{d}" => d.to_s, "{y}" => y.to_s }
      DATE_PATTERNS[lang][pattern].gsub(/\{[Mmdy]\}/, values)
    end

    # new Intl.DisplayNames(lang, { type: "region" }).of(code), or the code where that throws. Only an upper case
    # code is looked up; Intl gives any other back as it came.
    def region(lang, code)
      return code unless code.match?(/\A([A-Z]{2}|[0-9]{3})\z/)

      data["regions"][lang(lang)].fetch(code, code)
    end

    # assets/intl.json, read once.
    def data
      @data ||= Json.decode(File.read(File.join(Version::ASSETS, "intl.json")))
    end

    # n * 100, worked out on the decimal digits, as ICU scales a percent, so 0.135 is 13.5 and not 13.500000000000002.
    def times100(n)
      return n * 100 if n.is_a?(Integer)

      negative, digits, point = decimal(n)
      Float("#{negative ? "-" : ""}#{plain(digits, point + 2)}")
    end

    # The number's sign, whole digits, and fraction digits, rounded half away from zero to at most
    # `max` places and padded to at least `min`.
    def rounded(n, min, max)
      return [n.negative?, n.abs.to_s, "0" * min] if n.is_a?(Integer)

      negative, digits, point = decimal(n)
      # Digits as a whole number of units of 10^-max.
      keep = point + max
      if keep.negative?
        units = "0"
      elsif digits.length > keep
        units = keep.zero? ? "0" : digits[0, keep]
        units = increment(units) if digits[keep].to_i >= 5
      else
        units = digits.ljust(keep, "0")
      end
      units = units.rjust(max + 1, "0")
      whole = units[0, units.length - max].sub(/\A0+/, "")
      fraction = (max.positive? ? units[-max..] : "").sub(/0+\z/, "")
      fraction = fraction.ljust(min, "0")
      [negative, whole.empty? ? "0" : whole, fraction]
    end

    def increment(digits)
      digits = digits.dup
      i = digits.length - 1
      while i >= 0 && digits[i] == "9"
        digits[i] = "0"
        i -= 1
      end
      return "1#{digits}" if i.negative?

      digits[i] = (digits[i].to_i + 1).to_s
      digits
    end

    # The shortest decimal form of a double: its sign, its significant digits, and where the point
    # goes (the number of digits before it, which may be zero or negative).
    def decimal(n)
      negative = n.negative? || (n.zero? && (1.0 / n).negative?)
      text, exponent = n.abs.to_s.split("e")
      int, fraction = text.split(".")
      digits = int + fraction.to_s
      point = int.length + exponent.to_i
      trimmed = digits.sub(/\A0+/, "")
      point -= digits.length - trimmed.length
      trimmed = trimmed.sub(/0+\z/, "")
      [negative, trimmed.empty? ? "0" : trimmed, trimmed.empty? ? 1 : point]
    end

    # Digits with the point after `point` of them, written out in full.
    def plain(digits, point)
      return "0.#{"0" * -point}#{digits}" if point <= 0
      return digits + ("0" * (point - digits.length)) if point >= digits.length

      "#{digits[0, point]}.#{digits[point..]}"
    end

    private_class_method :lang, :data, :date, :times100, :rounded, :increment, :decimal, :plain
  end
end
