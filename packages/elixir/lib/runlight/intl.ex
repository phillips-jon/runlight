defmodule Runlight.Intl do
  @moduledoc false
  # Internal. The pieces of JavaScript's Intl the email reports use, for the
  # dashboard's languages (en, de, es, fr, and pt), as Node's ICU writes them:
  # Intl.NumberFormat for counts, percents, one decimal place, and currencies,
  # Intl.DateTimeFormat for a month and year or a short day, and
  # Intl.DisplayNames for region names. Elixir has no ICU, so what it would
  # say is read from priv/intl.json, which scripts/elixir-intl.mts writes from
  # Node's own.
  #
  # Numbers round as ICU does, half away from zero on the number's shortest
  # decimal form, so 2.05 to one place is 2.1, though the double just under
  # it is what is stored.

  alias Runlight.JS

  @path Path.expand("../../priv/intl.json", __DIR__)
  @external_resource @path

  @data (fn ->
           raw = @path |> File.read!() |> JS.parse!()

           for lang <- ~w(en de es fr pt), into: %{} do
             o = raw[lang]

             {lang,
              %{
                group: o["group"],
                decimal: o["decimal"],
                groups_four: o["groupsFour"],
                percent: {o["percent"]["prefix"], o["percent"]["suffix"]},
                currencies:
                  for {code, c} <- JS.Object.to_list(o["currencies"]), into: %{} do
                    {code, {c["prefix"], c["suffix"], c["digits"]}}
                  end,
                other: {o["other"]["prefix"], o["other"]["suffix"]},
                months: Enum.map(o["months"], &List.to_tuple/1) |> List.to_tuple(),
                regions: o["regions"] |> JS.Object.to_list() |> Map.new()
              }}
           end
         end).()

  defp data(lang), do: Map.get(@data, lang) || Map.fetch!(@data, "en")

  @doc "`new Intl.NumberFormat(lang, { minimumFractionDigits, maximumFractionDigits }).format(n)`; the defaults are 0 and 3."
  @spec number(String.t(), number(), non_neg_integer(), non_neg_integer()) :: String.t()
  def number(lang, n, min \\ 0, max \\ 3)
  def number(_lang, :nan, _min, _max), do: "NaN"
  def number(_lang, :infinity, _min, _max), do: "∞"
  def number(_lang, :neg_infinity, _min, _max), do: "-∞"

  def number(lang, n, min, max) do
    d = data(lang)
    {negative, whole, fraction} = rounded(n, min, max)

    whole =
      if not d.groups_four and byte_size(whole) < 5,
        do: whole,
        else: Regex.replace(~r/\B(?=(\d{3})+$)/, whole, d.group)

    if(negative, do: "-", else: "") <> whole <> if(fraction != "", do: d.decimal <> fraction, else: "")
  end

  @doc "`new Intl.NumberFormat(lang, { style: \"percent\", maximumFractionDigits: 0 }).format(n)`."
  @spec percent(String.t(), number()) :: String.t()
  def percent(lang, n) do
    {prefix, suffix} = data(lang).percent
    prefix <> number(lang, times100(n), 0, 0) <> suffix
  end

  @doc """
  `new Intl.NumberFormat(lang, { style: "currency", currency, maximumFractionDigits }).format(n)`,
  or `${n} ${currency}` where Intl throws (a currency code that is not three letters).
  """
  @spec currency(String.t(), number(), String.t(), non_neg_integer()) :: String.t()
  def currency(lang, n, currency, max) do
    if Regex.match?(~r/\A[A-Za-z]{3}\z/, currency) do
      code = String.upcase(currency)
      d = data(lang)

      {prefix, suffix, digits} =
        case Map.fetch(d.currencies, code) do
          {:ok, c} ->
            c

          :error ->
            {p, s} = d.other
            {String.replace(p, "{c}", code), String.replace(s, "{c}", code), 2}
        end

      prefix <> number(lang, n, min(digits, max), max) <> suffix
    else
      "#{JS.string(n)} #{currency}"
    end
  end

  @doc "A date, YYYY-MM-DD, as `{ month: \"long\", year: \"numeric\" }` writes it."
  @spec month_year(String.t(), String.t()) :: String.t()
  def month_year(lang, date), do: date_text(lang, date, 0)

  @doc "A date as `{ month: \"short\", day: \"numeric\" }` writes it, with `year: \"numeric\"` too when asked."
  @spec short_day(String.t(), String.t(), boolean()) :: String.t()
  def short_day(lang, date, with_year), do: date_text(lang, date, if(with_year, do: 2, else: 1))

  defp date_text(lang, date, pattern) do
    [y, m, d] = date |> String.split("-") |> Enum.map(&String.to_integer/1)
    template = data(lang).months |> elem(m - 1) |> elem(pattern)
    template |> String.replace("{y}", Integer.to_string(y)) |> String.replace("{d}", Integer.to_string(d))
  end

  @doc """
  `new Intl.DisplayNames(lang, { type: "region" }).of(code)`, or the code
  where that throws or there is no name. Only an upper case code is looked
  up; Intl gives any other back as it came.
  """
  @spec region(String.t(), String.t()) :: String.t()
  def region(lang, code) do
    if Regex.match?(~r/\A([A-Z]{2}|\d{3})\z/, code), do: Map.get(data(lang).regions, code, code), else: code
  end

  # n * 100, worked out on the decimal digits, as ICU scales a percent, so 0.135 is 13.5.
  defp times100(n) when is_integer(n), do: n * 100

  defp times100(n) do
    {negative, digits, point} = decimal(n)
    {f, _} = Float.parse(if(negative, do: "-", else: "") <> plain(digits, point + 2))
    f
  end

  # The sign, whole digits, and fraction digits, rounded half away from zero to at most `max` places and
  # padded to at least `min`.
  defp rounded(n, min, _max) when is_integer(n), do: {n < 0, Integer.to_string(abs(n)), String.duplicate("0", min)}

  defp rounded(n, min, max) do
    {negative, digits, point} = decimal(n)
    keep = point + max

    units =
      cond do
        keep < 0 ->
          "0"

        byte_size(digits) > keep ->
          units = if keep == 0, do: "0", else: binary_part(digits, 0, keep)
          if String.to_integer(binary_part(digits, keep, 1)) >= 5, do: increment(units), else: units

        true ->
          String.pad_trailing(digits, keep, "0")
      end

    units = String.pad_leading(units, max + 1, "0")
    whole = units |> binary_part(0, byte_size(units) - max) |> String.trim_leading("0")
    fraction = if max > 0, do: binary_part(units, byte_size(units) - max, max), else: ""
    fraction = fraction |> String.trim_trailing("0") |> String.pad_trailing(min, "0")
    {negative, if(whole == "", do: "0", else: whole), fraction}
  end

  defp increment(digits) do
    n = String.to_integer(digits) + 1
    n |> Integer.to_string() |> String.pad_leading(byte_size(digits), "0")
  end

  # The shortest decimal form of a double: its sign, its significant digits, and where the point goes.
  defp decimal(n) when n == 0, do: {false, "0", 1}

  defp decimal(n) do
    {digits, point} = JS.shortest(abs(n))
    {n < 0, digits, point}
  end

  defp plain(digits, point) do
    cond do
      point <= 0 -> "0." <> String.duplicate("0", -point) <> digits
      point >= byte_size(digits) -> digits <> String.duplicate("0", point - byte_size(digits))
      true -> binary_part(digits, 0, point) <> "." <> binary_part(digits, point, byte_size(digits) - point)
    end
  end
end
