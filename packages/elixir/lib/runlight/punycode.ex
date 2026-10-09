defmodule Runlight.Punycode do
  @moduledoc false
  # Internal: not the package's API, and it can change in any release.
  #
  # A domain name's labels as ASCII, as a URL's host is written: each label
  # with letters past ASCII becomes xn-- and its Punycode (RFC 3492). The
  # name is lowercased first, as UTS #46 maps it for the names people type.

  import Bitwise

  @base 36
  @tmin 1
  @tmax 26
  @skew 38
  @damp 700
  @initial_bias 72
  @initial_n 128

  @doc "The name with each label past ASCII as xn--, or :error for one that cannot be."
  @spec to_ascii(String.t()) :: {:ok, String.t()} | :error
  def to_ascii(name) do
    labels =
      name
      |> String.normalize(:nfc)
      |> String.split(".")
      |> Enum.map(fn label ->
        if Regex.match?(~r/[^\x00-\x7f]/u, label), do: "xn--" <> encode(String.to_charlist(label)), else: label
      end)

    if Enum.all?(labels, &(byte_size(&1) <= 63)), do: {:ok, Enum.join(labels, ".")}, else: :error
  end

  defp encode(input) do
    basic = for c <- input, c < 0x80, do: c
    b = length(basic)
    out = if b > 0, do: basic ++ [?-], else: []
    encode_loop(input, @initial_n, 0, @initial_bias, b, b, out) |> List.to_string()
  end

  defp encode_loop(input, n, delta, bias, h, b, out) do
    if h >= length(input) do
      out
    else
      m = input |> Enum.filter(&(&1 >= n)) |> Enum.min()
      delta = delta + (m - n) * (h + 1)
      n = m

      {delta, bias, h, out} =
        Enum.reduce(input, {delta, bias, h, out}, fn c, {delta, bias, h, out} ->
          cond do
            c < n ->
              {delta + 1, bias, h, out}

            c == n ->
              {digits, _} = digits(delta, bias, @base, [])
              bias = adapt(delta, h + 1, h == b)
              {0, bias, h + 1, out ++ digits}

            true ->
              {delta, bias, h, out}
          end
        end)

      encode_loop(input, n + 1, delta + 1, bias, h, b, out)
    end
  end

  defp digits(q, bias, k, acc) do
    t =
      cond do
        k <= bias -> @tmin
        k >= bias + @tmax -> @tmax
        true -> k - bias
      end

    if q < t do
      {Enum.reverse([digit(q) | acc]), nil}
    else
      d = t + rem(q - t, @base - t)
      digits(div(q - t, @base - t), bias, k + @base, [digit(d) | acc])
    end
  end

  defp digit(d) when d < 26, do: ?a + d
  defp digit(d), do: ?0 + d - 26

  defp adapt(delta, points, first) do
    delta = if first, do: div(delta, @damp), else: delta >>> 1
    delta = delta + div(delta, points)
    adapt_loop(delta, 0)
  end

  defp adapt_loop(delta, k) do
    if delta > div((@base - @tmin) * @tmax, 2) do
      adapt_loop(div(delta, @base - @tmin), k + @base)
    else
      k + div((@base - @tmin + 1) * delta, delta + @skew)
    end
  end
end
