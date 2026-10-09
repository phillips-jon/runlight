# frozen_string_literal: true

module Runlight
  # The dashboard's translations, for text the server writes (email reports).
  # Same keys, same placeholders, so every language stays in one place.
  module Messages
    LOCALES = File.expand_path("../../assets/locales.json", __dir__)
    private_constant :LOCALES

    # Each language's table as JSON text, from the shared assets.
    @raw = nil
    @parsed = {}

    module_function

    def raw
      @raw ||= Json.decode(File.read(LOCALES, encoding: Encoding::UTF_8))
    end

    def table(lang)
      unless @parsed.key?(lang)
        text = raw[lang]
        @parsed[lang] = text.is_a?(String) ? Json.decode(text) : {}
      end
      @parsed[lang]
    end

    def languages
      ["en", *raw.keys.reject { |code| code == "en" }]
    end

    # The words for one language: t(key, vars) and tn(key, n, vars), with
    # "lang" the language used, English when the one asked for is not known.
    # A Hash {"t" => callable, "tn" => callable, "lang" => String}; vars is a Hash of String to a value.
    def translator(lang)
      code = languages.include?(lang) ? lang : "en"
      fill = lambda do |text, vars|
        text.gsub(/\{(\w+)\}/) { vars.key?(Regexp.last_match(1)) ? Js.string(vars[Regexp.last_match(1)]) : Regexp.last_match(0) }
      end
      t = ->(key, vars = {}) { fill.call(table(code)[key] || table("en")[key] || key, vars) }
      tn = lambda do |key, n, vars = {}|
        form = plural(code, n)
        own = table(code)["#{key}_#{form}"] || table(code)["#{key}_other"]
        !own.nil? && own != "" ? fill.call(own, vars) : t.call("#{key}_other", vars)
      end
      { "t" => t, "tn" => tn, "lang" => code }
    end

    # Intl.PluralRules(lang).select(n) for the dashboard's languages, by CLDR's cardinal rules. As there, the
    # number is first written with at most three decimals (rounding half away from zero), and its integer
    # digits i and visible decimals v are read from that. Any other language answers "other".
    #
    # - en, de: one when i = 1 and v = 0
    # - es: one when n = 1; many when i is a non-zero multiple of a million and v = 0
    # - fr, pt: one when i is 0 or 1; many as in es
    def plural(lang, n)
      return "other" if n.is_a?(Float) && (n.nan? || n.infinite?)

      i, fraction = decimal(n.abs)
      v = fraction.length
      million = i != "0" && i.length >= 7 && i.end_with?("000000")
      case lang
      when "en", "de"
        i == "1" && v.zero? ? "one" : "other"
      when "es"
        return "one" if i == "1" && v.zero?

        million && v.zero? ? "many" : "other"
      when "fr", "pt"
        return "one" if %w[0 1].include?(i)

        million && v.zero? ? "many" : "other"
      else
        "other"
      end
    end

    # A non-negative number as its integer digits and up to three decimals without trailing zeros, from the
    # shortest decimal that reads back as the number, as ICU formats it.
    def decimal(n)
      text = Json.number(n)
      # Plain digits, from JavaScript's exponent form where it uses one.
      if (m = text.match(/\A(\d+)(?:\.(\d+))?e([+-]\d+)\z/))
        digits = m[1] + m[2].to_s
        point = m[1].length + m[3].to_i
        text = if point <= 0 then "0.#{"0" * -point}#{digits}"
               elsif point >= digits.length then digits + ("0" * (point - digits.length))
               else "#{digits[0, point]}.#{digits[point..]}"
               end
      end
      whole, fraction = text.split(".", 2)
      fraction = fraction.to_s
      if fraction.length > 3
        up = fraction[3].to_i >= 5
        fraction = fraction[0, 3]
        if up
          # Add one at the third decimal, carrying into the whole part.
          all = increment(whole + fraction)
          whole = all[0, all.length - 3]
          fraction = all[-3..]
        end
      end
      # ICU reads i as a 64-bit integer, keeping only the lowest 18 digits of a larger number, so 1e21 has i = 0.
      whole = (whole.length > 18 ? whole[-18..] : whole).sub(/\A0+/, "")
      [whole.empty? ? "0" : whole, fraction.sub(/0+\z/, "")]
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

    private_class_method :raw, :table, :decimal, :increment
  end
end
