defmodule Runlight.Messages do
  @moduledoc false
  # Internal. The dashboard's translations, for text the server writes (email
  # reports): the same keys and placeholders, so every language stays in one
  # place (the SDK's messages.ts).

  alias Runlight.Assets
  alias Runlight.JS
  alias Runlight.JS.Object

  @tables (for {code, text} <- Assets.locales(), into: %{} do
             {code, text |> JS.parse!() |> Object.to_list() |> Map.new()}
           end)

  defp table(lang), do: Map.get(@tables, lang, %{})

  @doc "Every language, English first."
  @spec languages() :: [String.t()]
  def languages, do: ["en" | Assets.locale_codes()]

  @doc "The language used for `lang`: itself when known, else English."
  @spec code(term()) :: String.t()
  def code(lang), do: if(lang in languages(), do: lang, else: "en")

  defp fill(text, vars) do
    Regex.replace(~r/\{(\w+)\}/, text, fn whole, name ->
      case fetch(vars, name) do
        {:ok, v} -> JS.string(v)
        :error -> whole
      end
    end)
  end

  defp fetch(vars, name) when is_map(vars) do
    case Map.fetch(vars, name) do
      {:ok, v} ->
        {:ok, v}

      :error ->
        Enum.find_value(vars, :error, fn
          {k, v} when is_atom(k) -> if Atom.to_string(k) == name, do: {:ok, v}
          _ -> nil
        end)
    end
  end

  defp fetch(vars, name) when is_list(vars), do: fetch(Map.new(vars), name)

  @doc "`t(key, vars)` in a language."
  @spec t(String.t(), String.t(), map() | keyword()) :: String.t()
  def t(lang, key, vars \\ %{}) do
    code = code(lang)
    text = Map.get(table(code), key) || Map.get(table("en"), key) || key
    fill(text, vars)
  end

  @doc "`tn(key, n, vars)`: the plural form for `n` in a language."
  @spec tn(String.t(), String.t(), number(), map() | keyword()) :: String.t()
  def tn(lang, key, n, vars \\ %{}) do
    code = code(lang)
    form = plural(code, n)
    own = Map.get(table(code), "#{key}_#{form}") || Map.get(table(code), "#{key}_other")
    if own != nil and own != "", do: fill(own, vars), else: t(code, "#{key}_other", vars)
  end

  @doc """
  `Intl.PluralRules(lang).select(n)` for the dashboard's languages, by CLDR's
  cardinal rules. As there, the number is first written with at most three
  decimals (rounding half away from zero), and its integer digits i and
  visible decimals v are read from that. Any other language answers "other".
  """
  @spec plural(String.t(), term()) :: String.t()
  def plural(_lang, n) when n in [:nan, :infinity, :neg_infinity], do: "other"

  def plural(lang, n) do
    {i, fraction} = decimal(abs(n))
    v = byte_size(fraction)
    million = i != "0" and byte_size(i) >= 7 and String.ends_with?(i, "000000")

    case lang do
      l when l in ["en", "de"] ->
        if i == "1" and v == 0, do: "one", else: "other"

      "es" ->
        cond do
          i == "1" and v == 0 -> "one"
          million and v == 0 -> "many"
          true -> "other"
        end

      l when l in ["fr", "pt"] ->
        cond do
          i in ["0", "1"] -> "one"
          million and v == 0 -> "many"
          true -> "other"
        end

      _ ->
        "other"
    end
  end

  defp decimal(n) do
    text = JS.format_number(n)

    text =
      case Regex.run(~r/\A(\d+)(?:\.(\d+))?e([+-]\d+)\z/, text) do
        [_, int, frac, exp] ->
          digits = int <> frac
          point = byte_size(int) + String.to_integer(exp)

          cond do
            point <= 0 -> "0." <> String.duplicate("0", -point) <> digits
            point >= byte_size(digits) -> digits <> String.duplicate("0", point - byte_size(digits))
            true -> binary_part(digits, 0, point) <> "." <> binary_part(digits, point, byte_size(digits) - point)
          end

        nil ->
          text
      end

    {whole, fraction} =
      case :binary.split(text, ".") do
        [w, f] -> {w, f}
        [w] -> {w, ""}
      end

    {whole, fraction} =
      if byte_size(fraction) > 3 do
        up = String.to_integer(binary_part(fraction, 3, 1)) >= 5
        fraction = binary_part(fraction, 0, 3)

        if up do
          all = increment(whole <> fraction)
          {binary_part(all, 0, byte_size(all) - 3), binary_part(all, byte_size(all) - 3, 3)}
        else
          {whole, fraction}
        end
      else
        {whole, fraction}
      end

    # ICU reads i as a 64-bit integer, keeping only the lowest 18 digits of a larger number, so 1e21 has i = 0.
    whole = if byte_size(whole) > 18, do: binary_part(whole, byte_size(whole) - 18, 18), else: whole
    whole = String.trim_leading(whole, "0")
    {if(whole == "", do: "0", else: whole), String.trim_trailing(fraction, "0")}
  end

  defp increment(digits) do
    n = String.to_integer(digits) + 1
    n |> Integer.to_string() |> String.pad_leading(byte_size(digits), "0")
  end
end
