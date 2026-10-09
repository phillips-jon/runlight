defmodule Runlight.Mmdb do
  @moduledoc """
  A reader for MaxMind DB files (the MMDB format that MaxMind's GeoLite2 and
  DB-IP's free databases use), in plain Elixir so location needs no library.
  It answers what the TypeScript server's mmdb-lib answers: the record for an
  address, maps with string keys, or nil when the address is not in the
  database.

  Format: https://maxmind.github.io/MaxMind-DB/
  """

  import Bitwise

  @marker <<0xAB, 0xCD, 0xEF, "MaxMind.com">>
  @metadata_max 131_072

  defstruct [:bytes, :metadata, :node_count, :record_size, :node_bytes, :data_start, :ipv4_start]

  @type t :: %__MODULE__{}

  @doc "A database from its bytes. Raises ArgumentError when it is not one."
  @spec new(binary()) :: t()
  def new(bytes) do
    size = byte_size(bytes)
    tail_start = max(0, size - @metadata_max)
    tail = binary_part(bytes, tail_start, size - tail_start)

    at =
      case :binary.matches(tail, @marker) do
        [] -> raise ArgumentError, "Not a MaxMind DB file: no metadata"
        matches -> elem(List.last(matches), 0)
      end

    start = tail_start + at + byte_size(@marker)
    db = %__MODULE__{bytes: bytes}
    {metadata, _} = decode(db, start, start)

    unless is_map(metadata) and Map.has_key?(metadata, "node_count") and Map.has_key?(metadata, "record_size") and
             Map.has_key?(metadata, "ip_version"),
           do: raise(ArgumentError, "Not a MaxMind DB file: bad metadata")

    record_size = metadata["record_size"]
    unless record_size in [24, 28, 32], do: raise(ArgumentError, "Unsupported record size #{record_size}")
    node_bytes = div(record_size, 4)

    db = %{
      db
      | metadata: metadata,
        node_count: metadata["node_count"],
        record_size: record_size,
        node_bytes: node_bytes,
        data_start: metadata["node_count"] * node_bytes + 16
    }

    %{db | ipv4_start: ipv4_start(db)}
  end

  @doc "A database read from a file."
  @spec open(Path.t()) :: t()
  def open(path), do: path |> File.read!() |> new()

  @doc "The record for an address, or nil. Raises ArgumentError for text that is not an IP address."
  @spec get(t(), String.t()) :: term()
  def get(%__MODULE__{} = db, ip) do
    packed =
      case :inet.parse_strict_address(String.to_charlist(ip)) do
        {:ok, {a, b, c, d}} -> <<a, b, c, d>>
        {:ok, {a, b, c, d, e, f, g, h}} -> <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
        _ -> raise ArgumentError, "Not an IP address: #{ip}"
      end

    v6 = byte_size(packed) == 16

    if v6 and db.metadata["ip_version"] == 4,
      do: raise(ArgumentError, "An IPv6 address cannot be looked up in an IPv4-only database: #{ip}")

    node = if v6 or db.metadata["ip_version"] == 4, do: 0, else: db.ipv4_start
    bits = for <<bit::1 <- packed>>, do: bit

    node =
      Enum.reduce_while(bits, node, fn bit, node ->
        if node < db.node_count, do: {:cont, record(db, node, bit)}, else: {:halt, node}
      end)

    # The node count itself means no record, and so does a tree that ends before the address does.
    if node <= db.node_count do
      nil
    else
      {value, _} = decode(db, db.data_start + node - db.node_count - 16, db.data_start)
      value
    end
  end

  # IPv4 addresses live under ::/96 in an IPv6 tree: the node 96 left turns down.
  defp ipv4_start(db) do
    Enum.reduce_while(1..96, 0, fn _, node ->
      if node < db.node_count, do: {:cont, record(db, node, 0)}, else: {:halt, node}
    end)
  end

  defp read(db, at, length) do
    size = byte_size(db.bytes)
    if at >= size, do: "", else: binary_part(db.bytes, at, min(length, size - at))
  end

  defp byte(db, at) do
    case read(db, at, 1) do
      <<b>> -> b
      _ -> raise ArgumentError, "Invalid MaxMind DB: read past the end"
    end
  end

  defp record(db, node, right) do
    b = read(db, node * db.node_bytes, db.node_bytes)
    if byte_size(b) < db.node_bytes, do: raise(ArgumentError, "Invalid MaxMind DB: read past the end")

    case db.record_size do
      24 ->
        <<l::24, r::24>> = b
        if right == 0, do: l, else: r

      28 ->
        <<b0, b1, b2, b3, b4, b5, b6>> = b

        if right == 0,
          do: (b3 &&& 0xF0) <<< 20 ||| b0 <<< 16 ||| b1 <<< 8 ||| b2,
          else: (b3 &&& 0x0F) <<< 24 ||| b4 <<< 16 ||| b5 <<< 8 ||| b6

      32 ->
        <<l::32, r::32>> = b
        if right == 0, do: l, else: r
    end
  end

  # The value at `at` and the offset just past it; pointers are offsets from `base`.
  defp decode(db, at, base) do
    control = byte(db, at)
    at = at + 1
    type = control >>> 5

    if type == 1 do
      ss = control >>> 3 &&& 3
      vvv = control &&& 7

      pointer =
        case ss do
          0 -> vvv <<< 8 ||| byte(db, at)
          1 -> (vvv <<< 16 ||| byte(db, at) <<< 8 ||| byte(db, at + 1)) + 2048
          2 -> (vvv <<< 24 ||| byte(db, at) <<< 16 ||| byte(db, at + 1) <<< 8 ||| byte(db, at + 2)) + 526_336
          _ -> unsigned(read(db, at, 4))
        end

      {value, _} = decode(db, base + pointer, base)
      {value, at + ss + 1}
    else
      {type, at} = if type == 0, do: {7 + byte(db, at), at + 1}, else: {type, at}
      size = control &&& 0x1F

      {size, at} =
        if size >= 29 do
          extra = size - 28
          n = Enum.reduce(0..(extra - 1), 0, fn i, n -> n <<< 8 ||| byte(db, at + i) end)
          {%{29 => 29, 30 => 285, 31 => 65_821}[size] + n, at + extra}
        else
          {size, at}
        end

      case type do
        2 ->
          {read(db, at, size), at + size}

        3 ->
          <<f::float-64>> = read(db, at, 8)
          {f, at + 8}

        4 ->
          {read(db, at, size), at + size}

        t when t in [5, 6] ->
          {unsigned(read(db, at, size)), at + size}

        7 ->
          Enum.reduce(1..size//1, {%{}, at}, fn _, {map, at} ->
            {key, at} = decode(db, at, base)
            {value, at} = decode(db, at, base)
            {Map.put(map, to_string(key), value), at}
          end)

        8 ->
          n = unsigned(read(db, at, size))
          n = if size == 4 and n >= 0x80000000, do: n - 0x100000000, else: n
          {n, at + size}

        t when t in [9, 10] ->
          {unsigned(read(db, at, size)), at + size}

        11 ->
          {list, at} =
            Enum.reduce(1..size//1, {[], at}, fn _, {list, at} ->
              {value, at} = decode(db, at, base)
              {[value | list], at}
            end)

          {Enum.reverse(list), at}

        14 ->
          {size != 0, at}

        15 ->
          <<f::float-32>> = read(db, at, 4)
          {f, at + 4}

        other ->
          raise ArgumentError, "Invalid MaxMind DB: unknown data type #{other}"
      end
    end
  end

  defp unsigned(bytes), do: :binary.decode_unsigned(bytes)
end
