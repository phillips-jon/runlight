defmodule Runlight.Zip do
  @moduledoc false
  # Internal. A ZIP file of text files, stored without compression, and CSV
  # (the SDK's zip.ts).

  alias Runlight.JS

  @doc "The ZIP of `files` (`%{name, text}`), dated `now` (epoch milliseconds, UTC)."
  @spec zip([map()], integer()) :: binary()
  def zip(files, now) do
    {y, mo, d} = JS.civil_from_days(Integer.floor_div(now, 86_400_000))
    rest = Integer.mod(now, 86_400_000)
    {h, mi, s} = {div(rest, 3_600_000), rem(div(rest, 60_000), 60), rem(div(rest, 1000), 60)}
    import Bitwise
    time = h <<< 11 ||| mi <<< 5 ||| div(s, 2)
    day = (y - 1980) <<< 9 ||| mo <<< 5 ||| d
    time = time &&& 0xFFFF
    day = day &&& 0xFFFF

    {parts, central, offset} =
      Enum.reduce(files, {[], [], 0}, fn file, {parts, central, offset} ->
        name = file.name
        data = file.text
        crc = :erlang.crc32(data)
        size = byte_size(data)

        local =
          <<0x04034B50::little-32, 20::little-16, 0x0800::little-16, 0::little-16, time::little-16, day::little-16,
            crc::little-32, size::little-32, size::little-32, byte_size(name)::little-16, 0::little-16>>

        entry =
          <<0x02014B50::little-32, 20::little-16, 20::little-16, 0x0800::little-16, 0::little-16, time::little-16,
            day::little-16, crc::little-32, size::little-32, size::little-32, byte_size(name)::little-16, 0::little-16,
            0::little-16, 0::little-16, 0::little-16, 0::little-32, offset::little-32>>

        {[parts, local, name, data], [central, entry, name], offset + 30 + byte_size(name) + size}
      end)

    central = IO.iodata_to_binary(central)
    count = length(files)

    finish =
      <<0x06054B50::little-32, 0::little-16, 0::little-16, count::little-16, count::little-16,
        byte_size(central)::little-32, offset::little-32, 0::little-16>>

    IO.iodata_to_binary([parts, central, finish])
  end

  @doc """
  One CSV row, quoting what needs it; a leading =, +, -, or @ is escaped so a
  spreadsheet will not run it.
  """
  @spec csv_row([term()]) :: String.t()
  def csv_row(values) do
    Enum.map_join(values, ",", fn v ->
      s = if v in [nil, :undefined], do: "", else: JS.string(v)
      s = if Regex.match?(~r/^[=+\-@\t\r]/, s) and not Regex.match?(~r/\A-?\d+(\.\d+)?\z/, s), do: "'" <> s, else: s
      if Regex.match?(~r/[",\n\r]/, s), do: "\"" <> String.replace(s, "\"", "\"\"") <> "\"", else: s
    end)
  end

  @doc "A CSV file of a header and rows."
  @spec csv([term()], [[term()]]) :: String.t()
  def csv(header, rows), do: Enum.map_join([header | rows], "\r\n", &csv_row/1) <> "\r\n"
end
