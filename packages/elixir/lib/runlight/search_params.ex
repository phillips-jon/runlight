defmodule Runlight.SearchParams do
  @moduledoc """
  A URL's query as the WHATWG `URLSearchParams` reads it: an ordered list of
  `{name, value}` pairs, where a name may repeat.

  Documented for its type; its functions are internal and can change in
  any release.
  """

  # Internal: not the package's API, and it can change in any release.
  #
  # Query parameters as JavaScript's URLSearchParams reads and writes them:
  # pairs kept in order, `+` read as a space, and written back in the
  # application/x-www-form-urlencoded form. A name like `a[]` or `a.b` is kept
  # exactly as sent.

  import Kernel, except: [to_string: 1]

  @type t :: [{String.t(), String.t()}]

  @doc "`new URLSearchParams(text)`."
  @spec parse(String.t()) :: t()
  def parse(text) do
    text = if String.starts_with?(text, "?"), do: binary_part(text, 1, byte_size(text) - 1), else: text

    text
    |> String.split("&")
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn part ->
      case :binary.split(part, "=") do
        [name, value] -> {decode(name), decode(value)}
        [name] -> {decode(name), ""}
      end
    end)
  end

  @doc "`new URLSearchParams(pairs)` from a keyword list, a map, or pairs."
  @spec new(Enumerable.t()) :: t()
  def new(pairs), do: Enum.map(pairs, fn {k, v} -> {Kernel.to_string(k), Kernel.to_string(v)} end)

  @doc "`params.get(name)`, nil when it is not there."
  @spec get(t(), String.t()) :: String.t() | nil
  def get(params, name) do
    case List.keyfind(params, name, 0) do
      {_, v} -> v
      nil -> nil
    end
  end

  @doc "`params.getAll(name)`."
  @spec get_all(t(), String.t()) :: [String.t()]
  def get_all(params, name), do: for({^name, v} <- params, do: v)

  @doc "`params.has(name)`."
  @spec has?(t(), String.t()) :: boolean()
  def has?(params, name), do: List.keymember?(params, name, 0)

  @doc "`params.set(name, value)`: the first in place, the rest gone, or added at the end."
  @spec set(t(), String.t(), String.t()) :: t()
  def set(params, name, value) do
    {out, found} =
      Enum.reduce(params, {[], false}, fn
        {^name, _}, {out, false} -> {[{name, value} | out], true}
        {^name, _}, {out, true} -> {out, true}
        pair, {out, found} -> {[pair | out], found}
      end)

    out = Enum.reverse(out)
    if found, do: out, else: out ++ [{name, value}]
  end

  @doc "`params.append(name, value)`."
  @spec append(t(), String.t(), String.t()) :: t()
  def append(params, name, value), do: params ++ [{name, value}]

  @doc "`params.delete(name)`."
  @spec delete(t(), String.t()) :: t()
  def delete(params, name), do: Enum.reject(params, fn {k, _} -> k == name end)

  @doc "`params.toString()`."
  @spec to_string(t()) :: String.t()
  def to_string(params), do: Enum.map_join(params, "&", fn {k, v} -> encode(k) <> "=" <> encode(v) end)

  defp decode(text) do
    text
    |> String.replace("+", " ")
    |> then(&Regex.replace(~r/%([0-9A-Fa-f]{2})/, &1, fn _, hex -> <<String.to_integer(hex, 16)>> end))
    |> Runlight.JS.scrub()
  end

  @doc "The form encoding: letters, digits, and *-._ as they are, spaces as +, the rest escaped."
  @spec encode(String.t()) :: String.t()
  def encode(text) do
    for <<c <- text>>, into: "" do
      cond do
        c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in ~c"*-._" -> <<c>>
        c == ?\s -> "+"
        true -> "%" <> (c |> Integer.to_string(16) |> String.pad_leading(2, "0"))
      end
    end
  end
end
