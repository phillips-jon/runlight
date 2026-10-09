defmodule Runlight.Zone do
  @moduledoc false
  # Internal: not the package's API, and it can change in any release.
  #
  # Time zones from `tz`'s copy of the IANA database, named as `Intl` names
  # them: without regard to case, so "america/new_york" is New York, as
  # `Intl.DateTimeFormat` reads it, with ICU's own extra names (PST, the System
  # V zones) as the PHP port lists them. A fixed offset ("+05:30", "-0800",
  # "+05") is a zone too, since `Intl` takes one. Tz.TimeZoneDatabase is called
  # directly; the app's `config :elixir, :time_zone_database` is never read or
  # set.

  alias Runlight.JS

  @type t :: :utc | {:fixed, integer()} | {:tz, String.t()}

  tz_dir =
    (fn ->
       dir = Application.compile_env(:tz, :data_dir) || to_string(:code.priv_dir(:tz))
       forced = Application.compile_env(:tz, :iana_version)

       names =
         case File.ls(dir) do
           {:ok, names} -> Enum.filter(names, &Regex.match?(~r/^tzdata20[0-9]{2}[a-z]$/, &1))
           _ -> []
         end

       chosen = if forced, do: Enum.find(names, &(&1 == "tzdata#{forced}")), else: Enum.max(names, fn -> nil end)
       if chosen, do: Path.join(dir, chosen)
     end).()

  files = ~w(africa antarctica asia australasia backward etcetera europe northamerica southamerica)

  names =
    if tz_dir do
      for file <- files,
          path = Path.join(tz_dir, file),
          File.exists?(path),
          line <- path |> File.read!() |> String.split("\n"),
          name <-
            (case String.split(line, ~r/\s+/, trim: true) do
               ["Zone", name | _] -> [name]
               ["Link", _target, name | _] -> [name]
               _ -> []
             end),
          do: name
    else
      []
    end

  for file <- files, tz_dir, do: @external_resource(Path.join(tz_dir, file))

  @names Map.new(names, &{String.downcase(&1), &1})

  # Names Intl reads as another zone where the database has none: ICU's three
  # letter names, kept from early Java, its System V zones, and names the
  # database dropped and ICU kept.
  @aliases %{
    "act" => "Australia/Darwin",
    "aet" => "Australia/Sydney",
    "agt" => "America/Argentina/Buenos_Aires",
    "art" => "Africa/Cairo",
    "ast" => "America/Anchorage",
    "bet" => "America/Sao_Paulo",
    "bst" => "Asia/Dhaka",
    "cat" => "Africa/Maputo",
    "cnt" => "America/St_Johns",
    "cst" => "America/Chicago",
    "ctt" => "Asia/Shanghai",
    "eat" => "Africa/Nairobi",
    "ect" => "Europe/Paris",
    "iet" => "America/Indiana/Indianapolis",
    "ist" => "Asia/Kolkata",
    "jst" => "Asia/Tokyo",
    "mit" => "Pacific/Apia",
    "net" => "Asia/Yerevan",
    "nst" => "Pacific/Auckland",
    "plt" => "Asia/Karachi",
    "pnt" => "America/Phoenix",
    "prt" => "America/Puerto_Rico",
    "pst" => "America/Los_Angeles",
    "sst" => "Pacific/Guadalcanal",
    "vst" => "Asia/Ho_Chi_Minh",
    "systemv/ast4" => "Etc/GMT+4",
    "systemv/ast4adt" => "America/Halifax",
    "systemv/est5" => "Etc/GMT+5",
    "systemv/est5edt" => "America/New_York",
    "systemv/cst6" => "Etc/GMT+6",
    "systemv/cst6cdt" => "America/Chicago",
    "systemv/mst7" => "Etc/GMT+7",
    "systemv/mst7mdt" => "America/Denver",
    "systemv/pst8" => "Etc/GMT+8",
    "systemv/pst8pdt" => "America/Los_Angeles",
    "systemv/yst9" => "Etc/GMT+9",
    "systemv/yst9ydt" => "America/Anchorage",
    "systemv/hst10" => "Etc/GMT+10",
    "canada/east-saskatchewan" => "America/Regina",
    "us/pacific-new" => "America/Los_Angeles"
  }

  @min_sec -377_705_116_800
  @max_sec 253_402_300_799
  @epoch_days 719_528

  @doc "The zone a name names, as `Intl.DateTimeFormat` reads a timeZone option, or nil where it throws."
  @spec find(term()) :: t() | nil
  def find(name) when is_binary(name) and name != "" do
    key = String.downcase(name)

    cond do
      String.contains?(name, <<0>>) -> nil
      Regex.match?(~r/[^\x21-\x7e]/, name) and fixed_offset(name) == nil -> nil
      key in ["local", "etc/unknown", "factory"] -> nil
      fixed = fixed_offset(name) -> fixed
      key == "utc" -> :utc
      true -> named(name)
    end
  end

  def find(_), do: nil

  defp named(name) do
    key = String.downcase(name)

    cond do
      known?(name) -> {:tz, name}
      (spelled = Map.get(@names, key)) && known?(spelled) -> {:tz, spelled}
      (aliased = Map.get(@aliases, key)) && known?(aliased) -> {:tz, aliased}
      true -> nil
    end
  end

  defp known?(name), do: match?({:ok, _}, Tz.PeriodsProvider.periods(name))

  # "+HH", "+HHMM" or "+HH:MM" (or "-", or the minus sign), as Intl reads an offset time zone.
  defp fixed_offset(text) do
    case Regex.run(~r/\A([+\-]|\x{2212})([01][0-9]|2[0-3])(?::?([0-5][0-9]))?\z/u, text) do
      [_, sign, hh | rest] ->
        mm = List.first(rest) || "0"
        sec = (String.to_integer(hh) * 60 + String.to_integer(if(mm == "", do: "0", else: mm))) * 60
        {:fixed, if(sign == "+", do: sec, else: -sec)}

      _ ->
        nil
    end
  end

  @doc "The seconds the zone's wall clock is ahead of UTC at epoch second `sec`."
  @spec offset(integer(), t()) :: integer()
  def offset(_sec, :utc), do: 0
  def offset(_sec, {:fixed, seconds}), do: seconds

  def offset(sec, {:tz, name}) do
    sec = sec |> max(@min_sec) |> min(@max_sec)
    days = Integer.floor_div(sec, 86_400)
    rest = sec - days * 86_400
    iso_days = {days + @epoch_days, {rest * 1_000_000, 86_400_000_000}}

    case Tz.TimeZoneDatabase.time_zone_period_from_utc_iso_days(iso_days, name) do
      {:ok, %{utc_offset: utc, std_offset: std}} -> utc + std
      _ -> 0
    end
  end

  @doc "The wall clock at an epoch second: year, month, day, hour, minute, second."
  @spec wall_at(integer(), t()) :: {integer(), integer(), integer(), integer(), integer(), integer()}
  def wall_at(sec, zone) do
    local = sec + offset(sec, zone)
    days = Integer.floor_div(local, 86_400)
    rest = local - days * 86_400
    {y, m, d} = JS.civil_from_days(days)
    {y, m, d, div(rest, 3600), rem(rest, 3600) |> div(60), rem(rest, 60)}
  end
end
